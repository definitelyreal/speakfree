#!/usr/bin/env python3
# Claude · 2026-07-03 · Session: 6f785b82-a72f-49de-99dc-89f3a51601e4
"""Replay kept recordings through a speakfree binary and score against baselines.

Two modes, composable:

  --canaries          Replay the pinned canary clips and assert their known-good
                      properties. Run this after ANY FluidAudio/engine upgrade:
                      the 3s trailing-silence pad compensates for a runtime quirk
                      in the FluidAudio/CoreML decode path (truncation does not
                      reproduce on onnx-asr; the pad response is non-monotonic),
                      so an engine bump can silently re-break tail clauses.
  --corpus N          Replay the N most recent recordings whose .meta.json engine
                      matches the current engine, diff current raw output against
                      the stored .raw.txt baseline, and report similarity + the
                      largest diffs. Reporting only — ANE inference is slightly
                      nondeterministic, so treat diffs as leads, not failures.

Exit code is 1 only when a canary fails. Audio never leaves this machine.

Examples:
  python3 scripts/replay-regression.py --canaries
  python3 scripts/replay-regression.py --corpus 40
  python3 scripts/replay-regression.py --corpus 40 --binary .build/debug/speakfree
"""
import argparse, difflib, glob, json, os, re, subprocess, sys

PROD_BIN = "/Applications/speakfree.app/Contents/MacOS/speakfree"
REC_DIRS = [os.path.expanduser("~/.config/speakfree/recordings"),
            os.path.expanduser("~/.config/speakfree-streaming/recordings")]

# Pinned canaries: (wav basename, field, must-contain substring, why)
CANARIES = [
    ("recording-2026-06-12-103432-DF55B5FD.wav", "raw", "send a screener",
     "2026-06-12 tail-clause truncation: TDT flush drops the final clause without "
     "enough trailing pad (FluidAudio/CoreML runtime quirk, non-monotonic in pad length)"),
    ("recording-2026-07-03-004254-56BA6A96.wav", "raw", "chat history",
     "2026-07-03 vocab-boost regression class: 'chat history' must never become "
     "'chat Viktor' on the plain batch path"),
]


def norm_tokens(s):
    return re.sub(r"[^a-z0-9' ]+", " ", s.lower()).split()


def similarity(a, b):
    return difflib.SequenceMatcher(None, norm_tokens(a), norm_tokens(b)).ratio()


def process(binary, wav):
    p = subprocess.run([binary, "process", wav], capture_output=True, text=True, timeout=300)
    if not p.stdout.strip():
        return None
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        return None


def find_wav(basename):
    for d in REC_DIRS:
        p = os.path.join(d, basename)
        if os.path.exists(p):
            return p
    return None


def run_canaries(binary):
    failed = 0
    for basename, field, needle, why in CANARIES:
        wav = find_wav(basename)
        if not wav:
            print(f"CANARY SKIP (wav missing): {basename}")
            continue
        out = process(binary, wav)
        text = (out or {}).get(field, "")
        ok = needle.lower() in text.lower()
        print(f"CANARY {'PASS' if ok else 'FAIL'}: {basename} [{field} contains {needle!r}]")
        if not ok:
            failed += 1
            print(f"  why pinned: {why}")
            print(f"  got: {text[:200]}")
    return failed


def current_engine_model(config_dir):
    try:
        cfg = json.load(open(os.path.join(config_dir, "config.json")))
        return cfg.get("engine", "whisper"), cfg.get("parakeetModel", "")
    except OSError:
        return None, None


def run_corpus(binary, n):
    engine, model = current_engine_model(os.path.expanduser("~/.config/speakfree"))
    print(f"corpus mode: current engine={engine} model={model}")
    candidates = []
    for d in REC_DIRS:
        for meta_path in glob.glob(os.path.join(d, "*.meta.json")):
            base = meta_path[: -len(".meta.json")]
            if not (os.path.exists(base + ".wav") and os.path.exists(base + ".raw.txt")):
                continue
            try:
                meta = json.load(open(meta_path))
            except (OSError, json.JSONDecodeError):
                continue
            if meta.get("engine") != engine:
                continue
            candidates.append(base)
    candidates.sort(reverse=True)  # filename embeds the timestamp
    candidates = candidates[:n]
    print(f"replaying {len(candidates)} engine-matched recordings...")
    rows = []
    for i, base in enumerate(candidates):
        baseline = open(base + ".raw.txt").read().strip()
        out = process(binary, base + ".wav")
        raw = (out or {}).get("raw", "<no output>")
        sim = similarity(baseline, raw)
        rows.append((sim, os.path.basename(base), baseline, raw))
        print(f"[{i + 1}/{len(candidates)}] {sim:.3f} {os.path.basename(base)}", flush=True)
    rows.sort()
    sims = [r[0] for r in rows]
    print(f"\nmean similarity vs stored baselines: {sum(sims) / len(sims):.4f}"
          f" | min {sims[0]:.3f} | <0.9: {sum(s < 0.9 for s in sims)}")
    print("\nlargest divergences (leads, not verdicts — baselines age and ANE wobbles):")
    for sim, name, baseline, raw in rows[:5]:
        print(f"- {sim:.3f} {name}\n  stored : {baseline[:140]}\n  replay : {raw[:140]}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--canaries", action="store_true")
    ap.add_argument("--corpus", type=int, metavar="N")
    ap.add_argument("--binary", default=PROD_BIN)
    args = ap.parse_args()
    if not (args.canaries or args.corpus):
        ap.error("pick --canaries and/or --corpus N")
    failed = 0
    if args.canaries:
        failed = run_canaries(args.binary)
    if args.corpus:
        run_corpus(args.binary, args.corpus)
    sys.exit(1 if failed else 0)


main()
