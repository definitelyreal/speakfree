#!/bin/bash
# ai-processed:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
# Shared local/remote installer. The staged app supplies its own vendored runtime.
# Tests source this file and replace OS operations with inert functions.
set -euo pipefail

SF_INSTALLED_APP=/Applications/speakfree.app
SF_TARGET_PATTERN='^/Applications/speakfree[.]app/Contents/MacOS/speakfree([[:space:]]|$)'

sf_verify_staged_app() {
    local staged_app="$1"
    [ -d "$staged_app" ] && [ ! -L "$staged_app" ] \
        && [ -x "$staged_app/Contents/MacOS/speakfree" ] \
        || { echo "FATAL: staged app is missing or invalid" >&2; return 1; }
    codesign --verify --deep "$staged_app" || return 1
    "$staged_app/Contents/MacOS/speakfree" --help >/dev/null || return 1
}

sf_prepare_update() {
    local staged_app="$1" receipt status=0
    # Deployment targets the ordinary production app/config. A test/custom override
    # would make its quiet-state observations refer to the wrong recording history.
    [ -z "${SPEAKFREE_CONFIG_DIR:-}" ] \
        || { echo "FATAL: unset SPEAKFREE_CONFIG_DIR before deployment" >&2; return 1; }
    receipt="$("$staged_app/Contents/MacOS/speakfree" prepare-update --timeout 600)" || status=$?
    if [ "$status" -ne 0 ] || [ "$receipt" != SPEAKFREE_UPDATE_READY ]; then
        echo "FATAL: update warning/quiet guard did not authorize a stop (exit $status); app left running" >&2
        return 1
    fi
}

sf_read_target_pids() {
    local output status=0 pid
    output="$(pgrep -f "$SF_TARGET_PATTERN")" || status=$?
    case "$status" in
        0)
            [ -n "$output" ] || { echo "FATAL: empty process-query success" >&2; return 1; }
            while IFS= read -r pid; do
                case "$pid" in ''|*[!0-9]*) echo "FATAL: invalid process-query result" >&2; return 1;; esac
            done <<< "$output"
            SF_TARGET_PIDS="$output"
            ;;
        1) SF_TARGET_PIDS="" ;;
        *) echo "FATAL: cannot determine whether the installed app is running" >&2; return 1 ;;
    esac
}

sf_stop_gracefully() {
    local pid attempt
    sf_read_target_pids || return 1
    for pid in $SF_TARGET_PIDS; do
        kill -TERM "$pid" || { echo "FATAL: graceful stop request failed; refusing replacement" >&2; return 1; }
    done
    for ((attempt=0; attempt<360; attempt++)); do
        sf_read_target_pids || return 1
        [ -n "$SF_TARGET_PIDS" ] || return 0
        sleep 0.5
    done
    echo "FATAL: app did not exit gracefully within 180 seconds; leaving its bundle intact" >&2
    return 1
}

sf_move_old_app_to_trash() {
    if [ -x /usr/bin/trash ]; then
        /usr/bin/trash "$SF_INSTALLED_APP" || return 1
    else
        local destination
        destination="$HOME/.Trash/speakfree-old-$(date +%Y%m%d-%H%M%S)-$$.app" || return 1
        [ -d "$HOME/.Trash" ] && [ ! -L "$HOME/.Trash" ] \
            || { echo "FATAL: user Trash is unavailable" >&2; return 1; }
        [ ! -e "$destination" ] && [ ! -L "$destination" ] \
            || { echo "FATAL: Trash destination already exists" >&2; return 1; }
        # -n plus the caller's source-absence check prevents in-place replacement.
        /bin/mv -n "$SF_INSTALLED_APP" "$destination" || return 1
    fi
}

sf_install_staged_app() {
    local staged_app="$1" label="$2"
    sf_verify_staged_app "$staged_app" || return 1
    sf_read_target_pids || return 1
    if [ -n "$SF_TARGET_PIDS" ]; then
        echo "== $label: waiting for quiet and the visible/audible update warning =="
        sf_prepare_update "$staged_app" || return 1
        # Invoke immediately after the positive receipt. An older app can still accept
        # a new Fn press between the final observation and SIGTERM; this is not atomic.
        sf_stop_gracefully || return 1
    else
        echo "== $label: app already stopped; no stop warning needed =="
        # Never signal an app that appeared after choosing the no-warning branch.
        # Re-query immediately before replacing files and abort if anything changed.
        sf_read_target_pids || return 1
        [ -z "$SF_TARGET_PIDS" ] \
            || { echo "FATAL: app started after the initial check; aborting without a signal" >&2; return 1; }
    fi
    if [ -e "$SF_INSTALLED_APP" ] || [ -L "$SF_INSTALLED_APP" ]; then
        sf_move_old_app_to_trash || return 1
    fi
    [ ! -e "$SF_INSTALLED_APP" ] && [ ! -L "$SF_INSTALLED_APP" ] \
        || { echo "FATAL: old app still exists; refusing to overwrite it" >&2; return 1; }
    cp -R "$staged_app" "$SF_INSTALLED_APP" || return 1
    codesign --verify --deep "$SF_INSTALLED_APP" || return 1
    open "$SF_INSTALLED_APP" || return 1
    sleep 5
    sf_read_target_pids || return 1
    [ -n "$SF_TARGET_PIDS" ] || { echo "FATAL: installed app did not remain running" >&2; return 1; }
    echo "$label RUNNING"
}

sf_guarded_install_main() {
    case "${1:-}" in
        verify) [ "$#" -eq 2 ] || return 64; sf_verify_staged_app "$2" ;;
        install) [ "$#" -eq 3 ] || return 64; sf_install_staged_app "$2" "$3" ;;
        *) echo "Usage: guarded-install.sh verify APP | install APP HOST_LABEL" >&2; return 64 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    sf_guarded_install_main "$@"
fi
