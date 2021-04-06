# frozen_string_literal: true

# Copyright 2019 Grabtaxi Holdings PTE LTE (GRAB), All rights reserved.
# Use of this source code is governed by an MIT-style license that can be found in the LICENSE file

require 'cocoapods'
require 'fileutils'
require 'json'
require 'digest/md5'
require 'fourflusher'

CacheDirectory = 'MergeCache'
InstallationDirectory = 'MergedPods'
MergeFileName = 'MergeFile'
MergeFileSample = %(
  group 'NetworkingPods' do
    pod 'AFNetworking'
    pod 'CocoaAsyncSocket'
  end

  group 'ImagePods' do
    pod 'SDWebImage'
    pod 'FLAnimatedImage'
  end
)
PodSpecWriter_Hook = %(
  post_install do |context|
    FileUtils.mkdir('Podspecs')
    context.aggregate_targets[0].specs.each do |spec|
      podspec = File.new("Podspecs/\#{spec.name.gsub("/", "_")}.json", 'w')
          podspec.puts(spec.attributes_hash.to_json)
          podspec.close
    end
    context.aggregate_targets[0].target_definition.dependencies.each do |dependency|
      if dependency.external?
        if dependency.external_source.key?(:path)
          path = dependency.external_source[:path]
          Pod::UI.puts "Creating a copy of external source for merging: \#{dependency.name}".yellow
          FileUtils.copy_entry path, "Pods/\#{dependency.name}"
        end
      end
    end
  end
)

module CocoapodsPodMerge
  class PodMerger
    def begin(_installer_context)
      merge_groups = parse_mergefile
      podfile_info = read_podfile

      unless install_and_merge_required
        Pod::UI.puts 'The pods are already merged according to the MergeFile, no changes required.'.yellow
        add_to_gitignore
        return
      end

      # Delete existing merged frameworks & cache
      if File.directory?(InstallationDirectory)
        FileUtils.rm_rf(InstallationDirectory)
      end
      FileUtils.rm_rf(CacheDirectory) if File.directory?(CacheDirectory)

      unless File.directory?(InstallationDirectory)
        FileUtils.mkdir(InstallationDirectory)
      end

      merge_groups.each do |group, group_contents|
        merge(group, group_contents, podfile_info)
      end

      create_mergefile_lock
      add_to_gitignore
    end

    def add_mergefile_to_project(installer_context) 
      pods_project = Xcodeproj::Project.open(installer_context.pods_project.path)
      mergefile = pods_project.new_file('../MergeFile')
      mergefile.explicit_file_type = 'text.script.ruby'
      mergefile.include_in_index = '1'
      pods_project.save

      build_framework(installer_context)
    end

    def exclude_arm64_architectures(project_path, configuration)
      project = Xcodeproj::Project.open(project_path)
      project.targets.each do |target|
        config = target.build_configurations.find { |config| config.name.eql? configuration }
        config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64'
      end
      project.save
    end

    def copy_bcsymbolmap_files(symbols_destination, configuration)
      Pod::UI.puts "Copying the bcsymbolmap files for the generated frameworks."
      symbols_destination.rmtree if symbols_destination.directory?
      symbols = Pathname.glob("build/#{configuration}-iphoneos/**/*.bcsymbolmap")
      symbols.each do |symbol|
        FileUtils.mkdir_p symbols_destination
        FileUtils.cp_r symbol, symbols_destination, :remove_destination => true
      end
    end

    def enable_debug_information(project_path, configuration)
      project = Xcodeproj::Project.open(project_path)
      project.targets.each do |target|
        config = target.build_configurations.find { |config| config.name.eql? configuration }
        config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
        config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
      end
      project.save
    end
    
    def enable_bitcode(project_path, configuration)
      project = Xcodeproj::Project.open(project_path)
      project.targets.each do |target|
        config = target.build_configurations.find { |config| config.name.eql? configuration }
        config.build_settings['ENABLE_BITCODE'] = 'YES'
        config.build_settings['BITCODE_GENERATION_MODE'] = 'bitcode'
      end
      project.save
    end
    
    def copy_dsym_files(dsym_destination, configuration)
      dsym_destination.rmtree if dsym_destination.directory?
      platforms = ['iphoneos', 'iphonesimulator']
      platforms.each do |platform|
        dsym = Pathname.glob("build/#{configuration}-#{platform}/**/*.dSYM")
        dsym.each do |dsym|
          destination = dsym_destination + platform
          FileUtils.mkdir_p destination
          FileUtils.cp_r dsym, destination, :remove_destination => true
        end
      end
    end

    def copy_dsym_and_bcsymbolmap(project_path)
      Pod::UI.puts "Copying the bcsymbolmap files & dSYMs to the Framework folder."
    
      destination = 'Framework'

      symbols = Pathname.glob("bcsymbolmap/**/*.bcsymbolmap")
      symbols.each do |symbol|
        FileUtils.cp_r symbol, destination, :remove_destination => true
      end

      dSYMs = Pathname.glob("dSYM/iphoneos/**/*.dSYM")
      dSYMs.each do |dSYM|
        FileUtils.cp_r dSYM, destination, :remove_destination => true
      end

      FileUtils.rm_rf(project_path + 'dSYM')
      FileUtils.rm_rf(project_path + 'bcsymbolmap')
    end 

    PLATFORMS = { 'iphonesimulator' => 'iOS',
      'appletvsimulator' => 'tvOS',
      'watchsimulator' => 'watchOS' }

    def build_for_iosish_platform(sandbox, build_dir, target, device, simulator, configuration)
      deployment_target = target.platform_deployment_target
      target_label = target.cocoapods_target_label

      xcodebuild(sandbox, target_label, device, deployment_target, configuration)
      xcodebuild(sandbox, target_label, simulator, deployment_target, configuration)

      spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
      spec_names.each do |root_name, module_name|
        executable_path = "#{build_dir}/#{root_name}"
        device_lib = "#{build_dir}/#{configuration}-#{device}/#{root_name}/#{module_name}.framework/#{module_name}"
        device_framework_lib = File.dirname(device_lib)
        simulator_lib = "#{build_dir}/#{configuration}-#{simulator}/#{root_name}/#{module_name}.framework/#{module_name}"

        next unless File.file?(device_lib) && File.file?(simulator_lib)

        lipo_log = `lipo -create -output #{executable_path} #{device_lib} #{simulator_lib}`
        puts lipo_log unless File.exist?(executable_path)

        FileUtils.mv executable_path, device_lib, :force => true
        FileUtils.mv device_framework_lib, build_dir, :force => true
        FileUtils.rm simulator_lib if File.file?(simulator_lib)
        FileUtils.rm device_lib if File.file?(device_lib)
      end
    end

    def xcodebuild(sandbox, target, sdk='macosx', deployment_target=nil, configuration)
      args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration} -sdk #{sdk})
      platform = PLATFORMS[sdk]
      args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?
      Pod::Executable.execute_command 'xcodebuild', args, true
    end

    def build_framework(installer_context)
      sandbox_root = Pathname(installer_context.sandbox_root)
      sandbox = Pod::Sandbox.new(sandbox_root)

      configuration = 'Release'
      exclude_arm64_architectures(sandbox.project_path, configuration)
      enable_bitcode(sandbox.project_path, configuration)
      enable_debug_information(sandbox.project_path, configuration)
      
      build_dir = sandbox_root.parent + 'build'
      destination = sandbox_root.parent + 'Framework'

      Pod::UI.puts "Building the frameworks"

      build_dir.rmtree if build_dir.directory?
      targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
      targets.each do |target|
        case target.platform_name
        when :ios then build_for_iosish_platform(sandbox, build_dir, target, 'iphoneos', 'iphonesimulator', configuration)
        else raise "Unknown platform '#{target.platform_name}'" end
      end

      raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

      # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
      # can get upset about Info.plist containing references to the simulator SDK
      frameworks = Pathname.glob("build/*/*/*.framework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }
      frameworks += Pathname.glob("build/*.framework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }

      resources = []

      Pod::UI.puts "Built #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)}"

      destination.rmtree if destination.directory?

      installer_context.umbrella_targets.each do |umbrella|
        umbrella.specs.each do |spec|
          consumer = spec.consumer(umbrella.platform_name)
          pod_dir = sandbox.pod_dir(spec.root.name).parent

          file_accessor = Pod::Sandbox::FileAccessor.new(pod_dir, consumer)
          frameworks += file_accessor.vendored_libraries
          frameworks += file_accessor.vendored_frameworks
          resources += file_accessor.resources
        end
      end
      frameworks.uniq!
      resources.uniq!

      Pod::UI.puts "Copying #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)} " \
        "to the `#{destination.relative_path_from Pathname.pwd}` folder"

      FileUtils.mkdir_p destination
      (frameworks + resources).each do |file|
        FileUtils.cp_r file, destination, :remove_destination => true
      end

      copy_dsym_files(sandbox_root.parent + 'dSYM', configuration)
      copy_bcsymbolmap_files(sandbox_root.parent + 'bcsymbolmap', configuration)
      copy_dsym_and_bcsymbolmap(sandbox_root.parent)

      build_dir.rmtree if build_dir.directory?
    end

    def add_to_gitignore
      gitignore_file = '.gitignore'

      return unless File.file?(gitignore_file)

      contents = File.read(gitignore_file)
      cache_folder = contents.scan(/#{CacheDirectory}/)
      contents += "\n#{CacheDirectory}/" unless cache_folder&.last

      #merged_folder = contents.scan(/#{InstallationDirectory}/)
      #contents += "\n#{InstallationDirectory}/" unless merged_folder&.last

      File.open(gitignore_file, 'w') { |file| file.puts contents }
    end

    def read_podfile
      unless File.file?('Podfile')
        abort('You don\'t seem to have a Podfile. What\'s good a Mergefile, without a Podfile?\n\nPlease run pod init to begin.'.red)
      end

      sources = []
      platforms = []

      File.open('Podfile', 'r') do |f|
        f.each_line do |line|
          next if line.strip.empty?

          unless line.scan(/platform :(.+),/).empty?
            platforms.append(line.strip)
          end
          sources.append(line.strip) unless line.scan(/source '(.+)'/).empty?
        end
      end
      PodfileInfo.new(sources, platforms)
    end

    def install_and_merge_required
      mergefile_lock_path = "#{InstallationDirectory}/#{MergeFileName}.lock"
      return true unless File.file?(mergefile_lock_path)

      current_mergefile_hash = Digest::MD5.hexdigest(File.read(MergeFileName))
      locked_mergefile_hash = File.read(mergefile_lock_path)
      current_mergefile_hash.strip != locked_mergefile_hash.strip
    end

    def create_mergefile_lock
      mergefile_lock_path = "#{InstallationDirectory}/#{MergeFileName}.lock"
      current_mergefile_hash = Digest::MD5.hexdigest(File.read(MergeFileName))
      File.open(mergefile_lock_path, 'w') { |file| file.puts current_mergefile_hash }
    end

    def parse_mergefile
      unless File.file?(MergeFileName)
        sample_mergefile = File.new(MergeFileName, 'w')
        sample_mergefile.puts(MergeFileSample)
        sample_mergefile.close
        abort('You need a MergeFile in your current directory to use cocoapods-pod-merge. A sample one has been created for you.'.green)
      end
      merge_groups = {}
      File.open(MergeFileName, 'r') do |f|
        parsing_a_group = false
        group_name = ''
        f.each_line do |line|
          next if line.strip.empty?
          next if line.strip.start_with?('#')

          line = line.gsub(/\#.+/, '') if line.include?('#') # Remove any comments
          if parsing_a_group
            if line.strip == 'end'
              parsing_a_group = false
            elsif line.strip.include?('!')
              if line.strip.include?('swift_version!')
                extracted_swift_version = line.strip.delete('swift_version!').delete('\'').delete('\"').strip.to_f
                if extracted_swift_version == 0
                  abort("Found an invalid Swift version specified for group \'#{group_name}\' in the MergeFile. Please specify one like: swift_version! '5.0'".red)
                end
                merge_groups[group_name]['swift_version'] = extracted_swift_version.to_s
              else
                merge_groups[group_name]['flags'][line.strip.delete('!')] = true
              end
            elsif line.strip.include?('platform')
              merge_groups[group_name]['platforms'].append(line)
            else
              merge_groups[group_name]['lines'].append(line)
              line = line.split(',').first
              title = line.scan(/\'(.+)\'/)
              title ||= line.scan(/\"(.+)\"/)
              merge_groups[group_name]['titles'].append(title.last.first.to_s.delete(',').delete("\''").delete('"'))
            end
          else
            unless line.scan(/\'(.+)\'/).last.empty?
              group_name = line.scan(/\'(.+)\'/).last.first.to_s

              if merge_groups[group_name]
                abort("Duplicate Group Name: #{group_name}. Please make sure all groups have different names!".red)
              end

              merge_groups[group_name] = { 'titles' => [], 'lines' => [], 'flags' => {}, 'swift_version' => '', 'platforms' => [] }
              parsing_a_group = true
            end
          end
        end
      end
      merge_groups
    end

    def merge(merged_framework_name, group_contents, podfile_info)
      Pod::UI.puts "Preparing to Merge: #{merged_framework_name}"

      pods_to_merge = group_contents['titles'].map { |pod_name| pod_name.sub /(\/[a-zA-Z]+)/,''}.uniq
      flags = group_contents['flags']
      forced_swift_language_version = group_contents['swift_version']
      platforms_in_target = group_contents['platforms']
      public_headers_by_pod = {}
      frameworks = []
      prefix_header_contents = []
      private_header_files = []
      resources = []
      script_phases = []
      compiler_flags = []
      libraries = []
      prepare_command = []
      vendored_libraries = []
      resource_bundles = {}
      swift_versions = {}

      # Flags
      has_dependencies = false
      mixed_language_group = false

      flags.each do |flag, _|
        case flag.strip
        when 'has_dependencies'
          has_dependencies = true
        end
      end

      # Download the Pods to be merged
      Pod::UI.puts 'Downloading Pods in the group'.cyan
      FileUtils.mkdir CacheDirectory unless File.directory?(CacheDirectory)

      create_cache_podfile(podfile_info, group_contents['lines'], forced_swift_language_version, platforms_in_target)

      Dir.chdir(CacheDirectory) do
        system('pod install') || raise('Failed to download pods to merge')
      end

      # Create a directory for the merged framework
      FileUtils.mkdir("#{InstallationDirectory}/#{merged_framework_name}")
      FileUtils.mkdir("#{InstallationDirectory}/#{merged_framework_name}/Sources")

      Pod::UI.puts 'Merging Pods'.cyan
      pods_to_merge.each_with_index do |pod, index|
        # Capture all resources to specify in the final podspec
        Pod::UI.puts "\t#{pod.cyan}"

        Dir.chdir("#{CacheDirectory}/Pods/#{pod}") do
          # Validate the Pod
          Pod::UI.puts "\t\tValidating Pod".magenta

          unless Dir.glob('**/*.swift').empty? # Make sure the pod is not a Swift or Mixed Pod
            mixed_language_group = true
            Pod::UI.puts "\t\tExperimental: ".yellow + "The group #{merged_framework_name} consists of Swift Pods. This can lead to import pollution.".magenta
          end

          unless Dir.glob('**/*.a').empty? # Log an experimental warning when merging pods with static libraries inside
            Pod::UI.puts "\t\tExperimental: ".yellow + "#{pod} contains static libraries inside, this can lead to errors or undefined behaviours".magenta
          end

          unless Dir.glob('**/*.framework').empty? # Make sure the pod does not contain a pre-compiled framework
            abort('Pods with precompiled frameworks inside cannot be merged.'.red)
          end

          Pod::UI.puts "\t\tCollecting Public Headers".magenta
          public_headers_by_pod[pod] = Dir.glob('**/*.h').map { |header| File.basename(header) }

          Dir.glob('**/*.{h,m,mm,swift}').each do |source_file|
            contents = File.read(source_file)
            if has_dependencies
              # Fix imports of style import xx
              pods_to_merge.each do |pod|
                modular_imports = contents.scan(%r{<#{pod}/(.+)>})
                next unless modular_imports&.last

                Pod::UI.puts "\t\tExperimental: ".yellow + "Found Modular Imports in #{source_file}, fixing this by converting to local #import".magenta
                contents_with_imports_fixed = contents.gsub(%r{<#{pod}/(.+)>}) do |match|
                  match.gsub(%r{<#{pod}/(.+)>}, "\"#{Regexp.last_match(1)}\"")
                end
                File.open(source_file, 'w') { |file| file.puts contents_with_imports_fixed }
              end

              # Fix imports of style import xx
              pods_to_merge.each do |pod|
                modular_imports = contents.scan("import #{pod}")
                next unless modular_imports&.last

                Pod::UI.puts "\t\tExperimental: ".yellow + "Found a module import in #{source_file}, fixing this by removing it".magenta
                File.open(source_file, 'w') { |file| file.puts contents.gsub("import #{pod}", '') }
              end
            else
              modular_imports = contents.scan(%r{<#{pod}/(.+)>})
              next unless modular_imports&.last

              Pod::UI.puts "\t\tExperimental: ".yellow + "Found Modular Imports in #{source_file}, fixing this by converting to local #import".magenta
              contents_with_imports_fixed = contents.gsub(%r{<#{pod}/(.+)>}) do |match|
                match.gsub(%r{<#{pod}/(.+)>}, "\"#{Regexp.last_match(1)}\"")
              end
              File.open(source_file, 'w') { |file| file.puts contents_with_imports_fixed }
            end
          end
        end

        # Read each pod's podspec, and collect configuration for the final merged podspec
        Pod::UI.puts "\t\tExtracting Detailed Podspecs".magenta
        
        # The originals pods name with the subspecs from the MergeFile. The subspecs are renamed to
        # PodspecName_Subspec instead of PodspecName/Subspec
        pods_to_merge_with_subspecs = group_contents['titles'].map { |pod_name| pod_name.sub '/','_'}

        Dir.chdir("#{CacheDirectory}/Podspecs") do
          info = extract_info_from_podspec(pods_to_merge_with_subspecs[index], mixed_language_group)
          frameworks += info.frameworks
          prefix_header_contents += info.prefix_header_contents
          private_header_files += info.private_header_files
          resources += info.resources
          script_phases += info.script_phases
          compiler_flags += info.compiler_flags
          libraries += info.libraries
          prepare_command += info.prepare_command
          vendored_libraries += info.vendored_libraries
          swift_versions[pod] = info.swift_versions.map(&:to_f)
          resource_bundles = resource_bundles.merge(info.resource_bundles)
        end

        # Copy over the Pods to be merged
        Pod::UI.puts "\t\tCopying Sources".magenta
        Dir.chdir("#{CacheDirectory}/Pods") do
          FileUtils.copy_entry pod.to_s, "../../#{InstallationDirectory}/#{merged_framework_name}/Sources/#{pod}"
        end
      end

      # Generate Module Map
      unless mixed_language_group
        Pod::UI.puts "\tGenerating module map".magenta
        generate_module_map(merged_framework_name, public_headers_by_pod)
      end

      # Verify there's a common Swift language version across the group
      if mixed_language_group
        if !forced_swift_language_version.empty?
          swift_version = [forced_swift_language_version]
        else
          swift_version = swift_versions.each_value.reduce { |final_swift_version, versions| final_swift_version & versions }
          unless swift_version&.first
            Pod::UI.puts "Could not find a common compatible Swift version across the pods to be merged group #{merged_framework_name}: #{swift_versions}".red
            abort("or specify a swift version in this group using the swift_version! flag, example: swift_version! '5.0'".red)
          end
        end
        Pod::UI.puts "\tUsing Swift Version #{swift_version.first} for the group: #{merged_framework_name}".yellow
      end

      # Create the local podspec
      Pod::UI.puts "\tCreating Podspec for the merged framework".magenta
      create_podspec(merged_framework_name, pods_to_merge, PodspecInfo.new(frameworks.uniq, prefix_header_contents.uniq, private_header_files.uniq, resources.uniq, script_phases.uniq, compiler_flags.uniq, libraries.uniq, prepare_command.uniq, resource_bundles, vendored_libraries.uniq, swift_version), mixed_language_group, podfile_info)

      Pod::UI.puts 'Cleaning up cache'.cyan
      FileUtils.rm_rf(CacheDirectory)

      Pod::UI.puts 'Merge Complete!'.green
    end

    def extract_info_from_podspec(pod, mixed_language_group)
      podspec_file = File.open "#{pod}.json"
      podspec = JSON.load podspec_file

      frameworks = []
      prefix_header_contents = []
      private_header_files = []
      resources = []
      script_phases = []
      compiler_flags = []
      libraries = []
      prepare_command = []
      vendored_libraries = []
      resource_bundles = {}
      swift_versions = []

      frameworks += array_wrapped(podspec['frameworks'])
      compiler_flags += array_wrapped(podspec['compiler_flags'])
      private_header_files += array_wrapped(podspec['private_header_files']).map { |path| "Sources/#{pod}/#{path}" }
      prefix_header_contents += array_wrapped(podspec['prefix_header_contents'])
      resources += array_wrapped(podspec['resource']).map { |path| "Sources/#{pod}/#{path}" }
      resources += array_wrapped(podspec['resources']).map { |path| "Sources/#{pod}/#{path}" }
      script_phases += array_wrapped(podspec['script_phases'])
      libraries += array_wrapped(podspec['library'])
      libraries += array_wrapped(podspec['libraries'])
      prepare_command += array_wrapped(podspec['prepare_command'])
      vendored_libraries += array_wrapped(podspec['vendored_library']).map { |path| "Sources/#{pod}/#{path}" }
      vendored_libraries += array_wrapped(podspec['vendored_libraries']).map { |path| "Sources/#{pod}/#{path}" }
      if mixed_language_group
        swift_versions += array_wrapped(podspec['swift_version'])
        swift_versions += array_wrapped(podspec['swift_versions'])
      end

      if podspec['resource_bundles']
        resource_bundles = resource_bundles.merge(podspec['resource_bundles'])
      end

      if podspec['resource_bundle']
        resource_bundles = resource_bundles.merge(podspec['resource_bundle'])
      end

      resource_bundles.each do |key, paths|
        paths = array_wrapped(paths).map { |path| "Sources/#{pod}/#{path}" }
        resource_bundles[key] = paths
      end

      subspecs = array_wrapped(podspec['default_subspec'])
      subspecs += array_wrapped(podspec['default_subspecs'])

      subspecs.each do |subspec|
        Pod::UI.puts "\t\tRecursively Collecting Podspecs for Subspec #{pod}/#{subspec}".magenta
        info = extract_info_from_podspec("#{pod}_#{subspec}", false) # Passing false assuming subspecs will not have a different swift version from the base spec
        frameworks += info.frameworks
        prefix_header_contents += info.prefix_header_contents
        private_header_files += info.private_header_files.map { |path| "Sources/#{pod}/#{path}" }
        resources += info.resources.map { |path| "Sources/#{pod}/#{path}" }
        script_phases += info.script_phases
        compiler_flags += info.compiler_flags
        libraries += info.libraries
        prepare_command += info.prepare_command
        vendored_libraries += info.vendored_libraries
        if info.resource_bundles
          resource_bundles = resource_bundles.merge(info.resource_bundles)
        end
      end

      PodspecInfo.new(frameworks, prefix_header_contents, private_header_files, resources, script_phases, compiler_flags, libraries, prepare_command, resource_bundles, vendored_libraries, swift_versions)
    end

    def array_wrapped(object)
      return [] unless object

      return object if object.class == Array
      return [object] if object.class == String || object.class == Hash
    end

    def create_cache_podfile(podfile_info, pods, swift_language_version, platforms_in_target)
      FileUtils.touch("#{CacheDirectory}/Podfile")
      file = File.new("#{CacheDirectory}/Podfile", 'w')

      uses_swift = !swift_language_version.empty?

      # Create a temporary Xcode project for pods missing Swift_Version in the Podspec
      if uses_swift
        project = Xcodeproj::Project.new("#{CacheDirectory}/Dummy.xcodeproj")
        target = project.new_target(:application, 'Dummy', :ios, '13.1', nil, :swift)
        swift_file = project.main_group.new_file('./dummy.swift')
        target.add_file_references([swift_file])
        project.targets.each do |target|
          target.build_configurations.each do |config|
            config.build_settings['SWIFT_VERSION'] ||= swift_language_version
          end
        end
        project.save
      end

      file.puts("require 'json'")
      podfile_info.sources.each do |source|
        file.puts source
      end

      if platforms_in_target.length == 0
        podfile_info.platforms.each do |platform|
          file.puts platform
        end
      end

      if uses_swift
        file.puts("install! 'cocoapods', :lock_pod_sources => false")
      else
        file.puts("install! 'cocoapods', :integrate_targets => false, :lock_pod_sources => false")
      end

      file.puts("target 'Dummy' do")
      platforms_in_target.each do |platform|
        file.puts platform.to_s
      end
      pods.each do |line|
        file.puts line.to_s
      end
    rescue IOError => e
      Pod::UI.puts "Error Writing Podfile for group #{pods}: #{e}".red
    ensure
      file.puts 'end'
      file.puts PodSpecWriter_Hook
      file&.close
    end

    def generate_module_map(merged_framework_name, public_headers)
      module_map = File.new("#{InstallationDirectory}/#{merged_framework_name}/Sources/module.modulemap", 'w')
      module_map.puts("framework module #{merged_framework_name} {")
      public_headers.each do |pod, headers|
        module_map.puts("\n\texplicit module #{pod.delete('+').delete('_')} {")
        headers.each do |header|
          module_map.puts("\t\theader \"#{header}\"")
        end
        module_map.puts("\t}")
      end
      module_map.puts("\n}")
      module_map.close
    end

    def create_podspec(merged_framework_name, pods_to_merge, podspec_info, mixed_language_group, podfile_info)
      frameworks = podspec_info.frameworks
      prefix_header_contents = podspec_info.prefix_header_contents
      private_header_files = podspec_info.private_header_files
      resources = podspec_info.resources
      script_phases = podspec_info.script_phases
      compiler_flags = podspec_info.compiler_flags
      libraries = podspec_info.libraries
      prepare_command = podspec_info.prepare_command
      resource_bundles = podspec_info.resource_bundles
      vendored_libraries = podspec_info.vendored_libraries
      swift_versions = podspec_info.swift_versions
      ios_deployment_target = podfile_info.platforms.find { |platform| platform.include? "ios"}.split(',')[1]

      mergedPodspec = %(
        Pod::Spec.new do |s|
          s.name             = '#{merged_framework_name}'
          s.version          = '1.0.0'
          s.summary          = 'Merged Pod generated by cocoapods pod-merge plugin'
          s.description      = 'Merged Framework containing the pods: #{pods_to_merge}'
          s.homepage         = 'https://github.com/grab/cocoapods-pod-merge'
          s.license          = { :type => 'MIT', :text => 'Merged Pods by cocoapods-pod-merge plugin  ' }
          s.author           = { 'GrabTaxi Pte Ltd' => 'dummy@grabtaxi.com' }
          s.source           = { :git => 'https://github.com/grab/cocoapods-pod-merge', :tag => '1.0.0' }
          s.ios.deployment_target = #{ios_deployment_target}
          s.source_files = 'Sources/**/*.{h,m,mm,swift}'
        )

      podspec = File.new("#{InstallationDirectory}/#{merged_framework_name}/#{merged_framework_name}.podspec", 'w')
      podspec.puts(mergedPodspec)

      if mixed_language_group
        podspec.puts("s.swift_version = #{swift_versions}")
      else
        podspec.puts("s.module_map = 'Sources/module.modulemap'")
      end

      unless resources.empty?
        podspec.puts("s.resource = #{resources.to_s.delete('[').delete(']')}")
      end

      unless frameworks.empty?
        podspec.puts("s.frameworks = #{frameworks.to_s.delete('[').delete(']')}")
      end

      unless prefix_header_contents.empty?
        podspec.puts("s.prefix_header_contents = #{prefix_header_contents.to_s.delete('[').delete(']')}")
      end

      unless private_header_files.empty?
        podspec.puts("s.private_header_files = #{private_header_files.to_s.delete('[').delete(']')}")
      end

      unless libraries.empty?
        podspec.puts("s.libraries = #{libraries.to_s.delete('[').delete(']')}")
      end

      unless prepare_command.empty?
        podspec.puts("s.prepare_command = #{prepare_command.to_s.delete('[').delete(']')}")
      end

      unless resource_bundles.empty?
        podspec.puts("s.resource_bundles = #{resource_bundles}")
      end

      unless vendored_libraries.empty?
        podspec.puts("s.vendored_libraries = #{vendored_libraries.to_s.delete('[').delete(']')}")
      end

      podspec.puts('end')
      podspec.close
    end
  end

  class PodspecInfo
    attr_accessor :frameworks
    attr_accessor :prefix_header_contents
    attr_accessor :private_header_files
    attr_accessor :resources
    attr_accessor :script_phases
    attr_accessor :compiler_flags
    attr_accessor :libraries
    attr_accessor :prepare_command
    attr_accessor :resource_bundles
    attr_accessor :vendored_libraries
    attr_accessor :swift_versions

    def initialize(frameworks, prefix_header_contents, private_header_files, resources, script_phases, compiler_flags, libraries, prepare_command, resource_bundles, vendored_libraries, swift_versions)
      @frameworks = frameworks
      @prefix_header_contents = prefix_header_contents
      @private_header_files = private_header_files
      @resources = resources
      @script_phases = script_phases
      @compiler_flags = compiler_flags
      @libraries = libraries
      @prepare_command = prepare_command
      @resource_bundles = resource_bundles
      @vendored_libraries = vendored_libraries
      @swift_versions = swift_versions
    end
  end

  class PodfileInfo
    attr_accessor :sources
    attr_accessor :platforms

    def initialize(sources, platforms)
      @sources = sources
      @platforms = platforms
    end
  end
end
