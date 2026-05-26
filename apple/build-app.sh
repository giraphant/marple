#!/bin/bash
# Build Marple as a proper .app bundle so macOS picks up the icon in the Dock.
set -euo pipefail
cd "$(dirname "$0")"

PKG_ROOT=.build/arm64-apple-macosx/debug
APP="Marple.app/Contents"
ICONSET="Artwork/FinalIcon/Marple.iconset"
BUNDLE_ID="com.marple.app"
VERSION="1.0"

echo "Building..."
swift build

echo "Assembling .app bundle..."
rm -rf Marple.app
mkdir -p "$APP/MacOS"
mkdir -p "$APP/Resources"

# Executable
cp "$PKG_ROOT/Marple" "$APP/MacOS/Marple"

# Icon: iconset → icns (iconutil is the reliable way outside Xcode)
iconutil -c icns "$ICONSET" -o "$APP/Resources/AppIcon.icns"

# Info.plist
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Marple</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Marple</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><true/>
  <key>NSSupportsSuddenTermination</key><true/>
</dict>
</plist>
PLIST

echo "Done: Marple.app"
echo "Run with:  open Marple.app"
