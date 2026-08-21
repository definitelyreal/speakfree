# ai-processed:unverified · session:019ff9d6-c78f-7572-9487-bce2a3b0f14a · 2026-08-12
"""Privacy-filtered ElevenLabs Scribe pseudo-labels for hard speakfree takes.

Requires ELEVENLABS_API_KEY. Inputs with missing target-app provenance or a private messaging target
are excluded. Results belong under build/ and must never be committed.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import secrets
import urllib.request
from pathlib import Path


PRIVATE_BUNDLE_MARKERS = (
    "signal", "whatsapp", "telegram", "messages", "mobile.sms", "imessage",
    "com.apple.MobileSMS", "org.whispersystems",
)


def metadata(base: Path) -> dict:
    path = Path(f"{base}.meta.json")
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def cloud_eligible(base: Path) -> tuple[bool, str]:
    target = str(metadata(base).get("targetApp") or "").strip()
    if not target:
        return False, "unknown-target"
    lower = target.lower()
    if any(marker.lower() in lower for marker in PRIVATE_BUNDLE_MARKERS):
        return False, "private-messaging-target"
    return True, "eligible"


def multipart(fields: dict[str, str], file_path: Path) -> tuple[bytes, str]:
    boundary = "----speakfree-" + secrets.token_hex(16)
    chunks: list[bytes] = []
    for name, value in fields.items():
        chunks.extend([
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
            value.encode(), b"\r\n",
        ])
    content_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    chunks.extend([
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="file"; filename="{file_path.name}"\r\n'.encode(),
        f"Content-Type: {content_type}\r\n\r\n".encode(),
        file_path.read_bytes(), b"\r\n", f"--{boundary}--\r\n".encode(),
    ])
    return b"".join(chunks), boundary


def transcribe(api_key: str, wav: Path) -> dict:
    body, boundary = multipart({
        "model_id": "scribe_v2",
        "language_code": "eng",
        "tag_audio_events": "false",
        "diarize": "false",
        "timestamps_granularity": "word",
    }, wav)
    request = urllib.request.Request(
        "https://api.elevenlabs.io/v1/speech-to-text",
        data=body,
        headers={"xi-api-key": api_key, "Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.loads(response.read())


def input_bases(path: Path) -> list[Path]:
    data = json.loads(path.read_text())
    rows = data.get("rows", data) if isinstance(data, dict) else data
    selected = []
    for row in rows:
        # Standing-scoreboard format: cloud-label only teacher-disagreement / hard takes.
        if "teachersAgree" in row and row["teachersAgree"]:
            continue
        selected.append(Path(row["base"]))
    return selected


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("build/cloud-labels/scribe-v2.json"))
    parser.add_argument("--max", type=int, default=25)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    allowed, excluded = [], {}
    for base in input_bases(args.input):
        eligible, reason = cloud_eligible(base)
        if eligible:
            allowed.append(base)
        else:
            excluded[reason] = excluded.get(reason, 0) + 1
    allowed = allowed[: args.max]
    print(json.dumps({"eligible": len(allowed), "excluded": excluded}, indent=2))
    if args.dry_run:
        return

    api_key = os.environ.get("ELEVENLABS_API_KEY")
    if not api_key:
        raise SystemExit("ELEVENLABS_API_KEY is required")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    results = json.loads(args.output.read_text()) if args.output.exists() else {}
    for index, base in enumerate(allowed, 1):
        key = base.name
        if key not in results:
            results[key] = transcribe(api_key, Path(f"{base}.wav"))
            args.output.write_text(json.dumps(results, indent=2))
        print(f"{index}/{len(allowed)}", flush=True)


if __name__ == "__main__":
    main()
