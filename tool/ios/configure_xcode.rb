# Adds what patch_native.py cannot do with plain text edits:
#   - CODE_SIGN_ENTITLEMENTS for the Runner target (push + App Attest)
#   - Arabic and English as known regions
#   - ar/en InfoPlist.strings as a localized resource
#   - PrivacyInfo.xcprivacy (the app's privacy manifest) as a resource
# Needs the `xcodeproj` Ruby gem (installed with CocoaPods; present on
# Codemagic macOS machines). If it cannot run, bootstrap.sh prints the
# manual Xcode steps from SETUP.md instead.
#
# Idempotent (16 Nov 2026): running it twice changes nothing, and a file is
# never added twice (a second copy of PrivacyInfo.xcprivacy makes Xcode
# fail with "Multiple commands produce"). Safe with Xcode synchronized
# folders (Xcode 16+, PBXFileSystemSynchronizedRootGroup): files inside a
# synchronized Runner folder are already in the target, so nothing is
# added; a file excluded from the target by an exception set is put back.
require 'xcodeproj'

project_path = File.expand_path('../../ios/Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target not found')
changed = []

target.build_configurations.each do |config|
  next if config.build_settings['CODE_SIGN_ENTITLEMENTS'] == 'Runner/Runner.entitlements'

  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  changed << "entitlements (#{config.name})"
end

regions = project.root_object.known_regions || []
wanted_regions = (regions + %w[ar en Base]).uniq
if wanted_regions != regions
  project.root_object.known_regions = wanted_regions
  changed << 'regions'
end

SYNCHRONIZED = 'PBXFileSystemSynchronizedRootGroup'.freeze

runner_group = project.main_group.children.find do |child|
  (child.respond_to?(:path) && child.path == 'Runner') || child.display_name == 'Runner'
end
abort('Runner group not found') unless runner_group

# True when the build phase already copies a file whose path ends in [name]
# (from any group, a variant group or a reference added by hand).
def in_phase?(phase, name)
  phase.files.any? do |build_file|
    ref = build_file.file_ref
    next false unless ref

    paths = [ref.path, ref.display_name]
    paths += ref.children.map(&:path) if ref.respond_to?(:children) && ref.isa == 'PBXVariantGroup'
    paths.compact.any? { |p| p == name || p.end_with?("/#{name}") }
  end
end

if runner_group.isa == SYNCHRONIZED
  # Xcode adds every file in the folder to the target by itself. Remove our
  # files from any exception set that would leave them out of Runner.
  exceptions = runner_group.respond_to?(:exceptions) ? runner_group.exceptions.to_a : []
  exceptions.each do |exception|
    next unless exception.respond_to?(:membership_exceptions) && exception.membership_exceptions
    next if exception.respond_to?(:target) && exception.target != target

    keep = exception.membership_exceptions.reject do |path|
      %w[PrivacyInfo.xcprivacy ar.lproj/InfoPlist.strings en.lproj/InfoPlist.strings].include?(path)
    end
    next if keep == exception.membership_exceptions

    exception.membership_exceptions = keep
    changed << 'synchronized folder exceptions'
  end
  # A reference added by an older run of this script next to the
  # synchronized folder would copy the file twice: drop it.
  target.resources_build_phase.files.to_a.each do |build_file|
    ref = build_file.file_ref
    next unless ref

    ours = (ref.respond_to?(:path) && ref.path == 'PrivacyInfo.xcprivacy') ||
           (ref.isa == 'PBXVariantGroup' && ref.display_name == 'InfoPlist.strings')
    next unless ours

    target.resources_build_phase.remove_build_file(build_file)
    ref.remove_from_project
    changed << "duplicate #{ref.display_name} reference removed"
  end
else
  phase = target.resources_build_phase

  variant = runner_group.children.find do |child|
    child.isa == 'PBXVariantGroup' && child.name == 'InfoPlist.strings'
  end
  unless variant
    variant = runner_group.new_variant_group('InfoPlist.strings')
    %w[ar en].each do |lang|
      ref = variant.new_reference("#{lang}.lproj/InfoPlist.strings")
      ref.name = lang
      ref.last_known_file_type = 'text.plist.strings'
    end
    changed << 'InfoPlist.strings'
  end
  phase.add_file_reference(variant, true) unless in_phase?(phase, 'InfoPlist.strings')

  # The app's privacy manifest (copied by patch_native.py) must be in the
  # bundle root, or App Store Connect reports missing API declarations.
  # Exactly once, wherever an earlier run or a template put it.
  privacy = project.files.find { |f| f.path == 'PrivacyInfo.xcprivacy' || f.path.to_s.end_with?('Runner/PrivacyInfo.xcprivacy') }
  unless privacy
    privacy = runner_group.new_reference('PrivacyInfo.xcprivacy')
    privacy.last_known_file_type = 'text.xml'
    changed << 'privacy manifest reference'
  end
  unless in_phase?(phase, 'PrivacyInfo.xcprivacy')
    phase.add_file_reference(privacy, true)
    changed << 'privacy manifest in resources'
  end
end

if changed.empty?
  puts 'configure_xcode: already set (nothing changed)'
else
  project.save
  puts "configure_xcode: set #{changed.join(', ')}"
end
