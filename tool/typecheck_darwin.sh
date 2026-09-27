#!/usr/bin/env bash
#
# Type-check the Darwin (iOS/macOS) Swift sources against the real Flutter
# modules — no stubs, so a pass means something.
#
# Checks every target the plugin ships: macOS, iOS device, and iOS simulator.
# Targets whose SDK is unavailable are skipped with a notice rather than
# silently passing. It degrades usefully: with only the Command Line Tools
# installed the macOS check still runs, because CLT ship swiftc and a macOS SDK
# that includes CoreBluetooth, and the Flutter SDK caches the frameworks.
#
# Limits, so nobody reads more into a green run than is there:
#   * -typecheck stops before code generation and linking.
#   * Podspec validity, resource bundles, and entitlements are untouched.
#   * Nothing here touches a radio.
#
# For the real thing, from example/:
#   flutter build macos
#   flutter build ios --simulator      # needs the iOS platform installed:
#                                      #   xcodebuild -downloadPlatform iOS
set -euo pipefail

cd "$(dirname "$0")/.."
SOURCES="darwin/ble_mesh_chat/Sources/ble_mesh_chat"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH; cannot locate the cached Flutter frameworks." >&2
  exit 1
fi

# `flutter` on PATH is often a wrapper script rather than a symlink into the
# SDK, so ask the tool itself rather than walking the filesystem.
FLUTTER_ROOT=$(flutter --version --machine \
  | sed -n 's/.*"flutterRoot" *: *"\([^"]*\)".*/\1/p')
if [ -z "$FLUTTER_ROOT" ] || [ ! -d "$FLUTTER_ROOT" ]; then
  echo "Could not determine flutterRoot from 'flutter --version --machine'." >&2
  exit 1
fi
ENGINE="$FLUTTER_ROOT/bin/cache/artifacts/engine"

# Deployment targets must match the podspec's s.osx/s.ios deployment_target.
MACOS_TARGET="arm64-apple-macosx12.0"
IOS_TARGET="arm64-apple-ios15.0"

checked=0
skipped=0
failed=0

# check <label> <sdk-name> <swift-target> <framework-path-pattern>
#
# The pattern is matched with `find -path` rather than a shell glob: the
# Flutter SDK often lives under a path containing spaces (e.g. "Application
# Support"), which word-splits an unquoted glob.
check() {
  local label="$1" sdk_name="$2" target="$3" fw_pattern="$4"

  local sdk
  if ! sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path 2>/dev/null) || [ -z "$sdk" ]; then
    echo "SKIP  $label — no $sdk_name SDK (install Xcode for iOS targets)"
    skipped=$((skipped + 1))
    return 0
  fi

  local fw
  fw=$(find "$ENGINE" -maxdepth 3 -type d -path "$fw_pattern" -print -quit 2>/dev/null)
  if [ -z "$fw" ]; then
    echo "SKIP  $label — Flutter framework not cached. Run: flutter precache"
    skipped=$((skipped + 1))
    return 0
  fi

  echo "CHECK $label ($target)"
  if xcrun swiftc -typecheck -sdk "$sdk" -target "$target" -F "$fw" "$SOURCES"/*.swift; then
    checked=$((checked + 1))
  else
    failed=$((failed + 1))
  fi
}

check "macOS          " macosx           "$MACOS_TARGET"       "$ENGINE/darwin-*/FlutterMacOS.xcframework/macos-*"
check "iOS device     " iphoneos         "$IOS_TARGET"         "$ENGINE/ios/Flutter.xcframework/ios-arm64"
check "iOS simulator  " iphonesimulator  "$IOS_TARGET-simulator" "$ENGINE/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"

echo
echo "$checked target(s) type-checked, $skipped skipped, $failed failed."
if [ "$failed" -gt 0 ]; then
  exit 1
fi
echo "OK — no errors. (Not linked; see the header of this script.)"
