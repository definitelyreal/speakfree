#!/bin/bash
# ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
# Build, vendor and stage on the full fleet BEFORE warning or stopping any app.
# Each staged executable enforces 30 seconds of quiet plus an audible/visible warning.
# Stop only after its positive receipt; never force termination. Trash before copy.
# All three Macs are the default. M3_ONLY=1 retains the explicit local-only override.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTES=("movie@100.82.136.101" "ark")
REMOTE_STAGES=()

sf_initialize_stage() {
    SF_STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/speakfree-fleet.XXXXXX")"
    chmod 700 "$SF_STAGE_ROOT"
}

sf_build_and_vendor() {
    local app="$SF_STAGE_ROOT/speakfree-fleet.app" dylib real_dylib b s orig final dev_id
    echo "== build and vendor =="
    xcrun swift build -c release || return 1
    bash scripts/bundle-app.sh .build/release/speakfree "$app" dev || return 1
    for dylib in scripts/vendor/dylibs/*.dylib; do cp "$dylib" "$app/Contents/Frameworks/" || return 1; done
    for real_dylib in "$app/Contents/Frameworks"/*.dylib; do
        b=$(basename "$real_dylib")
        s=$(echo "$b" | sed 's/\([^0-9]*[0-9]*\)\.[0-9]*\.[0-9]*\.dylib$/\1.dylib/')
        if [ "$s" != "$b" ]; then ln -sf "$b" "$app/Contents/Frameworks/$s" || return 1; fi
    done
    orig=$(otool -L "$app/Contents/MacOS/speakfree" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
    [ -n "$orig" ] || { echo "FATAL: libwhisper dependency not found" >&2; return 1; }
    if [ "$orig" != "@rpath/libwhisper.1.dylib" ]; then
        install_name_tool -change "$orig" "@rpath/libwhisper.1.dylib" "$app/Contents/MacOS/speakfree" || return 1
    fi
    final=$(otool -L "$app/Contents/MacOS/speakfree" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
    [ "$final" = "@rpath/libwhisper.1.dylib" ] || { echo "FATAL: rpath fix failed" >&2; return 1; }
    dev_id=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
    [ -n "$dev_id" ] || dev_id=-
    for real_dylib in "$app/Contents/Frameworks"/*.dylib; do
        [ -L "$real_dylib" ] || codesign --force --sign "$dev_id" "$real_dylib" || return 1
    done
    codesign --force --sign "$dev_id" "$app/Contents/Frameworks/Sparkle.framework" || return 1
    codesign --force --sign "$dev_id" --identifier com.definitelyreal.speakfree "$app" || return 1
    cp scripts/guarded-install.sh "$SF_STAGE_ROOT/guarded-install.sh" || return 1
    bash "$SF_STAGE_ROOT/guarded-install.sh" verify "$app" || return 1
    tar -czf "$SF_STAGE_ROOT/payload.tgz" -C "$SF_STAGE_ROOT" speakfree-fleet.app guarded-install.sh || return 1
    SF_ARCHIVE_SHA=$(shasum -a 256 "$SF_STAGE_ROOT/payload.tgz" | awk '{print $1}')
}

sf_stage_remote() {
    local remote="$1" stage
    echo "== stage and verify $remote =="
    stage=$(ssh -o BatchMode=yes "$remote" 'umask 077; mktemp -d /tmp/speakfree-fleet.XXXXXX') || return 1
    # Remote arguments below contain only this validated shell-safe path and SHA.
    [[ "$stage" =~ ^/tmp/speakfree-fleet\.[A-Za-z0-9]+$ ]] \
        || { echo "FATAL: invalid remote staging path" >&2; return 1; }
    [[ "$SF_ARCHIVE_SHA" =~ ^[a-f0-9]{64}$ ]] || return 1
    scp -o BatchMode=yes "$SF_STAGE_ROOT/payload.tgz" "$remote:$stage/payload.tgz" || return 1
    ssh -o BatchMode=yes "$remote" bash -s -- "$stage" "$SF_ARCHIVE_SHA" <<'REMOTE_STAGE_SCRIPT' || return 1
set -euo pipefail
stage="$1"
printf '%s  %s\n' "$2" "$stage/payload.tgz" | shasum -a 256 -c -
tar -xzf "$stage/payload.tgz" -C "$stage"
bash "$stage/guarded-install.sh" verify "$stage/speakfree-fleet.app"
REMOTE_STAGE_SCRIPT
    SF_NEW_REMOTE_STAGE="$stage"
}

sf_install_local() {
    bash "$SF_STAGE_ROOT/guarded-install.sh" install "$SF_STAGE_ROOT/speakfree-fleet.app" M3
}

sf_install_remote() {
    local remote="$1" stage="$2"
    # This invokes the newly staged, vendored guard; no Homebrew dependency on Macs.
    ssh -o BatchMode=yes "$remote" bash -s -- "$stage" <<'REMOTE_INSTALL_SCRIPT'
set -euo pipefail
stage="$1"
bash "$stage/guarded-install.sh" install "$stage/speakfree-fleet.app" remote
rm -rf "$stage"
REMOTE_INSTALL_SCRIPT
}

sf_cleanup_stage() { rm -rf "$SF_STAGE_ROOT"; }

sf_fleet_main() {
    local index
    case "${M3_ONLY:-0}" in 0|1) ;; *) echo "FATAL: M3_ONLY must be 0 or 1" >&2; return 1;; esac
    [ -z "${SPEAKFREE_CONFIG_DIR:-}" ] \
        || { echo "FATAL: unset SPEAKFREE_CONFIG_DIR before deployment" >&2; return 1; }
    cd "$REPO_DIR" || return 1
    sf_initialize_stage || return 1
    sf_build_and_vendor || return 1
    if [ "${M3_ONLY:-0}" != 1 ]; then
        for index in "${!REMOTES[@]}"; do
            sf_stage_remote "${REMOTES[$index]}" || return 1
            REMOTE_STAGES[$index]="$SF_NEW_REMOTE_STAGE"
        done
    fi
    # Every selected host now has a verified complete bundle. No app has stopped.
    sf_install_local || return 1
    if [ "${M3_ONLY:-0}" = 1 ]; then
        echo "== M3_ONLY=1: explicit override skips M5/M1 =="
    else
        for index in "${!REMOTES[@]}"; do
            sf_install_remote "${REMOTES[$index]}" "${REMOTE_STAGES[$index]}" || return 1
        done
    fi
    sf_cleanup_stage || return 1
    echo "== selected fleet deploy complete =="
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if ! sf_fleet_main "$@"; then
        echo "FATAL: deployment aborted; fleet may be partly updated. Preserve staged files for diagnosis: ${SF_STAGE_ROOT:-not created}" >&2
        exit 1
    fi
fi
