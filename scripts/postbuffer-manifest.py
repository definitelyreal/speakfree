#!/usr/bin/env python3
# ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22
"""Build a replay manifest for `perf-harness postbuffer-replay` from logs and archived takes.

Pairs each completed dictation in ~/.config/speakfree/logs with its WAV in
~/.config/speakfree/recordings and works out where the key was released:

  * takes recorded after 2026-09-22 carry `keyReleaseSample` in their .meta.json (exact);
  * older takes whose latency sits in the 1.25-1.6 s band waited the full 1.2 s extension, so
    the release is 1.2 s before the end of the recording (estimate, marked "estimated").

Other older takes are skipped: their wait was <= 220 ms of unknown length.
Writes JSON only (ids, paths, sample indices). No transcript text is read.

    python3 scripts/postbuffer-manifest.py --since 2026-09-04 --out build/.../manifest.json
"""
import argparse
import json
import os
import re
import sys
import wave
from datetime import datetime, timedelta, timezone

TIME_RE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] ")
FILE_DATE_RE = re.compile(r"speakfree-(\d{4})-(\d\d)-(\d\d)T(\d\d)-(\d\d)-(\d\d)Z")
COMPLETE_RE = re.compile(r"Transcription complete: ([0-9.]+)s from key-release")
REC_NAME_RE = re.compile(r"^recording-(\d{4}-\d\d-\d\d)-(\d{6})-[0-9A-F]+\.wav$")
EXTENDED_BAND = (1.25, 1.60)
EXTENDED_CAP_SAMPLES = int(1.2 * 16000)


def local_start(path):
    m = FILE_DATE_RE.search(os.path.basename(path))
    if not m:
        return None
    y, mo, d, h, mi, s = map(int, m.groups())
    return datetime(y, mo, d, h, mi, s, tzinfo=timezone.utc).astimezone().replace(tzinfo=None)


def takes_from_log(path):
    """(start datetime, latency seconds, cold, rescue) per completed take."""
    start = local_start(path)
    if start is None:
        return []
    day = start.date()
    last = None
    rec_start = None
    cold = rescue = False
    out = []
    with open(path, errors="replace") as f:
        for line in f:
            m = TIME_RE.match(line)
            if not m:
                continue
            secs = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
            if last is not None and secs < last - 300:   # in-order lines: a step back is midnight
                day += timedelta(days=1)
            last = secs
            ts = datetime.combine(day, datetime.min.time()) + timedelta(seconds=secs)
            if "AudioRecorder: recording started" in line:
                rec_start, cold, rescue = ts, False, False
            elif "waiting on model load" in line:
                cold = True
            elif "whisper rescue" in line or "model-empty" in line:
                rescue = True
            elif (c := COMPLETE_RE.search(line)) and rec_start is not None:
                out.append((rec_start, float(c.group(1)), cold, rescue))
                rec_start = None
    return out


def index_recordings(rec_dir):
    idx = {}
    with os.scandir(rec_dir) as it:
        for e in it:
            m = REC_NAME_RE.match(e.name)
            if m:
                ts = datetime.strptime(m.group(1) + m.group(2), "%Y-%m-%d%H%M%S")
                idx.setdefault(ts, []).append(e.path)
    return idx


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--logs", default=os.path.expanduser("~/.config/speakfree/logs"))
    ap.add_argument("--recordings", default=os.path.expanduser("~/.config/speakfree/recordings"))
    ap.add_argument("--since", default="2000-01-01")
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)

    idx = index_recordings(args.recordings)
    manifest, stats = [], {"takes": 0, "matched": 0, "exact": 0, "estimated": 0, "skipped_unknown_release": 0}
    for name in sorted(os.listdir(args.logs)):
        if not name.endswith(".log"):
            continue
        for rec_start, latency, cold, rescue in takes_from_log(os.path.join(args.logs, name)):
            if rec_start.date().isoformat() < args.since:
                continue
            stats["takes"] += 1
            wav = None
            for delta in (0, 1, -1, 2):
                cands = idx.get(rec_start + timedelta(seconds=delta))
                if cands and len(cands) == 1:
                    wav = cands[0]
                    break
            if wav is None:
                continue
            stats["matched"] += 1
            meta_path = wav[:-4] + ".meta.json"
            release, kind = None, None
            try:
                with open(meta_path) as f:
                    meta = json.load(f)
                if isinstance(meta.get("keyReleaseSample"), int):
                    release, kind = meta["keyReleaseSample"], "exact"
            except (OSError, ValueError):
                pass
            if release is None:
                if EXTENDED_BAND[0] <= latency <= EXTENDED_BAND[1] and not cold and not rescue:
                    with wave.open(wav) as w:
                        release = w.getnframes() - EXTENDED_CAP_SAMPLES
                    kind = "estimated"
                else:
                    stats["skipped_unknown_release"] += 1
                    continue
            if release <= 0:
                continue
            stats[kind] += 1
            manifest.append({"id": os.path.basename(wav)[:-4], "wav": wav, "releaseSample": release,
                             "latency": latency, "release": kind})
    with open(args.out, "w") as f:
        json.dump(manifest, f, indent=1)
    print(json.dumps(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main())
