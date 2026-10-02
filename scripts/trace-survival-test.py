#!/usr/bin/env python3
# ai-suggestion:unverified · session:feat-dictation-trace · 2026-09-24
"""Two-minute check: which apps keep speakfree's invisible dictation trace?

Run:  python3 scripts/trace-survival-test.py            (all apps below)
      python3 scripts/trace-survival-test.py claude chrome   (only some)

For each app and each of the two encodings, this script puts a short traced sentence on
the clipboard. You paste it into the app's message box (do NOT send), press Return here,
then select what you pasted in the app, copy it (Cmd+A then Cmd+C inside the box), and
press Return here again. The script reads the clipboard back and reports whether the
invisible part survived the round trip. Clear the box in the app afterward.

It only uses the clipboard (pbcopy / pbpaste). It never types, clicks, or sends anything,
and it restores nothing: your clipboard ends up holding the last test sentence. A
clipboard-history app may record the (synthetic) test sentences. speakfree may type into
Terminal and iTerm with simulated key presses rather than pasting, so treat a terminal
result as a guide.

Result per app and encoding:
  SURVIVED     every invisible character came back and decodes to the same trace
  DAMAGED      some invisible characters came back but the trace no longer decodes
  STRIPPED     the visible text came back without the invisible part
  NOT COPIED   the clipboard still held the "copy it now" marker (nothing was copied)
  SKIPPED      you typed s

Copying back shows what the app's text box keeps. Whether the model on the other end
receives it is a separate question: in Claude or ChatGPT you can also send the tags
sentence and ask "what hidden text follows the dot?" to check that directly.
"""
import json
import os
import subprocess
import sys

APPS = [
    ("claude", "Claude desktop app, message box"),
    ("codex", "Codex (ChatGPT) desktop app, message box"),
    ("vscode", "VS Code, Claude Code panel input"),
    ("terminal", "Claude Code in your terminal (iTerm/Terminal/Ghostty), at the prompt"),
    ("chrome", "Chrome, claude.ai message box"),
    ("safari", "Safari, chatgpt.com (Codex) message box"),
]

PAYLOAD = {"engine": "whisper", "heard": "ship the kama fix to the café build \U0001F44D",
           "unsure": ["kama 0.28"]}
ENV = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
MARKER = "speakfree survival test: copy the pasted text now"


def payload_json(ascii_only):
    # Same key order and format as DictationTrace.json in the app.
    parts = ['"speakfree_trace":1',
             '"engine":' + json.dumps(PAYLOAD["engine"], ensure_ascii=ascii_only),
             '"heard":' + json.dumps(PAYLOAD["heard"], ensure_ascii=ascii_only),
             '"unsure":[' + ",".join(json.dumps(u, ensure_ascii=ascii_only) for u in PAYLOAD["unsure"]) + "]"]
    return "{" + ",".join(parts) + "}"


def encode(kind):
    if kind == "tags":
        return "".join(chr(0xE0000 + b) for b in payload_json(True).encode("ascii"))
    return "".join(chr(0xFE00 + b) if b < 16 else chr(0xE0100 + b - 16)
                   for b in payload_json(False).encode("utf-8"))


def decode_runs(text):
    """Every run of tag or selector characters, decoded to bytes."""
    runs, cur, kind = [], [], None
    for ch in text + "\0":
        v = ord(ch)
        if 0xE0020 <= v <= 0xE007E:
            k, b = "tags", v - 0xE0000
        elif 0xFE00 <= v <= 0xFE0F:
            k, b = "selectors", v - 0xFE00
        elif 0xE0100 <= v <= 0xE01EF:
            k, b = "selectors", v - 0xE0100 + 16
        else:
            k, b = None, None
        if k != kind and cur:
            runs.append((kind, bytes(cur)))
            cur = []
        kind = k
        if k:
            cur.append(b)
    return runs


def pbcopy(s):
    subprocess.run(["pbcopy"], input=s.encode("utf-8"), env=ENV, check=True)


def pbpaste():
    return subprocess.run(["pbpaste"], capture_output=True, env=ENV).stdout.decode("utf-8", "replace")


def verdict(kind, sent_invisible, back):
    if back.strip() == MARKER:
        return "NOT COPIED"
    for k, raw in decode_runs(back):
        if k == kind:
            try:
                obj = json.loads(raw.decode("utf-8"))
                if obj.get("speakfree_trace") == 1 and obj.get("heard") == PAYLOAD["heard"]:
                    return "SURVIVED"
            except (UnicodeDecodeError, ValueError):
                pass
            return "DAMAGED (%d of %d invisible characters)" % (len(raw), len(sent_invisible))
    return "STRIPPED"


def main():
    chosen = [a for a in APPS if len(sys.argv) < 2 or a[0] in sys.argv[1:]]
    if not chosen:
        print("Unknown app. Choices:", ", ".join(a[0] for a in APPS))
        return 2
    results = []
    print(__doc__.split("Result per app")[0])
    for key, where in chosen:
        for kind in ("tags", "selectors"):
            invisible = encode(kind)
            sample = "speakfree survival test (%s, %s). ·%s" % (key, kind, invisible)
            pbcopy(sample)
            print("\n[%s / %s] Sentence is on the clipboard." % (key, kind))
            a = input("  1. Paste it into: %s (do not send). Press Return (s = skip this app): " % where)
            if a.strip().lower() == "s":
                results.append((key, kind, "SKIPPED"))
                if kind == "tags":
                    results.append((key, "selectors", "SKIPPED"))
                break
            pbcopy(MARKER)
            input("  2. In the app, select what you pasted and copy it (Cmd+A, Cmd+C). Press Return: ")
            v = verdict(kind, invisible, pbpaste())
            results.append((key, kind, v))
            print("  ->", v, " (clear the box in the app now)")
    print("\nResults")
    for key, kind, v in results:
        print("  %-9s %-10s %s" % (key, kind, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
