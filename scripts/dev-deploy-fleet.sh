#!/bin/bash
# Claude · 2026-07-22 · Session: dba44e2d-9a1a-4b83-b219-a922d882cf7f
# Deploy the current dev build to the whole dogfood fleet:
#   M3 (this Mac, Homebrew libwhisper) + M5 (movie@100.82.136.101) + M1 (ark)
# Remote Macs get the vendored-dylib bundle (no Homebrew whisper-cpp there).
# Michael's rule (2026-07-22): every redeploy goes to all three unless told otherwise.
#
# Honors the MANDATORY install sequence: stop -> Trash old bundle -> copy -> launch.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
REMOTES=("movie@100.82.136.101" "ark")

echo "== build =="
xcrun swift build -c release
bash scripts/bundle-app.sh .build/release/speakfree speakfree.app dev

echo "== M3 (local) =="
# The app exits GRACEFULLY on SIGTERM (waits up to ~10s for quiet). Wait for the
# process to actually die before reinstalling/relaunching — a fixed sleep raced it:
# `open` then activates the DYING old instance instead of launching the new one,
# the pgrep health check passes against that dying process, and minutes later the
# machine has no speakfree at all (M5, 2026-07-23).
# Wait out the app's OWN graceful window (in-flight dictation + 10s quiet; the app
# refuses new recordings once signaled). 15s + pkill -9 SIGKILLed a live dictation
# on 2026-07-25 — audio still in memory, wav had 0 samples. 3min covers any real
# dictation; -9 only past that (matches the app's stuck-state escape hatch).
pkill -f "speakfree.app/Contents/MacOS/speakfree" || true
for _ in $(seq 1 360); do
    pgrep -f "speakfree.app/Contents/MacOS/speakfree" >/dev/null || break
    sleep 0.5
done
pkill -9 -f "speakfree.app/Contents/MacOS/speakfree" 2>/dev/null || true
/usr/bin/trash /Applications/speakfree.app 2>/dev/null || true
cp -R speakfree.app /Applications/speakfree.app
open /Applications/speakfree.app
sleep 4
pgrep -f "speakfree.app/Contents/MacOS/speakfree" >/dev/null && echo "M3 RUNNING"

echo "== vendored bundle for remotes =="
rm -rf speakfree-fleet.app
cp -R speakfree.app speakfree-fleet.app
APP=speakfree-fleet.app
for dylib in scripts/vendor/dylibs/*.dylib; do cp "$dylib" "$APP/Contents/Frameworks/"; done
for real_dylib in "$APP/Contents/Frameworks"/*.dylib; do
    b=$(basename "$real_dylib")
    s=$(echo "$b" | sed 's/\([^0-9]*[0-9]*\)\.[0-9]*\.[0-9]*\.dylib$/\1.dylib/')
    if [ "$s" != "$b" ]; then ln -sf "$b" "$APP/Contents/Frameworks/$s"; fi
done
ORIG=$(otool -L "$APP/Contents/MacOS/speakfree" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
if [ "$ORIG" != "@rpath/libwhisper.1.dylib" ]; then
    install_name_tool -change "$ORIG" "@rpath/libwhisper.1.dylib" "$APP/Contents/MacOS/speakfree"
fi
FINAL=$(otool -L "$APP/Contents/MacOS/speakfree" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
[ "$FINAL" = "@rpath/libwhisper.1.dylib" ] || { echo "FATAL: rpath fix failed" >&2; exit 1; }
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -type f \
    -exec codesign --force --sign "$DEV_ID" {} \;
codesign --force --sign "$DEV_ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$DEV_ID" --identifier com.definitelyreal.speakfree "$APP"
codesign --verify --deep "$APP"
tar czf /tmp/speakfree-fleet.tgz speakfree-fleet.app

for REMOTE in "${REMOTES[@]}"; do
    echo "== $REMOTE =="
    scp -o BatchMode=yes /tmp/speakfree-fleet.tgz "$REMOTE":/tmp/speakfree-new.tgz
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes "$REMOTE" '
        pkill -f "speakfree.app/Contents/MacOS/speakfree" || true
        for _ in $(seq 1 360); do
            pgrep -f "speakfree.app/Contents/MacOS/speakfree" >/dev/null || break
            sleep 0.5
        done
        pkill -9 -f "speakfree.app/Contents/MacOS/speakfree" 2>/dev/null || true
        mv /Applications/speakfree.app ~/.Trash/speakfree-old-$(date +%H%M%S).app 2>/dev/null || true
        cd /Applications && tar xzf /tmp/speakfree-new.tgz
        mv speakfree-fleet.app speakfree.app
        codesign --verify --deep speakfree.app
        open speakfree.app; sleep 5
        pgrep -f "speakfree.app/Contents/MacOS/speakfree" >/dev/null && echo "RUNNING"
        mv /tmp/speakfree-new.tgz ~/.Trash/ 2>/dev/null || true'
done

rm -rf speakfree-fleet.app
echo "== fleet deploy complete =="
