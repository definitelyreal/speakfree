#!/bin/bash
# Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
#
# Kill/restart speakfree WITHOUT eating an in-flight dictation: waits until the
# recording-in-progress sentinel has been absent for 10 consecutive seconds
# (i.e. fn hasn't been held for 10 s), then sends SIGTERM — which new builds
# additionally handle by finishing any dictation that slipped in.
#
# Usage: scripts/safe-restart.sh
#   Waits, then kills; caller reinstalls/relaunches afterwards (kill-only by
#   default — there is no separate --kill-only flag, this is just what it does).
set -u

SENTINEL="$HOME/.config/speakfree/.recording-in-progress.json"
QUIET_NEEDED=10
MAX_WAIT=180

quiet=0
waited=0
while [ $quiet -lt $QUIET_NEEDED ]; do
  if [ -f "$SENTINEL" ]; then
    quiet=0
  else
    quiet=$((quiet + 1))
  fi
  sleep 1
  waited=$((waited + 1))
  if [ $waited -ge $MAX_WAIT ]; then
    echo "safe-restart: still dictating after ${MAX_WAIT}s — giving up (nothing killed)" >&2
    exit 1
  fi
done

echo "safe-restart: ${QUIET_NEEDED}s of quiet — stopping speakfree"
pkill -f "speakfree.app/Contents/MacOS/speakfree" 2>/dev/null
pkill -f "speakfree start" 2>/dev/null
exit 0
