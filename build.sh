#!/bin/zsh
# Builds DVD Toolbox.app: the SwiftUI app in Sources/, wrapped into a bundle and signed.
#
#   ./build.sh && open "build/DVD Toolbox.app"
#
# DVD_ID, DVD_NAME and DVD_OUT build it under another id, name and folder (selftest.sh's, so the test
# never touches the real app's settings or Keychain items). DVD_SIGN picks the signing identity ("-"
# for ad hoc); by default an Apple Development identity from the keychain, else ad hoc. DVD_VERSION
# and DVD_BUILD set the version numbers (release.sh); DVD_KEYCHAIN names the keychain the identity is
# in when it is not one of the searched ones.
set -euo pipefail
cd "${0:A:h}"

ID=${DVD_ID:-xyz.tiresia.dvdtoolbox}
NAME=${DVD_NAME:-DVD Toolbox}
VERSION=${DVD_VERSION:-0.1.0}
BUILD=${DVD_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
OUT=${DVD_OUT:-build}
APP="$OUT/$NAME.app"

# -file-prefix-map keeps this folder's path out of the binary (#file strings, debug info); the release
# script checks that no home folder is in the app
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$PWD=/src" 2>&1 | grep -E "error|warning: unre|Build complete" | tail -5
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DVDToolbox "$APP/Contents/MacOS/DVDToolbox"
strip -S "$APP/Contents/MacOS/DVDToolbox"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ATS is relaxed because Jellyfin may be reached by its Tailscale address over plain http, which
# WireGuard already encrypts.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>DVD Toolbox</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>DVDToolbox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSRemovableVolumesUsageDescription</key><string>DVD Toolbox reads the DVD in the drive to rip it.</string>
</dict></plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

cat > "$OUT/DVDToolbox.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><false/>
</dict></plist>
ENT

# an Apple Development identity if the keychain has one, ad hoc otherwise; none is written into
# this repository
IDENTITY=${DVD_SIGN:-$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]*\) "Apple Development.*/\1/p' | head -1)}
KEYCHAIN=(); [[ -n ${DVD_KEYCHAIN:-} ]] && KEYCHAIN=(--keychain "$DVD_KEYCHAIN")
codesign --force --options runtime --entitlements "$OUT/DVDToolbox.entitlements" --sign "${IDENTITY:--}" "${KEYCHAIN[@]}" "$APP"
[[ -n $IDENTITY ]] || echo "note: signed ad hoc; the Keychain asks again after each build"
echo "built $APP"
