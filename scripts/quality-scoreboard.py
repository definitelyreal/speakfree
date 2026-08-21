# ai-processed:unverified · session:019ff9d6-c78f-7572-9487-bce2a3b0f14a · 2026-08-12
"""Standing, local-only ASR agreement scoreboard for speakfree's private recording corpus.

Outputs contain private transcripts and therefore default under build/ (gitignored). The harness
compares stored production Parakeet v2 output with two independent local teachers: Whisper
large-v3 and Parakeet v3. Teacher disagreement is flagged, never promoted to ground truth.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import subprocess
import tempfile
import wave
from pathlib import Path


def tokens(text: str) -> list[str]:
    return re.sub(r"[^\w\s']", " ", (text or "").lower()).split()


def wer(reference: str, hypothesis: str) -> float:
    ref, hyp = tokens(reference), tokens(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    row = list(range(len(hyp) + 1))
    for index, expected in enumerate(ref, 1):
        previous = row[0]
        row[0] = index
        for column, actual in enumerate(hyp, 1):
            old = row[column]
            row[column] = previous if expected == actual else 1 + min(
                previous, row[column], row[column - 1]
            )
            previous = old
    return row[-1] / len(ref)


def stem(path: Path) -> Path:
    name = str(path)
    for suffix in (".meta.json", ".raw.txt", ".txt", ".wav"):
        if name.endswith(suffix):
            return Path(name[: -len(suffix)])
    return path


def duration(path: Path) -> float:
    with wave.open(str(path), "rb") as audio:
        return audio.getnframes() / audio.getframerate()


def choose_sample(recordings: Path, size: int, seed: int) -> list[dict]:
    rows = []
    for wav in recordings.glob("recording-*.wav"):
        if wav.name.endswith(".bt.wav"):
            continue
        base = stem(wav)
        raw = Path(f"{base}.raw.txt")
        if not raw.exists():
            continue
        meta_path = Path(f"{base}.meta.json")
        try:
            meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
            seconds = float(meta.get("durationSeconds") or duration(wav))
        except (OSError, ValueError, json.JSONDecodeError, wave.Error):
            continue
        rows.append({"base": str(base), "duration": seconds})

    buckets = [[], [], []]
    for row in rows:
        seconds = row["duration"]
        buckets[0 if seconds < 5 else 1 if seconds <= 15 else 2].append(row)
    rng = random.Random(seed)
    per_bucket = max(1, size // 3)
    selected = []
    for bucket in buckets:
        selected.extend(rng.sample(bucket, min(per_bucket, len(bucket))))
    remaining = [row for row in rows if row not in selected]
    selected.extend(rng.sample(remaining, min(size - len(selected), len(remaining))))
    return sorted(selected, key=lambda row: row["base"])


def run_whisper(binary: Path, model: Path, wav: Path) -> str:
    result = subprocess.run(
        [str(binary), "-m", str(model), "-f", str(wav), "-nt", "-np", "-l", "en", "-t", "4"],
        check=True, capture_output=True, text=True, timeout=300,
    )
    return result.stdout.strip()


def run_parakeet(binary: Path, wav: Path) -> dict:
    with tempfile.NamedTemporaryFile(suffix=".json") as output:
        subprocess.run(
            [str(binary), "transcribe", str(wav), "--model-version", "v3",
             "--word-timestamps", "--output-json", output.name],
            check=True, capture_output=True, text=True, timeout=300,
        )
        data = json.loads(Path(output.name).read_text())
    words = data.get("wordTimings") or []
    return {
        "text": (data.get("text") or "").strip(),
        "confidence": data.get("confidence"),
        "minWordConfidence": min((word.get("confidence", 1) for word in words), default=None),
    }


def transcribe(sample: list[dict], whisper: Path, model: Path, parakeet: Path, output: Path) -> list[dict]:
    prior = {row["base"]: row for row in json.loads(output.read_text())} if output.exists() else {}
    results = []
    for index, item in enumerate(sample, 1):
        base = Path(item["base"])
        key = str(base)
        row = prior.get(key, dict(item))
        try:
            row["production"] = Path(f"{base}.raw.txt").read_text(errors="replace").strip()
            row.setdefault("whisperLargeV3", run_whisper(whisper, model, Path(f"{base}.wav")))
            row.setdefault("parakeetV3", run_parakeet(parakeet, Path(f"{base}.wav")))
            row.pop("error", None)
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
            row["error"] = str(error)
        results.append(row)
        output.write_text(json.dumps(results, indent=2))
        print(f"{index}/{len(sample)}", flush=True)
    return results


def analyze(rows: list[dict], output: Path) -> dict:
    scored = []
    for row in rows:
        if row.get("error"):
            continue
        whisper_text = row["whisperLargeV3"]
        parakeet_text = row["parakeetV3"]["text"]
        teacher_wer = wer(whisper_text, parakeet_text)
        scored.append({
            **row,
            "teacherWER": round(teacher_wer, 4),
            "teachersAgree": teacher_wer <= 0.10,
            "productionVsWhisperWER": round(wer(whisper_text, row["production"]), 4),
            "productionVsParakeetV3WER": round(wer(parakeet_text, row["production"]), 4),
        })
    agreed = [row for row in scored if row["teachersAgree"]]
    summary = {
        "sampleCount": len(scored),
        "teacherAgreementCount": len(agreed),
        "teacherDisagreementCount": len(scored) - len(agreed),
        "productionMeanWEROnConsensus": round(
            sum(row["productionVsWhisperWER"] for row in agreed) / len(agreed), 4
        ) if agreed else None,
        "rows": scored,
    }
    output.write_text(json.dumps(summary, indent=2))
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("sample", "transcribe", "analyze", "all"))
    parser.add_argument("--recordings", type=Path, default=Path.home() / ".config/speakfree/recordings")
    parser.add_argument("--output", type=Path, default=Path("build/quality-scoreboard"))
    parser.add_argument("--size", type=int, default=90)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--whisper", type=Path, default=Path("/opt/homebrew/bin/whisper-cli"))
    parser.add_argument("--whisper-model", type=Path,
                        default=Path.home() / ".config/speakfree/models/ggml-large-v3.bin")
    parser.add_argument("--parakeet", type=Path,
                        default=Path(".build/arm64-apple-macosx/debug/fluidaudiocli"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sample_path = args.output / "sample.json"
    raw_path = args.output / "transcriptions.json"
    score_path = args.output / "scoreboard.json"
    if args.command in ("sample", "all"):
        sample_path.write_text(json.dumps(choose_sample(args.recordings, args.size, args.seed), indent=2))
    sample = json.loads(sample_path.read_text())
    if args.command in ("transcribe", "all"):
        transcribe(sample, args.whisper, args.whisper_model, args.parakeet, raw_path)
    if args.command in ("analyze", "all"):
        result = analyze(json.loads(raw_path.read_text()), score_path)
        print(json.dumps({key: value for key, value in result.items() if key != "rows"}, indent=2))


if __name__ == "__main__":
    main()
