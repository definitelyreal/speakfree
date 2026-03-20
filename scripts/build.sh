#!/bin/bash
set -e

APP="speakfree.app"
VERSION=$(grep 'let version' Sources/OpenWisprLib/Version.swift | sed 's/.*"\(.*\)".*/\1/')
DMG="speakfree-${VERSION}.dmg"
SIGN_ID="Developer ID Application: Michael Morgenstern (AZ53Y7V4UZ)"

# Find the real binary path
WHISPER_BIN=$(python3 -c "import os; print(os.path.realpath('/opt/homebrew/bin/whisper-cli'))")
WHISPER_LIB_DIR=$(dirname "$WHISPER_BIN")/../lib

echo "Building speakfree v${VERSION}..."
swift build -c release

echo "Copying main binary..."
cp .build/release/speakfree "$APP/Contents/MacOS/speakfree"

echo "Bundling whisper-cli..."
mkdir -p "$APP/Contents/Frameworks"
cp "$WHISPER_BIN" "$APP/Contents/MacOS/whisper-cli"

# Copy real dylibs (not symlinks)
for dylib in "$WHISPER_LIB_DIR"/*.dylib; do
    if [ ! -L "$dylib" ]; then
        cp "$dylib" "$APP/Contents/Frameworks/"
    fi
done

# Create versioned symlinks so whisper-cli can find its dylibs by soname
for real_dylib in "$APP/Contents/Frameworks"/*.dylib; do
    basename=$(basename "$real_dylib")
    soname=$(echo "$basename" | sed 's/\([^0-9]*[0-9]*\)\.[0-9]*\.[0-9]*\.dylib$/\1.dylib/')
    if [ "$soname" != "$basename" ]; then
        ln -sf "$basename" "$APP/Contents/Frameworks/$soname"
    fi
done

# Fix rpath so whisper-cli finds its dylibs inside the bundle
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/whisper-cli" 2>/dev/null || true

echo "Signing..."
xattr -cr "$APP"
# Sign dylibs and whisper-cli first, then the app bundle
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Frameworks/"*.dylib
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/MacOS/whisper-cli"
codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"

echo "Building DMG..."
rm -f "$DMG"
create-dmg \
    --volname "speakfree" \
    --window-pos 200 120 \
    --window-size 560 340 \
    --background "scripts/dmg-background.png" \
    --icon-size 128 \
    --icon "speakfree.app" 140 170 \
    --hide-extension "speakfree.app" \
    --app-drop-link 420 170 \
    "$DMG" \
    "$APP"

echo "Notarizing..."
xcrun notarytool submit "$DMG" \
    --keychain-profile "speakfree-notary" \
    --wait

echo "Stapling..."
xcrun stapler staple "$DMG"

echo "Done: $APP"
echo "Done: $DMG (signed, notarized, stapled)"
