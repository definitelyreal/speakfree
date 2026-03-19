#!/bin/bash
set -e

APP="speakfree.app"
# Find the real binary path
WHISPER_BIN=$(python3 -c "import os; print(os.path.realpath('/opt/homebrew/bin/whisper-cli'))")
WHISPER_LIB_DIR=$(dirname "$WHISPER_BIN")/../lib

echo "Building speakfree..."
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
# (binary links against e.g. libwhisper.1.dylib, we ship libwhisper.1.8.3.dylib)
for real_dylib in "$APP/Contents/Frameworks"/*.dylib; do
    basename=$(basename "$real_dylib")
    # Strip the patch version: libfoo.1.8.3.dylib -> libfoo.1.dylib
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
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
