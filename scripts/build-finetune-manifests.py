# ai-processed:unverified · session:019ff9d6-c78f-7572-9487-bce2a3b0f14a · 2026-08-13
"""Build leakage-resistant NeMo manifests from independently checked labels.

Production Parakeet transcripts are deliberately never accepted as labels. Pseudo-labels must
either have local teacher agreement or a privacy-filtered cloud adjudication. Hand-written .gt.txt
files are reserved for evaluation and are never placed in the training split.
"""

from __future__ import annotations

import argparse
import json
import wave
from pathlib import Path


def audio_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as audio:
        return audio.getnframes() / audio.getframerate()


def cloud_texts(path: Path | None) -> dict[str, str]:
    if path is None or not path.exists():
        return {}
    data = json.loads(path.read_text())
    return {
        key: value.get("text", "").strip()
        for key, value in data.items()
        if value.get("text", "").strip()
    }


def accepted_rows(scoreboard: Path, cloud: dict[str, str]) -> tuple[list[dict], list[dict]]:
    rows = json.loads(scoreboard.read_text()).get("rows", [])
    accepted, rejected = [], []
    for row in rows:
        base = Path(row["base"])
        wav = Path(f"{base}.wav")
        cloud_label = cloud.get(base.name)
        if cloud_label:
            label, source = cloud_label, "elevenlabs-scribe-v2"
        elif row.get("teachersAgree"):
            label, source = str(row.get("whisperLargeV3") or "").strip(), "teacher-consensus"
        else:
            rejected.append({"base": str(base), "reason": "teacher-disagreement"})
            continue
        if not label or not wav.exists():
            rejected.append({"base": str(base), "reason": "missing-label-or-audio"})
            continue
        accepted.append({
            "audio_filepath": str(wav.resolve()),
            "duration": float(row.get("duration") or audio_duration(wav)),
            "text": label,
            "label_source": source,
            "base": str(base),
        })
    return accepted, rejected


def gold_rows(recordings: Path) -> list[dict]:
    result = []
    for gt in recordings.rglob("*.gt.txt"):
        # A gold file may live beside either foo.wav or foo.gt.wav depending on the old harness.
        stem = str(gt)[:-len(".gt.txt")]
        candidates = (Path(f"{stem}.wav"), Path(f"{stem}.gt.wav"))
        wav = next((candidate for candidate in candidates if candidate.exists()), None)
        text = gt.read_text(errors="replace").strip()
        if wav and text:
            result.append({
                "audio_filepath": str(wav.resolve()),
                "duration": audio_duration(wav),
                "text": text,
            })
    return sorted(result, key=lambda row: row["audio_filepath"])


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scoreboard", type=Path, required=True)
    parser.add_argument("--cloud-labels", type=Path)
    parser.add_argument("--recordings", type=Path,
                        default=Path.home() / ".config/speakfree/recordings")
    parser.add_argument("--output", type=Path, default=Path("build/finetune-manifests"))
    parser.add_argument("--validation-fraction", type=float, default=0.1)
    parser.add_argument(
        "--allow-missing-gold",
        action="store_true",
        help="prepare pilot manifests even when no hand-labeled audio is available; never train",
    )
    args = parser.parse_args()

    accepted, rejected = accepted_rows(args.scoreboard, cloud_texts(args.cloud_labels))
    # Recording filenames begin with an ISO-like timestamp. Hold out the newest slice rather than
    # randomly mixing adjacent takes, which reduces conversational/session leakage across splits.
    accepted.sort(key=lambda row: row["base"])
    validation_count = min(len(accepted), max(1, round(len(accepted) * args.validation_fraction)))
    train, validation = accepted[:-validation_count], accepted[-validation_count:]
    test = gold_rows(args.recordings)

    if not test and not args.allow_missing_gold:
        raise SystemExit(
            "Refusing to build training manifests: no .gt.txt file has matching audio. "
            "Restore/create a gold evaluation set, or use --allow-missing-gold for preparation only."
        )

    # Keep provenance/audit fields beside the NeMo-compatible three-field manifests.
    args.output.mkdir(parents=True, exist_ok=True)
    nemo_fields = ("audio_filepath", "duration", "text")
    write_jsonl(args.output / "train.jsonl", [
        {key: row[key] for key in nemo_fields} for row in train
    ])
    write_jsonl(args.output / "validation.jsonl", [
        {key: row[key] for key in nemo_fields} for row in validation
    ])
    write_jsonl(args.output / "test-gold.jsonl", test)
    (args.output / "audit.json").write_text(json.dumps({
        "accepted": accepted,
        "rejected": rejected,
        "counts": {"train": len(train), "validation": len(validation), "goldTest": len(test)},
        "guardrails": {
            "productionSelfLabelsAccepted": False,
            "goldUsedForTraining": False,
        },
    }, indent=2))
    print(json.dumps({"train": len(train), "validation": len(validation),
                      "goldTest": len(test), "rejected": len(rejected)}, indent=2))


if __name__ == "__main__":
    main()
