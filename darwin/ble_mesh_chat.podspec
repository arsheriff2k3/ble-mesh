#
# Shared iOS + macOS podspec. See ../pubspec.yaml (`sharedDarwinSource: true`).
# Run `pod lib lint ble_mesh_chat.podspec` to validate.
#
Pod::Spec.new do |s|
  s.name             = 'ble_mesh_chat'
  s.version          = '0.1.1'
  s.summary          = 'Dual-role BLE byte transport for offline mesh networks.'
  s.description      = <<-DESC
Dual-role (central + peripheral) Bluetooth Low Energy byte transport. The native
layer exposes links, frames, and frame sizes only; the mesh protocol lives in Dart.
                       DESC
  s.homepage         = 'https://github.com/arsheriff2k3/ble-mesh'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Ryan Sheriff' => 'arsheriff2k3@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'ble_mesh_chat/Sources/ble_mesh_chat/**/*.swift'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  s.resource_bundles = {
    'ble_mesh_chat_privacy' => ['ble_mesh_chat/Sources/ble_mesh_chat/PrivacyInfo.xcprivacy']
  }
end
