#!/bin/bash
set -euo pipefail

BINARY="${1:-.build/release/speakfree}"
APP_DIR="${2:-speakfree.app}"
VERSION="${3:-0.3.0}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/speakfree"
# swift build doesn't set @executable_path/../Frameworks rpath — add it so
# bundled frameworks (Sparkle, whisper dylibs) are found at runtime.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/speakfree" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cp "$REPO_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Bundle Sparkle.framework (required at runtime — binary links against it)
mkdir -p "$APP_DIR/Contents/Frameworks"
SPARKLE_FW="$REPO_DIR/.build/arm64-apple-macosx/release/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    SPARKLE_FW="$REPO_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [ -d "$SPARKLE_FW" ]; then
    cp -a "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/"
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>speakfree</string>
    <key>CFBundleIdentifier</key>
    <string>com.definitelyreal.speakfree</string>
    <key>CFBundleName</key>
    <string>speakfree</string>
    <key>CFBundleDisplayName</key>
    <string>speakfree</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>speakfree needs microphone access to record speech for transcription.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>speakfree uses screen capture for local OCR to improve transcription accuracy (opt-in).</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>speakfree uses Apple Events to paste text into remote desktop apps like Splashtop.</string>
</dict>
</plist>
PLIST

# Sign with the Developer ID when present, else ad-hoc. Ad-hoc signatures change
# identity on EVERY rebuild, so macOS treats each dev build as a new app and
# silently drops its TCC grants (Accessibility/Automation) — a month of dev
# builds lost permissions this way (2026-07-15: the Accessibility pane kept
# honoring a stale row while the real app had nothing). A Developer ID signature
# has a stable designated requirement, so grants survive rebuilds.
# Deliberately NOT --options runtime: hardened-runtime library validation would
# reject the Homebrew libwhisper dylib and Sparkle.framework in dev bundles.
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [ -n "$DEV_ID" ]; then
    find "$APP_DIR/Contents/Frameworks" -name "*.framework" -maxdepth 1 2>/dev/null \
        | while read -r fw; do codesign --force --sign "$DEV_ID" "$fw" || true; done
    codesign --force --sign "$DEV_ID" --identifier com.definitelyreal.speakfree "$APP_DIR"
    echo "Signed with: $DEV_ID"
else
    codesign --force --sign - --identifier com.definitelyreal.speakfree "$APP_DIR"
    echo "Signed: ad-hoc (no Developer ID — TCC grants will NOT survive rebuilds)"
fi

echo "Built $APP_DIR"
