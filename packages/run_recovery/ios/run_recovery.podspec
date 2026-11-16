# Local plugin (packages/run_recovery), used by the School Carpool app only.
Pod::Spec.new do |s|
  s.name             = 'run_recovery'
  s.version          = '0.1.0'
  s.summary          = 'Run recovery for School Carpool: significant location changes and background activity sessions during a run.'
  s.description      = 'Keeps a school run\'s live location going on iPhone when the app is closed by iOS or swiped away (with Always permission).'
  s.homepage         = 'https://example.com/school-carpool/run_recovery'
  s.license          = { :type => 'Proprietary', :text => 'Part of the School Carpool app.' }
  s.author           = { 'School Carpool' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  # Privacy manifest: the plugin keeps one flag in UserDefaults (reason CA92.1).
  s.resource_bundles = { 'run_recovery_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.frameworks       = 'CoreLocation'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
