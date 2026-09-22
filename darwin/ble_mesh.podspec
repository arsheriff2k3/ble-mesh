#
# Shared iOS + macOS podspec. See ../pubspec.yaml (`sharedDarwinSource: true`).
# Run `pod lib lint ble_mesh.podspec` to validate.
#
Pod::Spec.new do |s|
  s.name             = 'ble_mesh'
  s.version          = '0.1.0'
  s.summary          = 'Dual-role BLE byte transport for offline mesh networks.'
  s.description      = <<-DESC
Dual-role (central + peripheral) Bluetooth Low Energy byte transport. The native
layer exposes links, frames, and frame sizes only; the mesh protocol lives in Dart.
                       DESC
  s.homepage         = 'https://github.com/blemesh/ble_mesh'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Mako IT Lab' => 'arsheriff2k3@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'ble_mesh/Sources/ble_mesh/**/*.swift'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  s.resource_bundles = {
    'ble_mesh_privacy' => ['ble_mesh/Sources/ble_mesh/PrivacyInfo.xcprivacy']
  }
end
