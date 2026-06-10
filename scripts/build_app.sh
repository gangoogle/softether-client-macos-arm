#!/bin/bash
set -euo pipefail

# ================================================================
#  build_app.sh — Build & assemble SoftEtherVPN.app (macOS ARM)
#
#  Usage:  ./scripts/build_app.sh [--debug]
#
#  Output: SoftEtherVPN.app in the project root.
#  The .app bundles vpnclient, vpncmd, hamcore.se2, lang.config,
#  and all required ARM64 .dylib dependencies into
#  Contents/Resources/Runtime/ — fully self-contained.
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="SoftEtherVPN"
BUNDLE_NAME="SoftEtherVPN.app"
CONFIG="${1:-release}"
BUILD_FLAGS="-c release"
if [ "$CONFIG" = "--debug" ]; then
    BUILD_FLAGS="-c debug"
fi

RES_DIR="$BUNDLE_NAME/Contents/Resources/Runtime"

echo "=========================================="
echo " Building $APP_NAME ($CONFIG)"
echo "=========================================="

# ---- 1. Verify prerequisites ----
if ! command -v swift &>/dev/null; then
    echo "❌ swift not found. Install Xcode Command Line Tools."
    exit 1
fi

SWIFT_VER=$(swift --version | head -1)
echo "→ Swift: $SWIFT_VER"

# ---- 2. Verify required system dylibs exist ----
HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
LIBSODIUM="$HOMEBREW_PREFIX/opt/libsodium/lib/libsodium.26.dylib"
LIBSSL="$HOMEBREW_PREFIX/opt/openssl@3/lib/libssl.3.dylib"
LIBCRYPTO="$HOMEBREW_PREFIX/opt/openssl@3/lib/libcrypto.3.dylib"
LIBCEDAR="$PROJECT_DIR/bin/libcedar.dylib"
LIBMAYAQUA="$PROJECT_DIR/bin/libmayaqua.dylib"

MISSING=()
for lib in "$LIBSODIUM" "$LIBSSL" "$LIBCRYPTO" "$LIBCEDAR" "$LIBMAYAQUA"; do
    if [ ! -f "$lib" ]; then
        MISSING+=("$lib")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "❌ Missing required dylibs:"
    for m in "${MISSING[@]}"; do echo "   $m"; done
    echo ""
    echo "   Install with: brew install libsodium openssl@3"
    exit 1
fi
echo "→ All required dylibs found"

# ---- 3. Build the Swift package ----
echo ""
echo "→ Compiling with: swift build $BUILD_FLAGS --arch arm64"
swift build $BUILD_FLAGS --arch arm64 2>&1 || {
    echo "❌ Build failed"
    exit 1
}

# ---- 4. Locate the compiled executable ----
BUILD_DIR=".build/arm64-apple-macosx"
if [ ! -d "$BUILD_DIR" ]; then
    BUILD_DIR=".build"
fi

EXEC_SRC=""
for dir in "$BUILD_DIR/$CONFIG" "$BUILD_DIR/debug"; do
    if [ -x "$dir/$APP_NAME" ]; then
        EXEC_SRC="$dir/$APP_NAME"
        break
    fi
done

if [ -z "$EXEC_SRC" ]; then
    echo "❌ Could not find compiled executable ($APP_NAME)"
    echo "   Searched in $BUILD_DIR/{release,debug}/"
    exit 1
fi
echo "→ Executable: $EXEC_SRC"

# ---- 5. Assemble the .app bundle ----
echo ""
echo "→ Assembling $BUNDLE_NAME"

rm -rf "$BUNDLE_NAME"
mkdir -p "$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$RES_DIR"

# Copy Swift executable
cp "$EXEC_SRC" "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"

# ---- 6. Copy runtime files ----
echo "→ Copying runtime files"

# Core binaries (Mach-O)
cp bin/vpnclient "$RES_DIR/"
cp bin/vpncmd    "$RES_DIR/"
chmod +x "$RES_DIR/vpnclient" "$RES_DIR/vpncmd"

# Resource files
cp bin/hamcore.se2 "$RES_DIR/"
if [ -f bin/lang.config ]; then
    cp bin/lang.config "$RES_DIR/"
fi

# ---- 7. Copy & fix dylib dependencies ----
echo "→ Bundling dylib dependencies"

# Project-bundled dylibs
cp "$LIBCEDAR"   "$RES_DIR/"
cp "$LIBMAYAQUA" "$RES_DIR/"

# Homebrew dylibs
cp "$LIBSODIUM"  "$RES_DIR/libsodium.26.dylib"
cp "$LIBSSL"     "$RES_DIR/libssl.3.dylib"
cp "$LIBCRYPTO"  "$RES_DIR/libcrypto.3.dylib"

# Fix install names (id) so they're location-independent
echo "→ Fixing dylib install names"
for dylib in "$RES_DIR"/*.dylib; do
    name=$(basename "$dylib")
    install_name_tool -id "@loader_path/$name" "$dylib" 2>/dev/null || true
done

# Fix load commands for each file in Runtime/
# All binaries and dylibs go into the same flat directory,
# so @loader_path always resolves to $RES_DIR.
echo "→ Fixing load commands"

# Map of old_path → new_path (as parallel arrays for bash 3.2 compat)
FIX_OLD=(
    "@rpath/libcedar.dylib"
    "@rpath/libmayaqua.dylib"
    "$LIBSODIUM"
    "$LIBSSL"
    "$LIBCRYPTO"
)
FIX_NEW=(
    "@loader_path/libcedar.dylib"
    "@loader_path/libmayaqua.dylib"
    "@loader_path/libsodium.26.dylib"
    "@loader_path/libssl.3.dylib"
    "@loader_path/libcrypto.3.dylib"
)

# Apply fixups to every file in Runtime/
for file in "$RES_DIR/vpnclient" "$RES_DIR/vpncmd" "$RES_DIR"/*.dylib; do
    if [ ! -f "$file" ]; then continue; fi
    for i in "${!FIX_OLD[@]}"; do
        old_path="${FIX_OLD[$i]}"
        new_path="${FIX_NEW[$i]}"
        if otool -L "$file" 2>/dev/null | grep -qF "$old_path"; then
            install_name_tool -change "$old_path" "$new_path" "$file" 2>/dev/null || true
        fi
    done
done

# Also fix any remaining Homebrew/Cellar absolute paths to @loader_path
echo "→ Fixing remaining Homebrew paths"
for file in "$RES_DIR/vpnclient" "$RES_DIR/vpncmd" "$RES_DIR"/*.dylib; do
    if [ ! -f "$file" ]; then continue; fi
    # Extract all load paths, filter for Homebrew/Cellar absolute paths
    otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r load_path; do
        case "$load_path" in
            /opt/homebrew/*|/usr/local/Homebrew/*)
                lib_name=$(basename "$load_path")
                if [ -f "$RES_DIR/$lib_name" ]; then
                    echo "     $file: $load_path → @loader_path/$lib_name"
                    install_name_tool -change "$load_path" "@loader_path/$lib_name" "$file" 2>/dev/null || true
                fi
                ;;
            *@rpath/*)
                lib_name=$(basename "$load_path")
                if [ -f "$RES_DIR/$lib_name" ]; then
                    echo "     $file: $load_path → @loader_path/$lib_name"
                    install_name_tool -change "$load_path" "@loader_path/$lib_name" "$file" 2>/dev/null || true
                fi
                ;;
        esac
    done
done

# ---- 8. Remove any leftover rpath entries that point to absolute paths ----
for bin in "$RES_DIR/vpnclient" "$RES_DIR/vpncmd"; do
    # Delete common build-machine-specific rpaths if present.
    install_name_tool -delete_rpath "$PROJECT_DIR/build_src/build" "$bin" 2>/dev/null || true
    install_name_tool -delete_rpath "$PROJECT_DIR/bin" "$bin" 2>/dev/null || true
done

# ---- 9. Ensure bundled Runtime stays a clean read-only template ----
echo "→ Cleaning mutable runtime state from bundle template"
rm -f "$RES_DIR"/vpn_client.config
rm -f "$RES_DIR"/.Global*
rm -f "$RES_DIR"/.pid_*
rm -f "$RES_DIR"/.ctl_*
rm -rf "$RES_DIR"/client_log
rm -rf "$RES_DIR"/backup.vpn_client.config

# ---- 10. Create Info.plist ----
echo "→ Writing Info.plist"

cat > "$BUNDLE_NAME/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SoftEtherVPN</string>
    <key>CFBundleIdentifier</key>
    <string>com.softether.vpnclient.gui</string>
    <key>CFBundleName</key>
    <string>SoftEther VPN</string>
    <key>CFBundleDisplayName</key>
    <string>SoftEther VPN Client</string>
    <key>CFBundleVersion</key>
    <string>2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# ---- 11. Ad-hoc code sign ----
echo "→ Signing with ad-hoc identity"
# Sign dylibs first, then the binaries, then the app bundle
for dylib in "$RES_DIR"/*.dylib; do
    codesign --force --sign - "$dylib" 2>/dev/null || true
done
for bin in "$RES_DIR/vpnclient" "$RES_DIR/vpncmd"; do
    codesign --force --sign - "$bin" 2>/dev/null || true
done
codesign --force --deep --sign - "$BUNDLE_NAME" 2>/dev/null || {
    echo "⚠ codesign not available (ignored)"
}

# ---- 12. Summary ----
echo ""
echo "=========================================="
echo " ✅ Build complete"
echo "=========================================="
echo " App:    $PROJECT_DIR/$BUNDLE_NAME"
echo " Binary: $BUNDLE_NAME/Contents/MacOS/$APP_NAME"
echo ""

echo "Bundle contents:"
find "$BUNDLE_NAME" -type f | sed "s|^$BUNDLE_NAME|  → $BUNDLE_NAME|" | sort

echo ""
APP_SZ=$(du -sh "$BUNDLE_NAME" | cut -f1)
echo "Size: $APP_SZ"
echo ""
echo "To launch from Finder:   open $BUNDLE_NAME"
echo "To launch from terminal: $BUNDLE_NAME/Contents/MacOS/$APP_NAME"
echo ""
echo "Note: First launch may require right-click → Open"
echo "      if not distributed through the App Store."
