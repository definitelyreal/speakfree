#!/usr/bin/env python3
# ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22
"""Key-release-to-text latency report from speakfree's diagnostic logs.

Reads ~/.config/speakfree/logs/*.log (or --logs DIR) and prints percentiles of the time from
releasing the hotkey to insertion submission, split by build and engine, plus the causes of slow
takes: the 1.2 s post-release speech extension, cold model loads, and empty-output rescues.

Two line formats are understood:
  * `Transcription complete: 0.41s from key-release to text-inserted, N chars` (all builds)
  * `Latency: total=... wait=... infer=... ext=yes|no cold=yes|no ...` (2026-09-22 onward),
    which carries the per-stage breakdown.

Only takes whose insertion was submitted are counted (as with the `Transcription complete` line): empty
results, errors, Secure Input fallbacks and Edit Mode segments do not appear.

Prints numbers only. Raw diagnostic logs can contain transcript content; this report
extracts only timings and fixed diagnostic fields.

    python3 scripts/latency-report.py                 # all logs
    python3 scripts/latency-report.py --since 2026-09-15
    python3 scripts/latency-report.py --json          # machine-readable
"""
import argparse
import json
import math
import os
import re
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

COMPLETE_RE = re.compile(r"Transcription complete: ([0-9.]+)s from key-release")
LATENCY_RE = re.compile(r"Latency: (.*)$")
BUILD_RE = re.compile(r"Build: commit (\w+)")
CONFIG_ENGINE_RE = re.compile(r"Config: engine=(\w+)")
TRANSCRIBER_RE = re.compile(r"Transcriber configured: .*\(engine: (\w+)\)")
TIME_RE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] ")
FILE_DATE_RE = re.compile(r"speakfree-(\d{4})-(\d\d)-(\d\d)T(\d\d)-(\d\d)-(\d\d)Z")

# Takes whose latency lands here almost always paid the 1.2 s extension (1.2 s cap plus the
# ~0.2 s everything else); used only for old lines that do not say so directly.
EXTENSION_BAND = (1.25, 1.60)


def percentile(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = (len(sorted_vals) - 1) * p / 100.0
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi:
        return sorted_vals[int(k)]
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def parse_fields(s):
    out = {}
    for tok in s.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def local_start_date(path):
    """Session start date in local time, from the UTC stamp in the log file name."""
    m = FILE_DATE_RE.search(os.path.basename(path))
    if not m:
        return None
    y, mo, d, h, mi, s = map(int, m.groups())
    utc = datetime(y, mo, d, h, mi, s, tzinfo=timezone.utc)
    return utc.astimezone().date()


def parse_log(path):
    """Yield one dict per completed dictation."""
    build, engine = "unknown", "unknown"
    day = local_start_date(path)
    last_secs = None
    pending_cold = False
    pending_rescue = False
    takes = []
    with open(path, errors="replace") as f:
        for line in f:
            tm = TIME_RE.match(line)
            if tm and day is not None:
                secs = int(tm.group(1)) * 3600 + int(tm.group(2)) * 60 + int(tm.group(3))
                # Lines are local wall time with no date and are written in order, so any clear
                # step backwards is a midnight (startup lines can be out of order by seconds).
                if last_secs is not None and secs < last_secs - 300:
                    day = day + timedelta(days=1)
                last_secs = secs
            if (m := BUILD_RE.search(line)):
                build = m.group(1)
            elif (m := CONFIG_ENGINE_RE.search(line)) or (m := TRANSCRIBER_RE.search(line)):
                engine = m.group(1)
            elif "WhisperEngine: transcribing" in line or "WhisperEngine: inference" in line:
                engine = "whisper"   # engine switches in Settings are not logged; infer them
            elif "ParakeetEngine: uncertain take" in line or "ParakeetEngine: slow stages" in line \
                    or "ParakeetEngine: model loaded" in line:
                engine = "parakeet"
            elif "AudioRecorder: recording started" in line:
                pending_cold = pending_rescue = False   # flags belong to one take
            elif "waiting on model load" in line:
                pending_cold = True
            elif "whisper rescue" in line or "model-empty" in line:
                pending_rescue = True
            elif (m := COMPLETE_RE.search(line)):
                takes.append({
                    "day": day.isoformat() if day else None, "build": build, "engine": engine,
                    "total": float(m.group(1)), "cold": pending_cold, "rescue": pending_rescue,
                    "stages": None,
                })
                pending_cold = pending_rescue = False
            elif (m := LATENCY_RE.search(line)) and takes:
                fields = parse_fields(m.group(1))
                take = takes[-1]
                take["stages"] = {k: float(v) for k, v in fields.items()
                                  if k in ("wait", "stop", "queue", "infer", "text", "save", "insert")
                                  and v != "na"}
                take["ext"] = fields.get("ext") == "yes"
                take["cold"] = take["cold"] or fields.get("cold") == "yes"
                take["preload"] = fields.get("preload") == "yes"
                if "engine" in fields:
                    take["engine"] = fields["engine"]
    return takes


def summarize(vals):
    s = sorted(vals)
    return {
        "n": len(s),
        "p10": percentile(s, 10), "p50": percentile(s, 50), "p75": percentile(s, 75),
        "p90": percentile(s, 90), "p95": percentile(s, 95), "p99": percentile(s, 99),
        "max": s[-1] if s else float("nan"),
    }


def extended(take):
    """Did this take wait out the long post-release extension? `ext=yes` only says the cap was
    raised; a take can still end early on 90 ms of silence, so judge by the measured wait."""
    wait = (take.get("stages") or {}).get("wait")
    if wait is not None:
        # The normal cap is 220 ms plus a 30 ms tick and main-thread lag; 0.35 s clears that.
        return take.get("ext", False) and wait > 0.35
    return (EXTENSION_BAND[0] <= take["total"] <= EXTENSION_BAND[1]
            and not take["cold"] and not take["rescue"])


def build_report(takes):
    rep = {"overall": summarize([t["total"] for t in takes])}
    n = len(takes) or 1
    rep["share_extended"] = sum(extended(t) for t in takes) / n
    rep["share_extended_measured"] = sum(1 for t in takes if "ext" in t)
    rep["cold_loads"] = sum(t["cold"] for t in takes)
    rep["rescues"] = sum(t["rescue"] for t in takes)
    clean = [t["total"] for t in takes if not extended(t) and not t["cold"] and not t["rescue"]]
    rep["clean"] = summarize(clean)
    by = defaultdict(list)
    for t in takes:
        by[(t["build"], t["engine"])].append(t)
    rep["by_build"] = []
    for (b, e), ts in sorted(by.items(), key=lambda kv: -len(kv[1])):
        s = summarize([t["total"] for t in ts])
        s.update(build=b, engine=e,
                 share_extended=sum(extended(t) for t in ts) / len(ts),
                 cold=sum(t["cold"] for t in ts))
        rep["by_build"].append(s)
    staged = [t for t in takes if t.get("stages")]
    rep["stages_median"] = {}
    for k in ("wait", "stop", "queue", "infer", "text", "save", "insert"):
        vals = sorted(t["stages"][k] for t in staged if k in t["stages"])
        if vals:
            rep["stages_median"][k] = {"p50": percentile(vals, 50), "p90": percentile(vals, 90)}
    return rep


def fmt(x):
    return "  n/a" if x != x else f"{x:5.2f}"


def print_report(rep):
    o = rep["overall"]
    print(f"Dictations: {o['n']}   key release to insertion submission, seconds")
    print("          p10   p50   p75   p90   p95   p99   max")
    for label, s in (("all", o), ("clean", rep["clean"])):
        print(f"  {label:6s}" + "".join(" " + fmt(s[k]) for k in
                                         ("p10", "p50", "p75", "p90", "p95", "p99", "max"))
              + f"   (n={s['n']})")
    print(f"\n  paid the 1.2 s post-release extension: {rep['share_extended']:.1%}"
          f"  ({rep['share_extended_measured']} measured directly, rest inferred from the 1.25-1.6 s band)")
    print(f"  cold model loads after key release:   {rep['cold_loads']}")
    print(f"  empty-output retries/rescues:         {rep['rescues']}")
    if rep["stages_median"]:
        print("\n  stage medians (p50 / p90), from Latency: lines")
        for k, v in rep["stages_median"].items():
            print(f"    {k:7s} {v['p50']:.3f} / {v['p90']:.3f}")
    print("\n  by build            engine     n    p50   p90  extended  cold")
    for s in rep["by_build"]:
        print(f"    {s['build']:16s} {s['engine']:9s} {s['n']:5d} {fmt(s['p50'])} {fmt(s['p90'])}"
              f"   {s['share_extended']:5.1%}  {s['cold']:4d}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--logs", default=os.path.expanduser("~/.config/speakfree/logs"))
    ap.add_argument("--since", help="YYYY-MM-DD, local date")
    ap.add_argument("--until", help="YYYY-MM-DD, local date, inclusive")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    paths = sorted(os.path.join(args.logs, p) for p in os.listdir(args.logs) if p.endswith(".log"))
    takes = [t for p in paths for t in parse_log(p)]
    if args.since:
        takes = [t for t in takes if t["day"] and t["day"] >= args.since]
    if args.until:
        takes = [t for t in takes if t["day"] and t["day"] <= args.until]
    if not takes:
        print("No completed dictations found.", file=sys.stderr)
        return 1
    rep = build_report(takes)
    if args.json:
        json.dump(rep, sys.stdout, indent=2, default=str)
        print()
    else:
        print_report(rep)
    return 0


if __name__ == "__main__":
    sys.exit(main())
