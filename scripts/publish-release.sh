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

# 3. Promote draft to public
echo "Promoting draft to public release..."
gh release edit "$TAG" --repo "$REPO" --draft=false

# 4. Commit and push the appcast — this is the moment existing users see the update
echo "Pushing appcast to main (users will start receiving the update prompt)..."
cd "$REPO_DIR"
git add "$APPCAST"
git commit -m "release: publish appcast for v${VERSION}" || echo "(appcast already committed)"
git push origin main

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
