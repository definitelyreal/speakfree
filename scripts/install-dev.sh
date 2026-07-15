#!/bin/bash
# install-dev.sh — build + install for local testing WITHOUT full DMG/notarize cycle.
#
# Builds a fresh dev bundle via scripts/bundle-app.sh (which Developer-ID-signs it
# when available, so TCC grants survive rebuilds) and installs it per CLAUDE.md's
# mandatory trash-then-copy policy: NEVER mutate the installed bundle in place —
# that leaves stale files and corrupts TCC (Microphone/Accessibility) state.
#
# Dev bundles resolve libwhisper from Homebrew's absolute path (no rpath rewrite,
# no bundled dylib) — see scripts/bundle-app.sh. Do not re-point it to @rpath here;
# the dev bundle never ships a Frameworks/libwhisper*.dylib for @rpath to resolve,
# so doing so previously broke dyld at launch.
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/speakfree.app"
TMP_DIR="$(mktemp -d)"
TMP_APP="$TMP_DIR/speakfree.app"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

cd "$REPO_DIR"

echo "Building (debug)..."
xcrun swift build

BINARY=".build/debug/speakfree"

echo "Bundling app (dev)..."
bash scripts/bundle-app.sh "$BINARY" "$TMP_APP" dev

echo "Stopping existing speakfree..."
pkill -x speakfree 2>/dev/null || true
sleep 0.5

echo "Removing old install (trash, not in-place mutation — see CLAUDE.md)..."
if [ -d "$APP" ]; then
    if command -v /usr/bin/trash &>/dev/null; then
        /usr/bin/trash "$APP"
    else
        # No `trash` utility available — fall back to rm -rf (loses Trash recoverability).
        rm -rf "$APP"
    fi
fi

echo "Installing to $APP..."
cp -R "$TMP_APP" "$APP"

echo "Launching..."
open "$APP"

echo "Done. Tail logs: tail -f ~/.config/speakfree/logs/\$(ls -t ~/.config/speakfree/logs/ | head -1)"
