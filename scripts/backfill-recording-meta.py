#!/usr/bin/env python3
# Claude · 2026-06-11 · Session: 0e395e1f-1a60-4eb1-95a4-63bdaecd8eda
"""Backfill .meta.json provenance sidecars for recordings made before the app
wrote them natively (pre-1.5.1). Version/engine/model are inferred from the
diagnostic session logs: each recording is attributed to the most recent
"Session started — … vX.Y.Z" at or before its timestamp. Inferred sidecars
carry "inferred": true and are never overwritten on re-run; recordings that
predate the oldest log get appVersion "unknown".
"""
import json
import re
from datetime import datetime, timezone
from pathlib import Path

CONFIG = Path.home() / ".config/speakfree"
RECORDINGS = CONFIG / "recordings"
LOGS = CONFIG / "logs"

# Log filenames are UTC: speakfree-2026-06-11T17-55-07Z.log
LOG_NAME = re.compile(r"speakfree-(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})Z\.log")
VERSION_LINE = re.compile(r"Session started — \S+ v([\d.]+)")
MODEL_LINE = re.compile(r"Model loaded: (\S+) \(engine: (\w+)\)")
# Recording filenames are local time: recording-2026-06-11-105042-ABCD1234.wav
REC_NAME = re.compile(r"recording-(\d{4}-\d{2}-\d{2})-(\d{6})-")

sessions = []  # (epoch, version, engine, model)
for log in sorted(LOGS.glob("*.log")):
    m = LOG_NAME.match(log.name)
    if not m:
        continue
    d, hh, mm, ss = m.groups()
    epoch = datetime.fromisoformat(f"{d}T{hh}:{mm}:{ss}+00:00").timestamp()
    try:
        head = log.read_text(errors="replace")[:4000]
    except OSError:
        continue
    vm = VERSION_LINE.search(head)
    mm2 = MODEL_LINE.search(head)
    sessions.append((
        epoch,
        vm.group(1) if vm else "unknown",
        mm2.group(2) if mm2 else "unknown",
        mm2.group(1) if mm2 else "unknown",
    ))
sessions.sort()

written = skipped = unknown = 0
for wav in sorted(RECORDINGS.glob("recording-*.wav")):
    meta_path = wav.with_suffix("").with_suffix(".meta.json")
    # with_suffix twice strips nothing extra here (single dot), build explicitly:
    meta_path = wav.parent / (wav.stem + ".meta.json")
    if meta_path.exists():
        skipped += 1
        continue
    m = REC_NAME.match(wav.name)
    if not m:
        continue
    d, t = m.groups()
    local = datetime.strptime(f"{d} {t}", "%Y-%m-%d %H%M%S").astimezone()
    epoch = local.timestamp()
    session = None
    for s in sessions:
        if s[0] <= epoch:
            session = s
        else:
            break
    version, engine, model = (session[1], session[2], session[3]) if session else ("unknown", "unknown", "unknown")
    if version == "unknown":
        unknown += 1
    txt = wav.parent / (wav.stem + ".txt")
    chars = len(txt.read_text(errors="replace")) if txt.exists() else 0
    duration = max(0.0, (wav.stat().st_size - 44) / (16000 * 2))  # 16 kHz mono s16le
    meta = {
        "appVersion": version,
        "engine": engine,
        "model": model,
        "inputDevice": None,
        "date": local.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "durationSeconds": round(duration, 2),
        "transcriptChars": chars,
        "inferred": True,
    }
    meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    meta_path.chmod(0o600)
    written += 1

print(f"written={written} skipped(existing)={skipped} unknown-version={unknown}")
