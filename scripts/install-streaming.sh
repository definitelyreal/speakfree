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

# Strip the Sparkle feed inherited from the production template. If left in place, the
# experimental app would poll the PRODUCTION appcast and could silently update itself
# into a stock release build, replacing the streaming experiment with prod. Deleting
# SUFeedURL (and disabling automatic checks) makes self-update impossible for this clone.
$PB -c "Delete :SUFeedURL" "$PLIST" 2>/dev/null || true
$PB -c "Delete :SUEnableAutomaticChecks" "$PLIST" 2>/dev/null || true

echo "Setting up isolated config dir ($STREAM_CONFIG)..."
mkdir -p "$STREAM_CONFIG"
# Reuse production models (large, effectively read-only) via symlink — no re-download.
# Only link if the source actually exists; otherwise skip (a dangling symlink would
# shadow the app's own model-download path with a broken entry).
if [ -e "$STREAM_CONFIG/models" ]; then
    : # already present
elif [ -d "$HOME/.config/speakfree/models" ]; then
    ln -s "$HOME/.config/speakfree/models" "$STREAM_CONFIG/models"
else
    echo "  (no production models dir at ~/.config/speakfree/models; skipping symlink, app will download models itself)"
fi
# Seed config/glossary/overrides from production so it starts configured (separate copies;
# edits here never affect production).
for f in config.json vocabulary.txt overrides.json; do
    [ -f "$STREAM_CONFIG/$f" ] || cp "$HOME/.config/speakfree/$f" "$STREAM_CONFIG/$f" 2>/dev/null || true
done

echo "Re-signing (inside-out: nested code first, then the app, no --deep)..."
# --deep is deprecated and applies the app's entitlements/flags to every nested item,
# which is wrong for frameworks. Sign inside-out instead: Sparkle's own nested pieces
# (XPC services, Autoupdate, Updater.app), then the frameworks/dylibs, then the app.
# Entitlements go on the app bundle ONLY; they don't belong on frameworks.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    for xpc in "$SPARKLE"/Versions/*/XPCServices/*.xpc; do
        [ -e "$xpc" ] && codesign --force --options runtime --sign "$SIGN_ID" "$xpc"
    done
    for nested in "$SPARKLE"/Versions/*/Autoupdate "$SPARKLE"/Versions/*/Updater.app; do
        [ -e "$nested" ] && codesign --force --options runtime --sign "$SIGN_ID" "$nested"
    done
fi
for fw in "$APP/Contents/Frameworks"/*; do
    [ -e "$fw" ] && codesign --force --options runtime --sign "$SIGN_ID" "$fw"
done
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

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
echo "  Config: $STREAM_CONFIG  (config + recordings isolated; whisper models symlinked from production)"
echo "  NOTE: distinct TCC identity — grant Accessibility + Microphone on first launch."
echo "  NOTE: Sparkle feed removed; this app can never self-update into a production build."
echo "  NOTE: the Parakeet/FluidAudio model cache (~/Library/Application Support/FluidAudio/Models/)"
echo "        is SHARED with production (keyed by \$HOME, not by config dir). This app's"
echo "        cache self-heal and prefetch can delete/replace files there. Never run both apps"
echo "        at once, and expect a possible ~600MB re-fetch by production if this app purges"
echo "        a model bundle."
echo "  NOTE: shares the global hotkey with production — run one at a time."
