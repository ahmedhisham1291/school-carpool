# Adds what patch_native.py cannot do with plain text edits:
#   - CODE_SIGN_ENTITLEMENTS for the Runner target (push + App Attest)
#   - Arabic and English as known regions
#   - ar/en InfoPlist.strings as a localized resource
#   - PrivacyInfo.xcprivacy (the app's privacy manifest) as a resource
# Needs the `xcodeproj` Ruby gem (installed with CocoaPods; present on
# Codemagic macOS machines). Idempotent. If it cannot run, bootstrap.sh prints
# the manual Xcode steps from SETUP.md instead.
require 'xcodeproj'

project_path = File.expand_path('../../ios/Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target not found')

target.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

regions = project.root_object.known_regions || []
project.root_object.known_regions = (regions + %w[ar en Base]).uniq

runner_group = project.main_group['Runner'] or abort('Runner group not found')
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
  target.resources_build_phase.add_file_reference(variant, true)
end

# The app's privacy manifest (copied by patch_native.py) must be in the
# bundle root, or App Store Connect reports missing API declarations.
unless runner_group.files.any? { |f| f.path == 'PrivacyInfo.xcprivacy' }
  privacy = runner_group.new_reference('PrivacyInfo.xcprivacy')
  privacy.last_known_file_type = 'text.xml'
  target.resources_build_phase.add_file_reference(privacy, true)
end

project.save
puts 'configure_xcode: entitlements, regions, InfoPlist.strings and privacy manifest set'
