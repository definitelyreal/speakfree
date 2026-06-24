#!/bin/bash
# install-streaming.sh — install the EXPERIMENTAL streaming engine as a SEPARATE app
# ("SpeakFree Streaming") with its own bundle id + config dir, so it runs side-by-side
# with the production speakfree.app and never touches its config / recordings / TCC.
#
# Usage: install-streaming.sh [build-only]
#   build-only = build + create the bundle + isolated config, but do NOT pkill/launch
#                (use to set it up without disturbing a running production app).
set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROD_APP="/Applications/speakfree.app"
APP="/Applications/SpeakFree Streaming.app"
BUNDLE_ID="com.definitelyreal.speakfree.streaming"
SIGN_ID="Developer ID Application: Michael Morgenstern (AZ53Y7V4UZ)"
ENTITLEMENTS="$(dirname "$0")/speakfree.entitlements"
STREAM_CONFIG="$HOME/.config/speakfree-streaming"
MODE="${1:-launch}"
cd "$REPO_DIR"

[ -d "$PROD_APP" ] || { echo "FATAL: $PROD_APP not found — it's the bundle template. Build/install production first." >&2; exit 1; }

echo "Building (debug)..."
xcrun swift build
BINARY=".build/debug/speakfree"
WHISPER_REF=$(otool -L "$BINARY" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
if [ -n "$WHISPER_REF" ] && [ "$WHISPER_REF" != "@rpath/libwhisper.1.dylib" ]; then
    echo "Fixing libwhisper rpath..."
    install_name_tool -change "$WHISPER_REF" "@rpath/libwhisper.1.dylib" "$BINARY"
fi

echo "Creating streaming app bundle from production template..."
rm -rf "$APP"
cp -Rc "$PROD_APP" "$APP"
cp "$BINARY" "$APP/Contents/MacOS/speakfree"

echo "Rewriting bundle identity → $BUNDLE_ID ..."
PB=/usr/libexec/PlistBuddy
PLIST="$APP/Contents/Info.plist"
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
$PB -c "Set :CFBundleName SpeakFree Streaming" "$PLIST" 2>/dev/null || $PB -c "Add :CFBundleName string SpeakFree Streaming" "$PLIST"
$PB -c "Set :CFBundleDisplayName SpeakFree Streaming" "$PLIST" 2>/dev/null || $PB -c "Add :CFBundleDisplayName string SpeakFree Streaming" "$PLIST"

echo "Setting up isolated config dir ($STREAM_CONFIG)..."
mkdir -p "$STREAM_CONFIG"
# Reuse production models (large, effectively read-only) via symlink — no re-download.
[ -e "$STREAM_CONFIG/models" ] || ln -s "$HOME/.config/speakfree/models" "$STREAM_CONFIG/models"
# Seed config/glossary/overrides from production so it starts configured (separate copies;
# edits here never affect production).
for f in config.json vocabulary.txt overrides.json; do
    [ -f "$STREAM_CONFIG/$f" ] || cp "$HOME/.config/speakfree/$f" "$STREAM_CONFIG/$f" 2>/dev/null || true
done

echo "Re-signing..."
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"

if [ "$MODE" = "build-only" ]; then
    echo "build-only: not launching (production app left running)."
else
    echo "Stopping any running instance (shared executable name + global hotkey → one at a time)..."
    pkill -x speakfree 2>/dev/null || true
    sleep 0.5
    echo "Launching SpeakFree Streaming..."
    open "$APP"
fi

echo ""
echo "  App:    $APP  (bundle $BUNDLE_ID)"
echo "  Config: $STREAM_CONFIG  (config + recordings isolated; models symlinked from production)"
echo "  NOTE: distinct TCC identity — grant Accessibility + Microphone on first launch."
echo "  NOTE: shares the global hotkey with production — run one at a time."
