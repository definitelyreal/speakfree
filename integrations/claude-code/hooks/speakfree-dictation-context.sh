#!/bin/bash
# ai-suggestion:unverified · session:feat-dictation-trace · 2026-09-24
# speakfree UserPromptSubmit hook: when a prompt contains text you dictated with speakfree,
# add what the speech engine actually heard (raw engine text before speakfree's cleanup,
# plus the words it was unsure of) as extra context for the model.
#
# How it works: the hook JSON arrives on stdin; `speakfree match --hook` takes its "prompt",
# finds the saved dictations the prompt came from (never trusting hidden traces on their own), and
# prints {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":...}}
# or nothing. It always exits 0, so it can never block or erase a prompt. It only reads the
# archive when saving is on in speakfree (Keep Recordings & Transcripts), never uses the
# network, and writes nothing. Typical run time is about 50 ms (see docs/DICTATION-TRACE.md).
#
# Install for Claude Code: copy this file somewhere stable, make it executable, and add to
# ~/.claude/settings.json (or a project's .claude/settings.json):
#
#   {
#     "hooks": {
#       "UserPromptSubmit": [
#         { "hooks": [ { "type": "command",
#                        "command": "$HOME/.claude/hooks/speakfree-dictation-context.sh",
#                        "timeout": 5 } ] }
#       ]
#     }
#   }
#
# Codex uses the same event name, input field ("prompt") and output shape. In
# ~/.codex/config.toml:
#
#   [[hooks.UserPromptSubmit]]
#   [[hooks.UserPromptSubmit.hooks]]
#   type = "command"
#   command = "/Users/YOU/.claude/hooks/speakfree-dictation-context.sh"
#
# Privacy: the added context contains your raw dictated words for that prompt, which the
# assistant then sends to its model provider along with the prompt itself.

SPEAKFREE="$(command -v speakfree 2>/dev/null)"
if [ -z "$SPEAKFREE" ]; then
    for p in /Applications/speakfree.app/Contents/MacOS/speakfree \
             "$HOME/Applications/speakfree.app/Contents/MacOS/speakfree"; do
        if [ -x "$p" ]; then SPEAKFREE="$p"; break; fi
    done
fi
[ -n "$SPEAKFREE" ] || exit 0
exec "$SPEAKFREE" match --hook
