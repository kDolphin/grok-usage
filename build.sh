#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Grok Usage"
EXEC_NAME="GrokUsage"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"

echo "=== Building $APP_NAME ==="

# Prefer the Xcode SDK to avoid Command Line Tools SDK/compiler mismatches.
if [ -d "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]; then
    SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
else
    SDK="$(xcrun --show-sdk-path)"
    SWIFTC="swiftc"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# All Swift sources under Sources/GrokUsage (exclude generated AppVersion if present)
SWIFT_FILES=()
while IFS= read -r f; do
    SWIFT_FILES+=("$f")
done < <(find "$PROJECT_DIR/Sources/GrokUsage" -name '*.swift' ! -name 'AppVersion.swift' | sort)
if [ ${#SWIFT_FILES[@]} -eq 0 ]; then
    echo "error: no Swift sources found" >&2
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
cp "$PROJECT_DIR/GrokUsage/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# App icon
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Localizations (PowerTop-style en + zh-Hans)
for lproj in en.lproj zh-Hans.lproj; do
    if [ -d "$PROJECT_DIR/GrokUsage/$lproj" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/$lproj"
        cp "$PROJECT_DIR/GrokUsage/$lproj/"*.strings "$APP_BUNDLE/Contents/Resources/$lproj/" 2>/dev/null || true
        echo "→ Bundled $lproj"
    fi
done

# Ad-hoc sign for local runs
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
