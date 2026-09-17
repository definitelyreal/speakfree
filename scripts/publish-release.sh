#!/bin/bash
# ai-suggestion:unverified · session:01a0a336-fe39-7870-bdab-33c820f98955 · 2026-09-17
# Publishing a downloadable binary is separate from promoting the update feed.
# This script never installs an app, pushes main, or bypasses its required review.
set -euo pipefail

VERSION="${1:-}"
MODE="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
   { [ -n "$MODE" ] && [ "$MODE" != "--binary-only" ]; }; then
    echo "Usage: publish-release.sh X.Y.Z [--binary-only]" >&2
    exit 1
fi
TAG="v$VERSION"
REPO="definitelyreal/speakfree"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
NOTES_FILE="docs/release-notes/$TAG.md"
DMG="speakfree-$VERSION.dmg"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$DMG"

[ -f "$NOTES_FILE" ] && [ -f "$DMG" ] || {
    echo "FATAL: release notes and the original signed DMG are required." >&2; exit 1;
}
[ -z "$(git status --porcelain --untracked-files=no)" ] || {
    echo "FATAL: commit tracked changes before publication." >&2; exit 1;
}
bash scripts/check-version.sh
APPCAST_URL=$(xmllint --xpath 'string(/rss/channel/item[1]/enclosure/@url)' docs/appcast.xml)
APPCAST_SIZE=$(xmllint --xpath 'string(/rss/channel/item[1]/enclosure/@length)' docs/appcast.xml)
[ "$APPCAST_URL" = "$DOWNLOAD_URL" ] && [ "$APPCAST_SIZE" = "$(stat -f%z "$DMG")" ] || {
    echo "FATAL: appcast URL/length does not match the release DMG." >&2; exit 1;
}
SOURCE_COMMIT=$(git rev-parse "$TAG^{commit}")
REMOTE_COMMIT=$(gh api "repos/$REPO/commits/$TAG" --jq '.sha')
[ "$SOURCE_COMMIT" = "$REMOTE_COMMIT" ] || {
    echo "FATAL: local and GitHub release tags differ." >&2; exit 1;
}
git diff --quiet "$TAG" -- Sources Resources Package.swift Package.resolved scripts || {
    echo "FATAL: source/package files differ from the release tag." >&2; exit 1;
}
LOCAL_DIGEST="sha256:$(shasum -a 256 "$DMG" | awk '{print $1}')"
REMOTE_DIGEST=$(gh api "repos/$REPO/releases/tags/$TAG" \
    --jq ".assets[] | select(.name == \"$DMG\") | .digest")
[ "$LOCAL_DIGEST" = "$REMOTE_DIGEST" ] || {
    echo "FATAL: GitHub asset digest differs from the signed local DMG." >&2; exit 1;
}
xcrun stapler validate "$DMG"

# Bind the actual notarized payload to the source tag, not just its filename.
MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/speakfree-release-verify.XXXXXX")
cleanup_mount() {
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || return
    rmdir "$MOUNT_DIR"
}
trap cleanup_mount EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG" >/dev/null
APP="$MOUNT_DIR/speakfree.app"
codesign --verify --deep --strict "$APP"
EMBEDDED_COMMIT=$(/usr/libexec/PlistBuddy -c 'Print :SFBuildCommit' "$APP/Contents/Info.plist")
EMBEDDED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
EMBEDDED_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
EMBEDDED_CHANNEL=$(/usr/libexec/PlistBuddy -c 'Print :SFBuildChannel' "$APP/Contents/Info.plist")
[ "$EMBEDDED_COMMIT" = "$SOURCE_COMMIT" ] && [ "$EMBEDDED_VERSION" = "$VERSION" ] &&
    [ "$EMBEDDED_BUILD" = "$VERSION" ] && [ "$EMBEDDED_CHANNEL" = "release" ] || {
    echo "FATAL: DMG payload does not match the tagged release source/version/channel." >&2; exit 1;
}
SPARKLE_VERSION=$(ls /opt/homebrew/Caskroom/sparkle | sort -V | tail -1)
SPARKLE_BIN="/opt/homebrew/Caskroom/sparkle/$SPARKLE_VERSION/bin"
APP_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")
SIGNING_KEY=$("$SPARKLE_BIN/generate_keys" -p | tr -d '[:space:]')
[ "$APP_KEY" = "$SIGNING_KEY" ] || {
    echo "FATAL: app's pinned update key differs from the verification key." >&2; exit 1;
}
APPCAST_SIGNATURE=$(xmllint --xpath 'string(/rss/channel/item[1]/enclosure/@*[local-name()="edSignature"])' docs/appcast.xml)
"$SPARKLE_BIN/sign_update" --verify "$DMG" "$APPCAST_SIGNATURE"
cleanup_mount
trap - EXIT

if [ "$MODE" = "--binary-only" ]; then
    # Keep /releases/latest pointing at the old asset until its Pages link is updated.
    gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES_FILE" --draft=false --latest=false
    curl --fail --silent --show-error --location --head "$DOWNLOAD_URL" >/dev/null
    echo "Published $DOWNLOAD_URL; latest release and live update feed unchanged."
    exit 0
fi

[ "$(git branch --show-current)" = "main" ] || {
    echo "FATAL: promote latest only after the reviewed metadata lands on main." >&2; exit 1;
}
[ "$(git rev-parse HEAD)" = "$(gh api "repos/$REPO/commits/main" --jq '.sha')" ] || {
    echo "FATAL: local main does not match GitHub main." >&2; exit 1;
}
[ "$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq '.isDraft')" = "false" ] || {
    echo "FATAL: publish with --binary-only before promoting the update feed." >&2; exit 1;
}
LIVE_APPCAST=$(curl --fail --silent --show-error "https://definitelyreal.github.io/speakfree/appcast.xml")
[ "$LIVE_APPCAST" = "$(< docs/appcast.xml)" ] || {
    echo "FATAL: live appcast differs from the signed local feed; wait for Pages deployment." >&2; exit 1;
}
LIVE_SITE=$(curl --fail --silent --show-error "https://definitelyreal.github.io/speakfree/")
[[ "$LIVE_SITE" == *"$DOWNLOAD_URL"* ]] || {
    echo "FATAL: reviewed version-specific download link is not live yet." >&2; exit 1;
}
curl --fail --silent --show-error --location --head "$DOWNLOAD_URL" >/dev/null
gh release edit "$TAG" --repo "$REPO" --latest=true
echo "Promoted $TAG: public binary, deployed Pages link and Sparkle feed agree."
