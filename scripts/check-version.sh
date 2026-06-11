#!/usr/bin/env bash
# check-version.sh — assert that Version.swift, Info.plist, and the appcast all agree.
# Exits 0 on agreement; exits 1 (with a clear message) on any mismatch.
# Designed to run both from scripts/build.sh (repo root is CWD) and from CI.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

# --- Report ---
echo "Version.swift         : $VERSION_SWIFT"
echo "Resources/Info.plist  : $VERSION_PLIST"
echo "docs/appcast.xml      : $VERSION_APPCAST"

# --- Check ---
MISMATCH=0
if [ "$VERSION_SWIFT" != "$VERSION_PLIST" ]; then
    echo "ERROR: Version.swift ($VERSION_SWIFT) != Info.plist ($VERSION_PLIST)" >&2
    MISMATCH=1
fi
if [ "$VERSION_SWIFT" != "$VERSION_APPCAST" ]; then
    echo "ERROR: Version.swift ($VERSION_SWIFT) != appcast ($VERSION_APPCAST)" >&2
    MISMATCH=1
fi

if [ "$MISMATCH" -ne 0 ]; then
    echo "" >&2
    echo "FATAL: Version triple is inconsistent. Update all three sources to agree before building." >&2
    exit 1
fi

echo "OK: all three version sources agree ($VERSION_SWIFT)"
