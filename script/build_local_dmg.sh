#!/usr/bin/env bash
set -euo pipefail

# Builds a distributable-but-UNNOTARIZED OpenUsage.dmg for handing to colleagues on the same team,
# without an Apple Developer Program membership.
#
# How this differs from script/release.sh (the real, public release path):
#   - Signed ad-hoc (`codesign --sign -`) instead of with a Developer ID identity, and never notarized.
#     Recipients must clear the quarantine flag once — see docs/local-distribution.md.
#   - No iCloud entitlement. That capability needs a provisioning profile from a paid account; without
#     it the app runs fine and only iCloud Sync is unavailable (it reports "unavailable" and every other
#     feature, including every provider, works normally).
#   - No Sparkle feed (no SUFeedURL). Deliberate: this build carries in-house providers that the public
#     appcast's builds do not, so it must never silently auto-update itself into the upstream app.
#     Ship a new DMG to update.
#
# Usage: script/build_local_dmg.sh
# Env:   OPENUSAGE_VERSION  version string baked into the bundle. Default: 0.7.7-local
#        BUNDLE_ID          default com.robinebers.openusage.local — its own id, so installing this
#                           build alongside an official OpenUsage keeps the two apps' settings apart.
#        UNIVERSAL=1        build a universal (arm64 + x86_64) binary for Intel Macs too. Default:
#                           this Mac's own architecture only (much faster).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="OpenUsage"
BUNDLE_ID="${BUNDLE_ID:-com.robinebers.openusage.local}"
MIN_SYSTEM_VERSION="15.0"
VERSION="${OPENUSAGE_VERSION:-0.7.7-local}"
BUILD="$(git rev-list --count HEAD)"
DMG_NAME="$APP_NAME-$VERSION.dmg"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_BINARY="$APP_HELPERS/openusage"
DMG_PATH="$DIST_DIR/$DMG_NAME"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-}" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> building $APP_NAME $VERSION ($BUILD)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product OpenUsage
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product openusage-cli
BUILD_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_CLI_BINARY="$BUILD_DIR/openusage-cli"
[ -x "$BUILD_BINARY" ] || { echo "missing built binary: $BUILD_BINARY" >&2; exit 1; }
[ -x "$BUILD_CLI_BINARY" ] || { echo "missing built CLI: $BUILD_CLI_BINARY" >&2; exit 1; }

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY" "$CLI_BINARY"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CLI_BINARY"

# SwiftPM stamps LC_BUILD_VERSION's `sdk` with the deployment target (macOS 15), not the SDK it really
# compiled against, and macOS gates the modern Liquid Glass control appearance on that stamp. Restamp
# to 26.0 while keeping minos at MIN_SYSTEM_VERSION; re-signed below. Same as release.sh.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"

shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob
# SwiftPM's staged resource bundles carry read-only file modes, and `cp`/Finder preserve them all the
# way into the recipient's copy — where `xattr -dr com.apple.quarantine` (the documented un-quarantine
# step) then errors on every one of them. Make them writable here so that command runs clean.
chmod -R u+w "$APP_RESOURCES"

if [ -f "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" ]; then
  echo "==> installing prebuilt app icon"
  cp "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" "$APP_RESOURCES/Assets.car"
  [ -f "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" ] \
    && cp "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
  echo "==> compiling app icon"
  xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
    --app-icon AppIcon --enable-on-demand-resources NO --development-region en \
    --target-device mac --platform macosx --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --output-partial-info-plist /dev/null --output-format human-readable-text --errors --warnings
fi

# No SUFeedURL / SUPublicEDKey and no NSUbiquitousContainers: this build neither auto-updates nor
# claims an iCloud container it has no entitlement for.
cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The executable links Sparkle even with the updater dormant, so the framework still has to be embedded
# or the app won't launch.
#
# No `--options runtime` anywhere below, unlike release.sh. The hardened runtime enforces library
# validation, which requires the app and every framework it loads to share a Team ID — and an ad-hoc
# signature has no Team ID at all, so dyld refuses to map Sparkle and the app dies at launch. Hardened
# runtime is a notarization requirement; this build isn't notarized, so it simply doesn't apply.
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "-" ""

echo "==> signing ad-hoc (NOT notarized)"
codesign --force --sign - "$CLI_BINARY"
# Not --deep: Sparkle is signed above and must keep that signature.
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> building $DMG_PATH"
STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE"

echo "==> done"
echo "    DMG: $DMG_PATH"
echo "    This build is NOT notarized. Recipients must run, once after copying to /Applications:"
echo "      xattr -dr com.apple.quarantine /Applications/OpenUsage.app"
echo "    See docs/local-distribution.md."
