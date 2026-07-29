#!/bin/bash
set -euo pipefail

# PowerTop-style build: compile app target under GrokUsage/, emit .app + .zip
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$PROJECT_DIR/GrokUsage"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Grok Usage"
EXEC_NAME="GrokUsage"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"

echo "=== Building $APP_NAME ==="

if [ -d "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]; then
    SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
else
    SDK="$(xcrun --show-sdk-path)"
    SWIFTC="swiftc"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

SWIFT_FILES=()
while IFS= read -r f; do
    SWIFT_FILES+=("$f")
done < <(find "$APP_SRC" -name '*.swift' | sort)
if [ ${#SWIFT_FILES[@]} -eq 0 ]; then
    echo "error: no Swift sources under $APP_SRC" >&2
    exit 1
fi

echo "Compiling ${#SWIFT_FILES[@]} sources…"
"$SWIFTC" \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework ServiceManagement \
    -framework UserNotifications \
    -parse-as-library \
    -O \
    -o "$BUILD_DIR/$EXEC_NAME" \
    "${SWIFT_FILES[@]}"

echo "Creating app bundle…"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

mv "$BUILD_DIR/$EXEC_NAME" "$EXECUTABLE"
cp "$APP_SRC/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [ -f "$APP_SRC/Resources/AppIcon.icns" ]; then
    cp "$APP_SRC/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

for lproj in en.lproj zh-Hans.lproj; do
    if [ -d "$APP_SRC/$lproj" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/$lproj"
        cp "$APP_SRC/$lproj/"*.strings "$APP_BUNDLE/Contents/Resources/$lproj/" 2>/dev/null || true
        echo "→ Bundled $lproj"
    fi
done

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

ZIP_PATH="$BUILD_DIR/GrokUsage.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "=== Build complete ==="
echo "App bundle: $APP_BUNDLE"
echo "Zip archive: $ZIP_PATH"
echo ""
echo "To run: open \"$APP_BUNDLE\""
echo "Install: cp -R \"$APP_BUNDLE\" /Applications/"
