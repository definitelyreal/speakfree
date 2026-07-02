#!/bin/bash
# publish-release.sh <version>
#
# Promotes the draft GitHub release to public and pushes the appcast so
# existing users receive the Sparkle update prompt.
#
# Run ONLY after dogfooding the build from /Applications.
# build.sh must have been run first (it creates the draft + updates appcast locally).
set -e

if [ -z "$1" ]; then
    echo "Usage: publish-release.sh <version>"
    echo "Example: publish-release.sh 1.3.0"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
REPO="definitelyreal/speakfree"
APPCAST="docs/appcast.xml"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Publishing speakfree ${TAG}..."

# 1. Verify the draft exists
RELEASE_STATE=$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "missing")
if [ "$RELEASE_STATE" = "missing" ]; then
    echo "Error: no release found for $TAG. Run build.sh first." >&2
    exit 1
fi
if [ "$RELEASE_STATE" != "true" ]; then
    echo "Error: release $TAG is not a draft (state=$RELEASE_STATE). Already published?" >&2
    exit 1
fi

# 2. Verify appcast.xml is updated for this version
APPCAST_VERSION=$(grep -o '<sparkle:version>[^<]*</sparkle:version>' "$REPO_DIR/$APPCAST" | sed 's/<[^>]*>//g')
if [ "$APPCAST_VERSION" != "$VERSION" ]; then
    echo "Error: appcast.xml has version '$APPCAST_VERSION', expected '$VERSION'." >&2
    echo "Run build.sh first to update the appcast." >&2
    exit 1
fi

# 3. Replace the draft-placeholder notes with real release notes, then promote to public.
# build.sh creates the draft with a "*Draft — not yet published*" placeholder body; without
# this step it went PUBLIC with that placeholder still showing (the v1.7.0 bug). Require a
# real notes file so the placeholder can never reach users.
NOTES_FILE="$REPO_DIR/docs/release-notes/v${VERSION}.md"
if [ ! -f "$NOTES_FILE" ]; then
    echo "FATAL: no release notes at docs/release-notes/v${VERSION}.md." >&2
    echo "  Write the user-facing notes there before publishing (prevents the draft placeholder going public)." >&2
    exit 1
fi
echo "Setting real release notes + promoting draft to public..."
gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES_FILE" --draft=false

# 4. Commit and push the appcast + Pages download link together — this is the moment
# existing users see the Sparkle update AND the public Download button points at the new
# binary. Both MUST ship together or the Pages link goes stale.
echo "Pushing appcast + Pages download link to main..."
cd "$REPO_DIR"
git add "$APPCAST" docs/index.html
git commit -m "release: publish appcast + download link for v${VERSION}" || echo "(already committed)"
git push origin main

# 5. Verify the public Pages download link resolves to THIS release's binary.
echo "Verifying download link resolves to v${VERSION}..."
DL_URL="https://github.com/${REPO}/releases/latest/download/speakfree-${VERSION}.dmg"
HTTP_CODE=$(curl -s -o /dev/null -L -w '%{http_code}' "$DL_URL" || echo "000")
[ "$HTTP_CODE" = "200" ] && echo "  OK: $DL_URL -> 200" || echo "  WARNING: $DL_URL returned $HTTP_CODE (asset may still be propagating)." >&2

echo ""
echo "=============================="
echo "  PUBLISHED: speakfree ${TAG}  "
echo "=============================="
echo ""
echo "  Release: https://github.com/${REPO}/releases/tag/${TAG}"
echo "  Appcast: https://definitelyreal.github.io/speakfree/appcast.xml"
echo ""
echo "  Existing users will see the update prompt within 24h (Sparkle auto-check interval)."
echo "  To check immediately: launch speakfree → Help menu → Check for Updates."
echo ""
