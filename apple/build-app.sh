#!/bin/bash
# Build Marple as a proper .app bundle so macOS picks up the icon in the Dock.
set -euo pipefail
cd "$(dirname "$0")"

# CONFIG=debug (default, dev) or release. Selects the swift build flag and the
# matching .build output dir. SIGN=1 enables Developer ID + hardened-runtime
# codesigning (release/dist); unset keeps the old unsigned dev bundle.
CONFIG="${CONFIG:-debug}"
PKG_ROOT=".build/arm64-apple-macosx/$CONFIG"
# Bundle output dir. QUA-199: defaults to a local-volume path, NOT the repo
# dir — the repo lives under ~/Documents (iCloud), and the File Provider keeps
# re-stamping com.apple.FinderInfo onto a synced .app between our `xattr -cr`
# and codesign, which codesign rejects ("resource fork, Finder information,
# or similar detritus not allowed"). `make dist` overrides it to its own
# off-iCloud staging dir.
APP_DIR="${APP_DIR:-$HOME/Library/Caches/marple-dev/Marple.app}"
APP="$APP_DIR/Contents"
APPICONSET="Sources/Marple/Resources/Assets.xcassets/AppIcon.appiconset"
BUNDLE_ID="com.marple.app"
ENTITLEMENTS="Resources/Marple.entitlements"
# Marketing version from the VERSION file (source of truth); build number is the
# monotonic commit count so notarytool accepts repeat submissions of one version.
VERSION="${VERSION:-$(cat VERSION)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "Building ($CONFIG)..."
if [ "$CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi

# MLX looks for `default.metallib` at the package root so 深度 (semantic) mode
# can load its Metal kernels. The file is gitignored (~3 MB binary blob), so a
# fresh worktree won't have one. Search in this preference order and copy in:
#   1. The mlx-swift SPM resource bundle in `.build` (when MLX's metal pass
#      actually ran in this checkout).
#   2. Any sibling git worktree that already has it at its package root
#      (typically `main`, which is where the file usually ends up first).
# If neither exists, fail closed: a bundled app without MLX kernels can hard-crash
# on the first 深度 query. Set MARPLE_SKIP_METALLIB=1 for 快速 / 平衡-only builds.
if [ ! -f default.metallib ]; then
    candidates=(
        "$PKG_ROOT/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        "$PKG_ROOT/mlx-swift_Cmlx.bundle/Contents/Resources/mlx.metallib"
        "$PKG_ROOT/mlx.metallib"
        ".build/arm64-apple-macosx/release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        ".build/arm64-apple-macosx/release/mlx-swift_Cmlx.bundle/Contents/Resources/mlx.metallib"
        ".build/arm64-apple-macosx/release/mlx.metallib"
    )
    # Fall back to any other worktree's package-root copy.
    HERE_APPLE="$(pwd)"
    while IFS= read -r wt; do
        for name in default.metallib mlx.metallib; do
            cand="$wt/apple/$name"
            if [ -f "$cand" ] && [ "$wt/apple" != "$HERE_APPLE" ]; then
                candidates+=("$cand")
            fi
        done
    done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

    for cand in "${candidates[@]}"; do
        if [ -f "$cand" ]; then
            echo "Bootstrapping default.metallib from $cand"
            cp "$cand" default.metallib
            break
        fi
    done
    if [ ! -f default.metallib ]; then
        if [ "${MARPLE_SKIP_METALLIB:-}" = "1" ]; then
            echo "WARNING: no default.metallib located — 深度 mode will be disabled." >&2
        else
            echo "ERROR: no default.metallib located; refusing to build a 深度-crashable app." >&2
            echo "Install/build the MLX Metal kernels, or rerun with MARPLE_SKIP_METALLIB=1 for 快速 / 平衡-only iteration." >&2
            exit 1
        fi
    fi
fi

echo "Assembling .app bundle..."
rm -rf "$APP_DIR"
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
elif [ "${MARPLE_SKIP_METALLIB:-}" = "1" ]; then
    echo "WARNING: default.metallib missing — 深度 mode will be disabled in the bundled .app." >&2
else
    echo "ERROR: default.metallib missing after bootstrap; refusing to build a 深度-crashable app." >&2
    exit 1
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
  <!-- The app declares itself zh-Hans-localized so AppKit's standard menus
       (File/Edit/View/Window/Help + their items) render in Chinese instead of
       falling back to English next to our Chinese custom menus. -->
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
  </array>
  <key>CFBundleExecutable</key><string>Marple</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Marple</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
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

# Codesign for release/dist. Sign inner-out (nested marple-cli first, then the
# main executable, then the .app wrapper) with hardened runtime — `--deep` is
# deprecated and unreliable for notarization. CODESIGN_IDENTITY is the Developer
# ID, passed in by the Makefile from Makefile.local. Resources (mlx.metallib,
# .icns) are data, not code, so they need no separate signing.
if [ "${SIGN:-}" = "1" ]; then
    : "${CODESIGN_IDENTITY:?SIGN=1 requires CODESIGN_IDENTITY (set DEVELOPER_ID_IDENTITY in Makefile.local)}"
    echo "Signing with: $CODESIGN_IDENTITY"
    # Strip resource forks / Finder info / quarantine xattrs that codesign
    # rejects ("resource fork, Finder information, or similar detritus").
    xattr -cr "$APP_DIR"
    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" "$APP/MacOS/marple-cli"
    # mlx.metallib lives in MacOS/ (colocated lookup), so codesign treats it as
    # nested code that must be signed before the wrapper — it's data, not an
    # executable, so no hardened-runtime option, just a timestamped signature.
    if [ -f "$APP/MacOS/mlx.metallib" ]; then
        codesign --force --timestamp \
            --sign "$CODESIGN_IDENTITY" "$APP/MacOS/mlx.metallib"
    fi
    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" "$APP/MacOS/Marple"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" "$APP_DIR"
    codesign --verify --strict --verbose=2 "$APP_DIR"
else
    # QUA-190: dev builds must still be sealed as a *bundle*, not just left with
    # the bare ad-hoc signature `swift build` stamps on the executable. An
    # unsealed bundle reports `Info.plist=not bound` and carries no Designated
    # Requirement, so macOS TCC has no stable identity to attach the "allow
    # Documents access" grant to — it re-prompts on every file the vault indexer
    # touches (the user sees an endless approve→prompt→approve loop). Ad-hoc
    # signing the whole bundle inner-out seals it and gives a cdhash-based DR
    # that TCC can record consent against. cdhash changes per rebuild, so expect
    # one fresh prompt after each rebuild — but no within-session loop.
    # Strip resource forks / Finder info the iCloud File Provider stamps onto the
    # copied binary; codesign rejects them ("detritus not allowed"). Mirrors the
    # SIGN=1 branch above — dev builds on a synced tree need it too.
    xattr -cr "$APP_DIR"
    codesign --force --sign - "$APP/MacOS/marple-cli"
    if [ -f "$APP/MacOS/mlx.metallib" ]; then
        codesign --force --sign - "$APP/MacOS/mlx.metallib"
    fi
    codesign --force --sign - "$APP/MacOS/Marple"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
fi

echo "Done: $APP_DIR (v$VERSION build $BUILD)"
echo "Run with:  open \"$APP_DIR\""

# Release builds are distributed via the DMG / Homebrew cask, which puts
# marple-cli on PATH — so only the dev (debug) flow self-symlinks here.
if [ "$CONFIG" = "release" ]; then
    exit 0
fi

# QUA-107: install / refresh the marple-cli symlink so AI agents can call it
# by bare name. We symlink into the bundle so every rebuild stays current.
# Try a user-writable PATH dir first (no sudo); fall back to printing a manual
# install command if nothing on PATH is writable.
# QUA-199: $APP_DIR may be absolute (the default cache path) or relative —
# only prefix $(pwd) for the relative case, or the link target doubles up.
case "$APP_DIR" in
    /*) CLI_SRC="$APP/MacOS/marple-cli" ;;
    *)  CLI_SRC="$(pwd)/$APP/MacOS/marple-cli" ;;
esac
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
