#!/bin/bash
# ai-suggestion:unverified · session:01a0a336-fe39-7870-bdab-33c820f98955 · 2026-09-17
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
VERSION=$(grep 'let version' Sources/SpeakFreeLib/Version.swift | sed 's/.*"\(.*\)".*/\1/')
DMG="speakfree-${VERSION}.dmg"
SIGN_ID="Developer ID Application: Michael Morgenstern (AZ53Y7V4UZ)"
ENTITLEMENTS="$(dirname "$0")/speakfree.entitlements"
BUILD_COMMIT=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "FATAL: commit tracked source changes before packaging." >&2
    exit 1
fi
check_source_inputs() {
    git diff --quiet "$BUILD_COMMIT" -- Sources Resources Package.swift Package.resolved scripts || {
        echo "FATAL: source inputs changed while packaging." >&2; return 1;
    }
    [ -z "$(git ls-files --others --exclude-standard -- Sources Resources scripts)" ] || {
        echo "FATAL: untracked build inputs must be committed before packaging." >&2; return 1;
    }
}
check_source_inputs
if [ -e "$DMG" ]; then
    echo "FATAL: $DMG already exists; preserve it before starting another build." >&2
    exit 1
fi

# Fork policy (2026-08-21): releases are cut from main or a release/X.Y.Z branch.
# release/* carries only regression fixes cherry-picked from main; main keeps
# experimenting. On a release branch the version in its name must match
# Version.swift so a mis-bumped branch can never ship under the wrong number.
CURRENT_BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
case "$CURRENT_BRANCH" in
    main) ;;
    release/*|codex/release/*)
        BRANCH_VERSION="${CURRENT_BRANCH##*/}"
        if [ "$BRANCH_VERSION" != "$VERSION" ]; then
            echo "FATAL: on $CURRENT_BRANCH but Version.swift says $VERSION." >&2
            exit 1
        fi ;;
    *)
        echo "FATAL: build.sh requires main, release/X.Y.Z or codex/release/X.Y.Z (currently '$CURRENT_BRANCH')." >&2
        exit 1 ;;
esac

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
    sed -i '' -E "s#releases/(latest/download|download/v[0-9.]+)/speakfree-[0-9.]+\.dmg#releases/download/v${VERSION}/speakfree-${VERSION}.dmg#g" "$INDEX"
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
bash "$REPO_DIR/scripts/check-version.sh" --source-only

echo "Building speakfree v${VERSION}..."
xcrun swift build -c release
check_source_inputs

# A fresh, retained staging bundle cannot inherit stale files from a prior app.
# Packaging never installs, stops, or restarts the user's running SpeakFree.
mkdir -p build
PACKAGE_DIR=$(mktemp -d "$REPO_DIR/build/release-package.XXXXXX")
APP="$PACKAGE_DIR/speakfree.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Always regenerate Info.plist from the tracked Resources/Info.plist so the bundle
# template (speakfree.app, which is gitignored) never drifts out of sync with the
# canonical plist. This ensures Sparkle keys, entitlements descriptions, and other
# metadata are never silently dropped from a build.
echo "Copying canonical Info.plist and setting version to ${VERSION}..."
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SFBuildCommit string $BUILD_COMMIT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SFBuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist"
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
check_source_inputs
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
codesign --verify --deep --strict --verbose=2 "$APP"
"$APP/Contents/MacOS/speakfree" --help >/dev/null

echo "Building DMG..."
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

codesign --sign "$SIGN_ID" --timestamp "$DMG"
echo "Notarizing..."
xcrun notarytool submit "$DMG" \
    --keychain-profile "speakfree-notary" \
    --wait

echo "Stapling..."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

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

bash "$REPO_DIR/scripts/check-version.sh"

# NOTE: the GitHub Pages site (docs/index.html) — download URL, version label, and
# "What's new" heading — was already stamped to v${VERSION} at the top of this
# script and validated by check-version.sh. Nothing to do here.

echo ""
echo "==========================================="
echo "  SIGNED PACKAGE READY — NOT YET PUBLISHED "
echo "==========================================="
echo ""
echo "  Staged:     $APP (v${VERSION}; $BUILD_COMMIT)"
echo "  DMG:        ${DMG} (signed, notarized, stapled)"
echo "  Appcast:    ${APPCAST} (updated locally, NOT pushed)"
echo "  Running app: unchanged. No GitHub mutations performed."
echo ""
echo "  Verify the package, push its source commit and exact tag, then upload"
echo "  a draft using gh release create --verify-tag. See docs/RELEASING.md."
echo ""
