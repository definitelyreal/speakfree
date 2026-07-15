#!/usr/bin/env bash
# check-version.sh — assert that EVERY version-bearing surface agrees:
#   Version.swift, Resources/Info.plist, docs/appcast.xml, and the GitHub Pages
#   site (docs/index.html: download URL, visible label, and newest changelog entry).
# Exits 0 on agreement; exits 1 (with a clear message) on any mismatch.
# Designed to run both from scripts/build.sh (repo root is CWD) and from CI.
#
# The Pages site is included because it silently drifted for three releases —
# build.sh used to stamp only the download URL, so the site showed v1.3.0 while
# serving the v1.6.0 DMG. Gating on it here means a stale site fails the build
# (and CI) instead of shipping. build.sh stamps the mechanical surfaces (URL,
# label, heading) automatically before calling this; the changelog body is the
# one human step this check enforces.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INDEX="$REPO_DIR/docs/index.html"

# --- Extract version from each source ---

VERSION_SWIFT=$(grep 'let version' "$REPO_DIR/Sources/SpeakFreeLib/Version.swift" \
    | sed 's/.*"\(.*\)".*/\1/')

VERSION_PLIST=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$REPO_DIR/Resources/Info.plist")

# Newest <item> is the first one in the file (build.sh always prepends).
# Match the first sparkle:shortVersionString value.
VERSION_APPCAST=$(grep -m1 '<sparkle:shortVersionString>' \
    "$REPO_DIR/docs/appcast.xml" \
    | sed 's/.*<sparkle:shortVersionString>\(.*\)<\/sparkle:shortVersionString>.*/\1/' \
    | tr -d '[:space:]')

# Also check <sparkle:version> and the version embedded in the enclosure's
# download URL (speakfree-X.Y.Z.dmg) — build.sh writes all three from the same
# $VERSION, but a hand edit or a partial regen could desync them independently
# of VERSION_APPCAST above.
VERSION_APPCAST_SPARKLE=$(grep -m1 '<sparkle:version>' \
    "$REPO_DIR/docs/appcast.xml" \
    | sed 's/.*<sparkle:version>\(.*\)<\/sparkle:version>.*/\1/' \
    | tr -d '[:space:]')
VERSION_APPCAST_URL=$(grep -m1 -oE 'speakfree-[0-9]+\.[0-9]+\.[0-9]+\.dmg' "$REPO_DIR/docs/appcast.xml" \
    | sed -E 's/speakfree-([0-9.]+)\.dmg/\1/')

# Pages site: the download URL, the visible "vX.Y.Z" label, and the newest
# changelog <h3>vX.Y.Z</h3> (topmost = current release).
VERSION_PAGES_URL=$(grep -m1 -oE 'speakfree-[0-9]+\.[0-9]+\.[0-9]+\.dmg' "$INDEX" \
    | sed -E 's/speakfree-([0-9.]+)\.dmg/\1/')
VERSION_PAGES_LABEL=$(grep -m1 -oE 'class="btn-sub">v[0-9]+\.[0-9]+\.[0-9]+' "$INDEX" \
    | sed -E 's/.*>v//')
VERSION_PAGES_CHANGELOG=$(grep -m1 -oE '<h3>v[0-9]+\.[0-9]+\.[0-9]+</h3>' "$INDEX" \
    | sed -E 's#<h3>v([0-9.]+)</h3>#\1#')

# --- Report ---
echo "Version.swift            : $VERSION_SWIFT"
echo "Resources/Info.plist     : $VERSION_PLIST"
echo "docs/appcast.xml         : $VERSION_APPCAST"
echo "appcast sparkle:version  : $VERSION_APPCAST_SPARKLE"
echo "appcast enclosure URL    : $VERSION_APPCAST_URL"
echo "index.html download URL  : $VERSION_PAGES_URL"
echo "index.html version label : $VERSION_PAGES_LABEL"
echo "index.html changelog top : $VERSION_PAGES_CHANGELOG"

# --- Check ---
MISMATCH=0
check() {  # check <name> <value>
    if [ "$2" != "$VERSION_SWIFT" ]; then
        echo "ERROR: Version.swift ($VERSION_SWIFT) != $1 ($2)" >&2
        MISMATCH=1
    fi
}
check "Info.plist"             "$VERSION_PLIST"
check "appcast"                "$VERSION_APPCAST"
check "appcast sparkle:version" "$VERSION_APPCAST_SPARKLE"
check "appcast enclosure URL"   "$VERSION_APPCAST_URL"
check "index.html download URL" "$VERSION_PAGES_URL"
check "index.html version label" "$VERSION_PAGES_LABEL"
check "index.html changelog top" "$VERSION_PAGES_CHANGELOG"

if [ "$MISMATCH" -ne 0 ]; then
    echo "" >&2
    echo "FATAL: version surfaces are inconsistent. All must equal Version.swift ($VERSION_SWIFT)." >&2
    echo "  - Mechanical surfaces (plist, appcast top, index.html URL/label/heading) are stamped by build.sh." >&2
    echo "  - The index.html changelog needs a hand-written <h3>v${VERSION_SWIFT}</h3> entry at the top." >&2
    exit 1
fi

echo "OK: all version surfaces agree ($VERSION_SWIFT)"
