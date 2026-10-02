#!/usr/bin/env python3
# ai-suggestion:unverified · session:feat-dictation-trace · 2026-09-24
"""Time `speakfree match --hook` end to end (process start to exit), the way Claude Code runs it.

Usage: bench-match-hook.py <speakfree-binary> <fixture-config-dir> "<known take text>" [runs=50] [hook-script]

With hook-script (integrations/claude-code/hooks/speakfree-dictation-context.sh), the
script is timed instead, with the binary's folder first on PATH so it finds that build.

Build the fixture first with scripts/make-match-fixture.py. The fixture is used through
SPEAKFREE_CONFIG_DIR, so the real ~/.config/speakfree is never read. Prints the hook's output
once, then p50 / p90 / max wall-clock milliseconds for a matching prompt and a non-matching one.
"""
import json
import os
import statistics
import subprocess
import sys
import time


def run(cmd, env, stdin):
    t0 = time.perf_counter()
    p = subprocess.run(cmd, input=stdin.encode(), env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return (time.perf_counter() - t0) * 1000, p.stdout.decode(), p.returncode


def pct(values, q):
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def main():
    binary, fixture, known = sys.argv[1], sys.argv[2], sys.argv[3]
    runs = int(sys.argv[4]) if len(sys.argv) > 4 else 50
    env = dict(os.environ, SPEAKFREE_CONFIG_DIR=fixture)
    cmd = [binary, "match", "--hook"]
    if len(sys.argv) > 5:
        cmd = [sys.argv[5]]
        env["PATH"] = os.path.dirname(os.path.abspath(binary)) + ":" + env.get("PATH", "")
    prompts = {
        "matching": "Some typed intro. " + known + " And a few more typed words at the end.",
        "no match": "A prompt that was typed by hand and never dictated at all, about nothing much.",
    }
    for label, prompt in prompts.items():
        stdin = json.dumps({"session_id": "bench", "hook_event_name": "UserPromptSubmit",
                            "cwd": "/", "prompt": prompt})
        run(cmd, env, stdin)  # warm the file cache once
        times = []
        out = ""
        for _ in range(runs):
            ms, out, code = run(cmd, env, stdin)
            if code != 0:
                print("exit code", code)
            times.append(ms)
        print(f"== {label}: output ==")
        print(out.strip() or "(nothing)")
        print(f"== {label}: {runs} runs  p50 {statistics.median(times):.0f} ms  "
              f"p90 {pct(times, 0.9):.0f} ms  max {max(times):.0f} ms")


main()
