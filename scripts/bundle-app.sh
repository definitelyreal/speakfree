#!/bin/bash
set -euo pipefail

BINARY="${1:-.build/release/speakfree}"
APP_DIR="${2:-OpenWispr.app}"
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
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>speakfree needs microphone access to record speech for transcription.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>speakfree uses screen capture for local OCR to improve transcription accuracy (opt-in).</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.definitelyreal.speakfree "$APP_DIR"

echo "Built $APP_DIR"
