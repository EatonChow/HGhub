#!/usr/bin/env bash
# Build an unsigned (or ad-hoc-free) iOS .app and zip it as an IPA.
# Tauri 2.10.1 has no `ios build --no-sign`. This keeps its release-options
# server alive for the generated Xcode "Build Rust Code" phase, then invokes
# xcodebuild with code signing disabled.
set -euo pipefail

VERSION="${1:?Usage: build-ios-unsigned.sh VERSION}"
ROOT="$(pwd)"
LOG="$ROOT/ios-build-session.log"
export LIBCLANG_PATH="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
ADDR_FILE="$(node -p "require('os').tmpdir() + '/' + require('./src-tauri/tauri.conf.json').identifier + '-server-addr'")"
mkdir -p artifacts
rm -f "$ADDR_FILE"

# `ios build` only refreshes an existing Xcode project. Generate it first.
if ! compgen -G 'src-tauri/gen/apple/*.xcodeproj' > /dev/null; then
  pnpm tauri ios init --ci --skip-targets-install
fi

pnpm tauri ios build --open --ci --features custom-protocol >"$LOG" 2>&1 &
SESSION_PID=$!
# `tauri ios build --open` launches the Xcode GUI and then sleeps. The options
# server is already running; the GUI only competes with the Rust link for memory.
XCODE_GUARD_PID=""
cleanup() {
  local status=$?
  if [[ -n "$XCODE_GUARD_PID" ]]; then
    kill "$XCODE_GUARD_PID" 2>/dev/null || true
  fi
  kill "$SESSION_PID" 2>/dev/null || true
  pkill -x Xcode 2>/dev/null || true
  if [[ "$status" -ne 0 ]]; then
    echo "----- tauri ios build session log -----" >&2
    cat "$LOG" >&2 || true
  fi
}
trap cleanup EXIT

for ((attempt = 0; attempt < 1200; attempt++)); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    echo 'Tauri build session exited before becoming ready' >&2
    exit 1
  fi
  if [[ -s "$ADDR_FILE" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -s "$ADDR_FILE" ]]; then
  echo 'Timed out waiting for the Tauri build options server' >&2
  exit 1
fi

(
  while kill -0 "$SESSION_PID" 2>/dev/null; do
    pkill -x Xcode 2>/dev/null || true
    sleep 5
  done
) &
XCODE_GUARD_PID=$!

ICONSET="$(find src-tauri/gen/apple -type d -name 'AppIcon.appiconset' -print -quit)"
if [[ -z "$ICONSET" ]]; then
  echo 'AppIcon.appiconset was not generated' >&2
  exit 1
fi
cp src-tauri/icons/ios/*.png "$ICONSET/"

# Tauri writes the placeholder development team into the project. Drop it so
# xcodebuild does not look up a provisioning profile.
PBXPROJ="$(find src-tauri/gen/apple -name project.pbxproj -print -quit)"
sed -i '' '/DEVELOPMENT_TEAM/d' "$PBXPROJ"

ensure_transport() {
  local plist="$1"
  /usr/libexec/PlistBuddy -c 'Delete :NSAppTransportSecurity' "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsArbitraryLoadsInWebContent bool true' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$plist"
  if ! /usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Add :NSLocalNetworkUsageDescription string 用于连接本机回环上的媒体代理。' "$plist"
  fi
}
while IFS= read -r plist; do
  ensure_transport "$plist"
done < <(find src-tauri/gen/apple -name Info.plist)

# Tauri generates lowercase debug/release configurations. Using Release
# silently selected debug in the original workflow.
XCODE_TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
test -d "$XCODE_TOOLCHAIN/usr/lib/swift/iphoneos"
xcodebuild build \
  -toolchain com.apple.dt.toolchain.XcodeDefault \
  -project src-tauri/gen/apple/huangguo-client.xcodeproj \
  -scheme huangguo-client_iOS \
  -configuration release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$ROOT/build_output" \
  TOOLCHAIN_DIR="$XCODE_TOOLCHAIN" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS=""

APP="$ROOT/build_output/Build/Products/release-iphoneos/HGhub.app"
if [[ ! -d "$APP" ]]; then
  APP="$(find "$ROOT/build_output/Build/Products" -type d -name 'HGhub.app' -print -quit)"
fi
test -d "$APP"
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")
test -s "$APP/$EXECUTABLE"
file "$APP/$EXECUTABLE" | grep 'Mach-O.*arm64'
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
test "$BUNDLE_ID" = "com.eatonchow.hghub"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$APP/Info.plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "$APP/Info.plist")" = "true"
# Avoid grep -q with pipefail: early pipe closure can hide a match.
strings "$APP/$EXECUTABLE" > "$ROOT/ios-binary-strings.txt"
if grep -F 'localhost:1420' "$ROOT/ios-binary-strings.txt"; then
  echo 'Refusing to package a development build' >&2
  exit 1
fi

PACKAGE_DIR=$(mktemp -d)
mkdir -p "$PACKAGE_DIR/Payload"
cp -R "$APP" "$PACKAGE_DIR/Payload/"
IPA="$ROOT/artifacts/HGhub_${VERSION}_ios.ipa"
(cd "$PACKAGE_DIR" && ditto -c -k --sequesterRsrc --keepParent Payload "$IPA")
unzip -tq "$IPA"
unzip -Z1 "$IPA" | grep -Fx 'Payload/HGhub.app/Info.plist' >/dev/null
echo "Packaged $IPA ($BUNDLE_ID)"
