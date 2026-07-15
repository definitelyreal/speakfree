#!/bin/bash
set -e

APP="speakfree.app"
VERSION=$(grep 'let version' Sources/SpeakFreeLib/Version.swift | sed 's/.*"\(.*\)".*/\1/')
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

# Stamp EVERY mechanical version surface in the Pages site from VERSION, up front,
# BEFORE the consistency check validates them. Historically build.sh rewrote only
# the download URL, so the visible "vX.Y.Z" label and the changelog drifted (the
# site showed v1.3.0 while serving the v1.6.0 DMG). These are regenerated on every
# release so they can never go stale again; the changelog body is the one human
# step, enforced by check-version.sh (newest <h3> must equal VERSION).
INDEX="docs/index.html"
MAJOR_MINOR=$(echo "$VERSION" | cut -d. -f1-2)
if [ -f "$INDEX" ]; then
    echo "Stamping Pages site version surfaces to v${VERSION}..."
    # Download button URL
    sed -i '' -E "s#releases/latest/download/speakfree-[0-9][0-9.]*\.dmg#releases/latest/download/speakfree-${VERSION}.dmg#g" "$INDEX"
    # Visible version label under the download button
    sed -i '' -E "s#(class=\"btn-sub\">v)[0-9][0-9.]*#\1${VERSION}#g" "$INDEX"
    # "What's new in vX.Y" disclosure heading
    sed -i '' -E "s#(What's new in v)[0-9]+\.[0-9]+#\1${MAJOR_MINOR}#g" "$INDEX"
    # Fail fast if any mechanical surface didn't land — these are guarded again in
    # check-version.sh below, but failing here pinpoints which sed missed.
    grep -q "speakfree-${VERSION}.dmg" "$INDEX"        || { echo "FATAL: download URL not updated to v${VERSION} in $INDEX." >&2; exit 1; }
    grep -q "class=\"btn-sub\">v${VERSION} " "$INDEX"  || { echo "FATAL: version label not updated to v${VERSION} in $INDEX." >&2; exit 1; }
    grep -q "What's new in v${MAJOR_MINOR}" "$INDEX"   || { echo "FATAL: changelog heading not updated to v${MAJOR_MINOR} in $INDEX." >&2; exit 1; }
fi

echo "Checking version consistency..."
bash "$REPO_DIR/scripts/check-version.sh"

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
# Mark this as the RELEASE channel so the menu-bar title is clean ("speakfree X.Y.Z").
# Any build without this key defaults to "Testing" (dev/experimental) — see SpeakFree.menuTitle.
/usr/libexec/PlistBuddy -c "Set :SFBuildChannel release" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :SFBuildChannel string release" "$APP/Contents/Info.plist"

echo "Copying main binary..."
cp .build/release/speakfree "$APP/Contents/MacOS/speakfree"

echo "Verifying vendored dylib checksums..."
# Fail the build if any vendored binary has been tampered with or accidentally replaced.
# To regenerate after an intentional vendor update:
#   cd scripts/vendor/dylibs && shasum -a 256 *.dylib whisper-cli > checksums.sha256
(cd "$VENDOR_DIR" && shasum -a 256 -c checksums.sha256 --strict)
echo "Vendored dylib checksums OK."

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
find "$APP/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print0 \
    | xargs -0 -n1 codesign --force --options runtime --sign "$SIGN_ID"
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
# Discover the installed Sparkle cask version dynamically so the path does not
# need to be bumped every time the cask is updated.
SPARKLE_CASKROOM="/opt/homebrew/Caskroom/sparkle"
SPARKLE_VERSION=$(ls "$SPARKLE_CASKROOM" 2>/dev/null | sort -V | tail -1)
if [ -z "$SPARKLE_VERSION" ]; then
    echo "FATAL: Sparkle cask not installed. Run: brew install --cask sparkle" >&2
    exit 1
fi
SPARKLE_BIN="$SPARKLE_CASKROOM/$SPARKLE_VERSION/bin"
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    echo "FATAL: sign_update not found at $SPARKLE_BIN/sign_update" >&2
    echo "  Installed Sparkle version: $SPARKLE_VERSION" >&2
    echo "  Re-install with: brew install --cask sparkle" >&2
    exit 1
fi
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

# Guard: the DMG was just signed with whatever private key lives in this
# machine's Keychain. Verify that key's matching public key is the one the
# shipped app actually trusts (SUPublicEDKey in Info.plist) — signing with the
# wrong key produces a signature that passes the format check above but Sparkle
# will silently reject at update time.
echo "Verifying Sparkle signing key matches the app's pinned public key..."
KEYCHAIN_PUB_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | tr -d '[:space:]')
APP_PUB_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null | tr -d '[:space:]')
if [ -z "$KEYCHAIN_PUB_KEY" ] || [ -z "$APP_PUB_KEY" ]; then
    echo "FATAL: could not read Sparkle public key (keychain='$KEYCHAIN_PUB_KEY' plist='$APP_PUB_KEY'). Aborting release." >&2
    exit 1
fi
if [ "$KEYCHAIN_PUB_KEY" != "$APP_PUB_KEY" ]; then
    echo "FATAL: Sparkle signing key mismatch." >&2
    echo "  Keychain public key : $KEYCHAIN_PUB_KEY" >&2
    echo "  App's SUPublicEDKey : $APP_PUB_KEY" >&2
    echo "  The DMG was signed with a different key than the app trusts — Sparkle would reject the update. Aborting." >&2
    exit 1
fi
echo "Sparkle signing key OK (matches SUPublicEDKey)."
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

# NOTE: the GitHub Pages site (docs/index.html) — download URL, version label, and
# "What's new" heading — was already stamped to v${VERSION} at the top of this
# script and validated by check-version.sh. Nothing to do here.

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
