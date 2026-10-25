#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${AQUA_INSTALLER_OUTPUT_DIR:-${TMPDIR:-/tmp}/AquaInstallerBuild}"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${TMPDIR:-/tmp}/AquaInstallerRust}"
BRIDGE_OUTPUT="$OUTPUT_DIR/signing-bridge"
APP_PATH="$OUTPUT_DIR/Aqua Installer.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$OUTPUT_DIR" "$BRIDGE_OUTPUT"
for RUST_TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    LIBRARY="$CARGO_TARGET_DIR/$RUST_TARGET/release/libsidepair_signing_bridge.a"
    test -f "$LIBRARY" || {
        echo "Missing Rust signing bridge: $LIBRARY" >&2
        exit 1
    }
done

lipo -create \
    "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libsidepair_signing_bridge.a" \
    "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/libsidepair_signing_bridge.a" \
    -output "$BRIDGE_OUTPUT/libsidepair_signing_bridge.a"

for ARCH in arm64 x86_64; do
    swiftc \
        -O \
        -swift-version 5 \
        -target "$ARCH-apple-macosx14.0" \
        -sdk "$SDK_PATH" \
        "$SCRIPT_DIR"/Sources/*.swift \
        -L "$BRIDGE_OUTPUT" \
        -lsidepair_signing_bridge \
        -lc++ \
        -lz \
        -framework Security \
        -framework CoreFoundation \
        -framework SystemConfiguration \
        -framework CFNetwork \
        -framework Network \
        -o "$OUTPUT_DIR/AquaInstaller-$ARCH"
done

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$SCRIPT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
lipo -create \
    "$OUTPUT_DIR/AquaInstaller-arm64" \
    "$OUTPUT_DIR/AquaInstaller-x86_64" \
    -output "$APP_PATH/Contents/MacOS/AquaInstaller"
chmod 755 "$APP_PATH/Contents/MacOS/AquaInstaller"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "Built universal Aqua Installer: $APP_PATH"
