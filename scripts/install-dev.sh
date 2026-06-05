#!/bin/bash
# install-dev.sh — build + install for local testing WITHOUT full DMG/notarize cycle.
# Always applies the libwhisper rpath fix so the installed app doesn't crash.
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/speakfree.app"
SIGN_ID="Developer ID Application: Michael Morgenstern (AZ53Y7V4UZ)"
ENTITLEMENTS="$(dirname "$0")/speakfree.entitlements"

cd "$REPO_DIR"

echo "Building (debug)..."
swift build

BINARY=".build/debug/speakfree"

# Verify the rpath fix is needed and apply it
WHISPER_REF=$(otool -L "$BINARY" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
if [ -n "$WHISPER_REF" ] && [ "$WHISPER_REF" != "@rpath/libwhisper.1.dylib" ]; then
    echo "Fixing libwhisper rpath ($WHISPER_REF → @rpath/libwhisper.1.dylib)..."
    install_name_tool -change "$WHISPER_REF" "@rpath/libwhisper.1.dylib" "$BINARY"
fi

echo "Stopping existing speakfree..."
pkill -x speakfree 2>/dev/null || true
sleep 0.5

echo "Installing to $APP..."
cp "$BINARY" "$APP/Contents/MacOS/speakfree"

echo "Re-signing..."
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"

echo "Launching..."
open "$APP"

echo "Done. Tail logs: tail -f ~/.config/speakfree/logs/\$(ls -t ~/.config/speakfree/logs/ | head -1)"
