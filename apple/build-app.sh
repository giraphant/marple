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

# MLX looks for `default.metallib` at the package root so 深度 (semantic) mode
# can load its Metal kernels. The file is gitignored (~3 MB binary blob), so a
# fresh worktree won't have one. Search in this preference order and copy in:
#   1. The mlx-swift SPM resource bundle in `.build` (when MLX's metal pass
#      actually ran in this checkout).
#   2. Any sibling git worktree that already has it at its package root
#      (typically `main`, which is where the file usually ends up first).
# If neither exists, warn and keep going — 快速 / 平衡 modes don't need it.
if [ ! -f default.metallib ]; then
    candidates=(
        "$PKG_ROOT/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        ".build/arm64-apple-macosx/release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
    )
    # Fall back to any other worktree's package-root copy.
    HERE_APPLE="$(pwd)"
    while IFS= read -r wt; do
        cand="$wt/apple/default.metallib"
        if [ -f "$cand" ] && [ "$wt/apple" != "$HERE_APPLE" ]; then
            candidates+=("$cand")
        fi
    done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

    for cand in "${candidates[@]}"; do
        if [ -f "$cand" ]; then
            echo "Bootstrapping default.metallib from $cand"
            cp "$cand" default.metallib
            break
        fi
    done
    if [ ! -f default.metallib ]; then
        echo "WARNING: no default.metallib located — 深度 mode will crash at first query." >&2
    fi
fi

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
