#!/bin/bash
set -e

APP="speakfree.app"
VERSION=$(grep 'let version' Sources/OpenWisprLib/Version.swift | sed 's/.*"\(.*\)".*/\1/')
DMG="speakfree-${VERSION}.dmg"
SIGN_ID="Developer ID Application: Michael Morgenstern (AZ53Y7V4UZ)"
ENTITLEMENTS="$(dirname "$0")/speakfree.entitlements"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Vendored whisper.cpp + ggml binaries. Pinning to a known-good version
# (libwhisper 1.8.3 + ggml 0.9.5) avoids depending on transient brew state —
# specifically, brew's whisper-cpp 1.8.4 is ABI-incompatible with current ggml
# 0.10.0, so building against brew silently produces a binary that ggml_aborts
# at model load. See scripts/vendor/dylibs/README.md.
VENDOR_DIR="$(dirname "$0")/vendor/dylibs"

echo "Building speakfree v${VERSION}..."
xcrun swift build -c release

# Always regenerate Info.plist from the tracked Resources/Info.plist so the bundle
# template (speakfree.app, which is gitignored) never drifts out of sync with the
# canonical plist. This ensures Sparkle keys, entitlements descriptions, and other
# metadata are never silently dropped from a build.
echo "Copying canonical Info.plist and setting version to ${VERSION}..."
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP/Contents/Info.plist"

echo "Copying main binary..."
cp .build/release/speakfree "$APP/Contents/MacOS/speakfree"

echo "Bundling whisper-cli..."
mkdir -p "$APP/Contents/Frameworks"
cp "$VENDOR_DIR/whisper-cli" "$APP/Contents/MacOS/whisper-cli"

echo "Bundling Sparkle.framework..."
SPARKLE_FW=".build/arm64-apple-macosx/release/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -a "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# Wipe stale dylibs (and any Dropbox conflicted-copy cruft) before bundling
# the pinned set, so we never accidentally ship an old/incompatible version.
find "$APP/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -delete
find "$APP/Contents/Frameworks" -maxdepth 1 -type l -name '*.dylib' -delete

# Bundle the pinned whisper.cpp + ggml dylibs from vendor.
for dylib in "$VENDOR_DIR"/*.dylib; do
    cp "$dylib" "$APP/Contents/Frameworks/"
done

# Create versioned symlinks so whisper-cli + libwhisper can find their deps by soname
for real_dylib in "$APP/Contents/Frameworks"/*.dylib; do
    basename=$(basename "$real_dylib")
    soname=$(echo "$basename" | sed 's/\([^0-9]*[0-9]*\)\.[0-9]*\.[0-9]*\.dylib$/\1.dylib/')
    if [ "$soname" != "$basename" ]; then
        ln -sf "$basename" "$APP/Contents/Frameworks/$soname"
    fi
done

# Fix rpaths so binaries find frameworks/dylibs inside the bundle.
# (Use add_rpath in a guarded form: it errors if the rpath already exists.)
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/speakfree" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/whisper-cli" 2>/dev/null || true

# Re-point the speakfree binary's libwhisper reference to @rpath. Swift Package
# Manager links it against the dylib's LC_ID_DYLIB (an absolute brew path), so
# without this fixup the running binary loads brew's libwhisper at runtime
# instead of the bundled one, defeating the whole pinning scheme.
SPEAKFREE_BIN="$APP/Contents/MacOS/speakfree"
ORIG_WHISPER_REF=$(otool -L "$SPEAKFREE_BIN" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
if [ -n "$ORIG_WHISPER_REF" ] && [ "$ORIG_WHISPER_REF" != "@rpath/libwhisper.1.dylib" ]; then
    install_name_tool -change "$ORIG_WHISPER_REF" "@rpath/libwhisper.1.dylib" "$SPEAKFREE_BIN"
fi
# Guard: verify the rpath fix took — if it still points to brew, the DMG would ship
# a binary that loads brew's libwhisper at runtime and crashes on model load.
FINAL_WHISPER_REF=$(otool -L "$SPEAKFREE_BIN" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
if [ "$FINAL_WHISPER_REF" != "@rpath/libwhisper.1.dylib" ]; then
    echo "FATAL: libwhisper still points to '$FINAL_WHISPER_REF' — rpath fix failed. Aborting." >&2
    exit 1
fi

echo "Signing..."
find "$APP" -exec xattr -c {} \; 2>/dev/null || true
# Sign dylibs and whisper-cli first (no entitlements needed for these).
# Use find -type f to skip symlinks — codesign fails with "timestamp expected"
# when re-signing an already-signed file via a symlink to it.
find "$APP/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' \
    -exec codesign --force --options runtime --sign "$SIGN_ID" {} \;
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/MacOS/whisper-cli"
# Sign the main app with entitlements (microphone + apple-events)
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"

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

echo "Updating Sparkle appcast..."
SPARKLE_BIN="/opt/homebrew/Caskroom/sparkle/2.9.0/bin"
APPCAST="docs/appcast.xml"
DOWNLOAD_URL="https://github.com/definitelyreal/speakfree/releases/download/v${VERSION}/${DMG}"
DMG_SIZE=$(stat -f%z "$DMG")
# Extract ONLY the edSignature value. The previous greedy sed (s/.*"\(.*\)".*/\1/)
# matched through to the LAST quote and captured length="...", shipping the file
# length as the "signature" — which Sparkle rejects, silently breaking auto-update
# for everyone since launch. Anchor on edSignature="..." specifically.
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG" 2>/dev/null | sed -E 's/.*edSignature="([^"]*)".*/\1/')
# Guard: a real EdDSA signature is base64 (~86 chars), never all-digits. Fail the
# release rather than ship a broken appcast again.
if [[ -z "$SIGNATURE" || "$SIGNATURE" =~ ^[0-9]+$ || ${#SIGNATURE} -lt 40 ]]; then
    echo "FATAL: extracted Sparkle signature looks invalid ('$SIGNATURE'). Aborting release." >&2
    exit 1
fi
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S %z")

# Build new appcast with this release at the top
cat > "$APPCAST" << APPCAST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>speakfree Updates</title>
    <link>https://definitelyreal.github.io/speakfree/</link>
    <description>Updates for speakfree</description>
    <language>en</language>
    <item>
      <title>speakfree v${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="${DOWNLOAD_URL}"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE}"
        length="${DMG_SIZE}" />
    </item>
  </channel>
</rss>
APPCAST_EOF

# Keep the GitHub Pages download link in lockstep with the released binary.
# build.sh updates appcast.xml but historically NOT index.html, so the public
# "Download" button drifted to an old version. Rewrite it to this release's DMG.
echo "Updating GitHub Pages download link to ${DMG}..."
INDEX="docs/index.html"
if [ -f "$INDEX" ]; then
    sed -i '' -E "s#releases/latest/download/speakfree-[0-9][0-9.]*\.dmg#releases/latest/download/speakfree-${VERSION}.dmg#g" "$INDEX"
    if ! grep -q "speakfree-${VERSION}.dmg" "$INDEX"; then
        echo "FATAL: failed to update download link in $INDEX to v${VERSION}." >&2
        exit 1
    fi
fi

echo "Force-quitting any running instance and deleting old app before install..."
osascript -e 'quit app "speakfree"' 2>/dev/null || true
pkill -x speakfree 2>/dev/null || true
sleep 1
pkill -9 -x speakfree 2>/dev/null || true
sleep 1
echo "Installing to /Applications..."
rm -rf /Applications/speakfree.app
cp -a "$APP" /Applications/

# Create a DRAFT GitHub release and upload the DMG.
# The release is NOT public yet — the appcast.xml is updated locally but NOT pushed.
# Dogfood the app from /Applications, then run scripts/publish-release.sh to go live.
echo "Creating draft GitHub release v${VERSION}..."
gh release create "v${VERSION}" "$DMG" \
    --repo definitelyreal/speakfree \
    --title "speakfree v${VERSION}" \
    --draft \
    --notes "$(cat <<NOTES_EOF
## speakfree v${VERSION}

*Draft — not yet published. Run scripts/publish-release.sh after dogfood.*
NOTES_EOF
)"

echo ""
echo "==========================================="
echo "  BUILD COMPLETE — DOGFOOD BEFORE RELEASE  "
echo "==========================================="
echo ""
echo "  Installed:  /Applications/speakfree.app (v${VERSION})"
echo "  DMG:        ${DMG} (signed, notarized, stapled)"
echo "  Appcast:    ${APPCAST} (updated locally, NOT pushed)"
echo "  GH Release: draft at github.com/definitelyreal/speakfree/releases"
echo ""
echo "  Test the app. When ready to ship:"
echo "    bash scripts/publish-release.sh ${VERSION}"
echo ""
