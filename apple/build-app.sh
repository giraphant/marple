#!/bin/bash
# Build Marple as a proper .app bundle so macOS picks up the icon in the Dock.
set -euo pipefail
cd "$(dirname "$0")"

PKG_ROOT=.build/arm64-apple-macosx/debug
APP="Marple.app/Contents"
APPICONSET="Sources/Marple/Resources/Assets.xcassets/AppIcon.appiconset"
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

# QUA-107: ship marple-cli inside the bundle so it always tracks the GUI build.
# A symlink under /usr/local/bin (created below) points at this copy.
cp "$PKG_ROOT/marple-cli" "$APP/MacOS/marple-cli"

# Ship MLX Metal kernels inside the bundle. `swift run` finds them via the
# SwiftPM resource bundle that sits next to the .build binary, but once we
# repackage as a .app that sibling bundle is gone and `open` launches with
# CWD=/, so MLX's `METAL_PATH=default.metallib` fallback also misses. Drop a
# copy next to the executable as `mlx.metallib` — MLX's first lookup is
# `<binary_dir>/mlx.metallib` (load_colocated_library), so this resolves
# before any of the bundle/CWD paths are tried.
if [ -f default.metallib ]; then
    cp default.metallib "$APP/MacOS/mlx.metallib"
else
    echo "WARNING: default.metallib missing — 深度 mode will crash in the bundled .app." >&2
fi

# Icon: build a .iconset from the appiconset PNGs in xcassets, then run
# iconutil. The xcassets ships explicit @2x renditions for every slot, so we
# pair each source PNG with its iconutil slot name directly.
TMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP_ICONSET"
cp "$APPICONSET/16x16-Marple.png"      "$TMP_ICONSET/icon_16x16.png"
cp "$APPICONSET/16x16-Marple@2x.png"   "$TMP_ICONSET/icon_16x16@2x.png"
cp "$APPICONSET/32x32-Marple.png"      "$TMP_ICONSET/icon_32x32.png"
cp "$APPICONSET/32x32-Marple@2x.png"   "$TMP_ICONSET/icon_32x32@2x.png"
cp "$APPICONSET/128x128-Marple.png"    "$TMP_ICONSET/icon_128x128.png"
cp "$APPICONSET/128x128-Marple@2x.png" "$TMP_ICONSET/icon_128x128@2x.png"
cp "$APPICONSET/256x256-Marple.png"    "$TMP_ICONSET/icon_256x256.png"
cp "$APPICONSET/256x256-Marple@2x.png" "$TMP_ICONSET/icon_256x256@2x.png"
cp "$APPICONSET/512x512-Marple.png"    "$TMP_ICONSET/icon_512x512.png"
cp "$APPICONSET/512x512-Marple@2x.png" "$TMP_ICONSET/icon_512x512@2x.png"
iconutil -c icns "$TMP_ICONSET" -o "$APP/Resources/AppIcon.icns"
rm -rf "$(dirname "$TMP_ICONSET")"

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
  <!-- QUA-107: marple-cli falls back to this URL scheme to cold-start the app
       when its Unix socket isn't reachable yet. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.marple.cli</string>
      <key>CFBundleURLSchemes</key>
      <array><string>marple</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "Done: Marple.app"
echo "Run with:  open Marple.app"

# QUA-107: install / refresh the marple-cli symlink so AI agents can call it
# by bare name. We symlink into the bundle so every rebuild stays current.
# Try a user-writable PATH dir first (no sudo); fall back to printing a manual
# install command if nothing on PATH is writable.
CLI_SRC="$(pwd)/$APP/MacOS/marple-cli"
CLI_INSTALLED=0
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    if [ -d "$d" ] && [ -w "$d" ]; then
        ln -sf "$CLI_SRC" "$d/marple-cli"
        echo "Linked: $d/marple-cli -> $CLI_SRC"
        CLI_INSTALLED=1
        break
    fi
done
if [ "$CLI_INSTALLED" -eq 0 ]; then
    echo ""
    echo "marple-cli built but not linked to PATH. To install:"
    echo "  sudo ln -sf \"$CLI_SRC\" /usr/local/bin/marple-cli"
fi
