# A tiny stand-in for the `xcodeproj` gem, for tool/test_configure_xcode.py
# only (the gem is not installed in the build workspace). It models just
# what tool/ios/configure_xcode.rb uses. The project is read from the JSON
# file in XCODEPROJ_STUB_IN and written to XCODEPROJ_STUB_OUT on save.
require 'json'

module Xcodeproj
  class Ref
    attr_accessor :isa, :path, :name, :last_known_file_type, :children, :parent, :project

    def initialize(project, isa, path, name = nil)
      @project = project
      @isa = isa
      @path = path
      @name = name
      @children = []
    end

    def display_name
      @name || (@path && File.basename(@path))
    end

    def files
      @children.select { |c| c.isa == 'PBXFileReference' }
    end

    def new_reference(path)
      ref = Ref.new(@project, 'PBXFileReference', path)
      ref.parent = self
      @children << ref
      ref
    end

    def new_variant_group(name)
      group = Ref.new(@project, 'PBXVariantGroup', nil, name)
      group.parent = self
      @children << group
      group
    end

    def remove_from_project
      @parent&.children&.delete(self)
      @project.removed << display_name
    end
  end

  class Exception
    attr_accessor :membership_exceptions, :target

    def initialize(paths, target)
      @membership_exceptions = paths
      @target = target
    end
  end

  class SyncGroup < Ref
    attr_accessor :exceptions
  end

  BuildFile = Struct.new(:file_ref)

  class Phase
    attr_reader :files

    def initialize
      @files = []
    end

    def add_file_reference(ref, _avoid_duplicates = false)
      @files << BuildFile.new(ref)
    end

    def remove_build_file(build_file)
      @files.delete(build_file)
    end
  end

  Config = Struct.new(:name, :build_settings)

  class Target
    attr_reader :name, :build_configurations, :resources_build_phase

    def initialize(name)
      @name = name
      @build_configurations = %w[Debug Release Profile].map { |n| Config.new(n, {}) }
      @resources_build_phase = Phase.new
    end
  end

  class Root
    attr_accessor :known_regions
  end

  class Project
    attr_reader :targets, :root_object, :main_group, :removed

    def self.open(_path)
      new(JSON.parse(File.read(ENV.fetch('XCODEPROJ_STUB_IN'))))
    end

    def initialize(state)
      @removed = []
      @state = state
      target = Target.new('Runner')
      @targets = [target]
      (state['entitlements'] || {}).each do |config, value|
        target.build_configurations.find { |c| c.name == config }.build_settings['CODE_SIGN_ENTITLEMENTS'] = value
      end
      @root_object = Root.new
      @root_object.known_regions = state['regions'] || %w[en Base]
      @main_group = Ref.new(self, 'PBXGroup', nil)
      if state['synchronized']
        runner = SyncGroup.new(self, 'PBXFileSystemSynchronizedRootGroup', 'Runner')
        runner.exceptions = (state['exceptions'] || []).map { |paths| Exception.new(paths, target) }
      else
        runner = Ref.new(self, 'PBXGroup', 'Runner')
      end
      runner.parent = @main_group
      @main_group.children << runner
      (state['runnerFiles'] || []).each do |path|
        ref = runner.new_reference(path)
        target.resources_build_phase.add_file_reference(ref) if (state['phase'] || []).include?(path)
      end
      (state['variants'] || []).each do |name|
        variant = runner.new_variant_group(name)
        %w[ar en].each { |l| variant.new_reference("#{l}.lproj/#{name}") }
        target.resources_build_phase.add_file_reference(variant) if (state['phase'] || []).include?(name)
      end
    end

    def files
      walk(@main_group).select { |r| r.isa == 'PBXFileReference' }
    end

    def walk(ref)
      [ref] + ref.children.flat_map { |c| walk(c) }
    end

    def save
      target = @targets.first
      runner = @main_group.children.first
      out = {
        'entitlements' => target.build_configurations.to_h { |c| [c.name, c.build_settings['CODE_SIGN_ENTITLEMENTS']] },
        'regions' => @root_object.known_regions,
        'phase' => target.resources_build_phase.files.map { |f| f.file_ref.display_name },
        'runnerChildren' => runner.children.map(&:display_name),
        'exceptions' => runner.respond_to?(:exceptions) ? runner.exceptions.map(&:membership_exceptions) : nil,
        'removed' => @removed,
      }
      File.write(ENV.fetch('XCODEPROJ_STUB_OUT'), JSON.generate(out))
    end
  end
end
