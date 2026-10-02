#!/usr/bin/env bash
# ai-suggestion:unverified · session:feat-agent-skills · 2026-09-24
# install-agent-skills.sh: copy the speakfree skill into your AI assistant's skills folder,
# or take it back out. Nothing is installed unless you run this yourself.
#
#   bash scripts/install-agent-skills.sh install [claude|codex|all]   (default: all)
#   bash scripts/install-agent-skills.sh remove  [claude|codex|all]
#   bash scripts/install-agent-skills.sh status
#
# Where the skill goes (official locations as of 2026-09):
#   Claude Code: ~/.claude/skills/speakfree/SKILL.md
#   Codex CLI:   ~/.agents/skills/speakfree/SKILL.md
# Set CLAUDE_SKILLS_DIR or CODEX_SKILLS_DIR to use a different folder.
#
# Safety: install never overwrites a folder it did not create (it checks for a marker
# file), and remove deletes only the files it installed. Exit codes: 0 ok, 1 refused or
# failed, 2 bad arguments.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/speakfree"
CODEX_DIR="${CODEX_SKILLS_DIR:-$HOME/.agents/skills}/speakfree"
MARKER=".installed-by-speakfree"

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

source_for() {
    case "$1" in
        claude) echo "$REPO/integrations/claude-code/speakfree/SKILL.md" ;;
        codex)  echo "$REPO/integrations/codex/speakfree/SKILL.md" ;;
    esac
}
dest_for() {
    case "$1" in
        claude) echo "$CLAUDE_DIR" ;;
        codex)  echo "$CODEX_DIR" ;;
    esac
}

install_one() {
    local name="$1" src dest
    src="$(source_for "$name")"; dest="$(dest_for "$name")"
    [ -f "$src" ] || { echo "Missing $src; run this from a speakfree checkout." >&2; return 1; }
    if [ -e "$dest" ] && [ ! -f "$dest/$MARKER" ]; then
        echo "Refusing: $dest already exists and was not installed by this script. Move it aside first." >&2
        return 1
    fi
    mkdir -p "$dest"
    cp "$src" "$dest/SKILL.md.tmp" && mv -f "$dest/SKILL.md.tmp" "$dest/SKILL.md"
    echo "speakfree skill, installed $(date +%Y-%m-%d)" > "$dest/$MARKER"
    echo "Installed $name skill: $dest/SKILL.md"
}

remove_one() {
    local name="$1" dest
    dest="$(dest_for "$name")"
    if [ ! -e "$dest" ]; then echo "Not installed for $name ($dest)"; return 0; fi
    if [ ! -f "$dest/$MARKER" ]; then
        echo "Refusing: $dest was not installed by this script; leaving it alone." >&2
        return 1
    fi
    rm -f "$dest/SKILL.md" "$dest/$MARKER"
    rmdir "$dest" 2>/dev/null || echo "Left $dest in place because it holds other files."
    echo "Removed $name skill from $dest"
}

status_one() {
    local name="$1" dest
    dest="$(dest_for "$name")"
    if [ -f "$dest/$MARKER" ]; then echo "$name: installed at $dest"
    elif [ -e "$dest" ]; then echo "$name: $dest exists but was not installed by this script"
    else echo "$name: not installed"; fi
}

action="${1:-}"; target="${2:-all}"
case "$target" in claude) targets=(claude) ;; codex) targets=(codex) ;; all) targets=(claude codex) ;; *) usage ;; esac
[ $# -le 2 ] || usage

rc=0
case "$action" in
    install) for t in "${targets[@]}"; do install_one "$t" || rc=1; done
             [ $rc -eq 0 ] && echo "Start a new Claude Code or Codex session to pick it up." ;;
    remove)  for t in "${targets[@]}"; do remove_one "$t" || rc=1; done ;;
    status)  for t in claude codex; do status_one "$t"; done ;;
    *) usage ;;
esac
exit $rc
