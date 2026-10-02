#!/usr/bin/env python3
# ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
"""Generate public synthetic speech fixtures; no recordings or network inputs."""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave

RATE = 16000
TEXTS = [
    ("fixture-1-clean.wav", "The blue balloon floats above the garden.", 0.06, "en-us", 145),
    ("fixture-2-spoken-comma.wav", "One comma two comma three.", 0.06, "en-us", 120),
    ("fixture-3-spoken-period-end.wav", "The little green robot is ready period.", 0.017, "en-us", 145),
]


def pcm(path):
    with wave.open(str(path), "rb") as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, RATE)
        values = array.array("h", wav.readframes(wav.getnframes()))
    if sys.byteorder != "little":
        values.byteswap()
    return values.tolist()


def write_pcm(path, samples):
    values = array.array("h", samples)
    if sys.byteorder != "little":
        values.byteswap()
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(values.tobytes())


def tail_rms(samples):
    tail = samples[-3520:]  # Last 220 ms, using the policy's 30 ms window alignment.
    return [math.sqrt(sum((v / 32768) ** 2 for v in tail[i:i+480]) / len(tail[i:i+480]))
            for i in range(0, len(tail), 480)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    espeak = shutil.which("espeak-ng")
    ffmpeg = shutil.which("ffmpeg")
    if not espeak or not ffmpeg:
        parser.error("espeak-ng and ffmpeg must be installed")
    version = subprocess.check_output([espeak, "--version"], text=True).split("Data at:")[0].strip()
    if "1.52.0" not in version:
        parser.error("Regeneration is pinned to eSpeak NG 1.52.0; review a version change explicitly")
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = []
    with tempfile.TemporaryDirectory(prefix="speakfree-synthetic-") as scratch:
        scratch = Path(scratch)
        for name, text, target_rms, voice, speed in TEXTS:
            native = scratch / name
            converted = scratch / ("converted-" + name)
            subprocess.run([espeak, "-v", voice, "-s", str(speed), "-p", "50", "-a", "100",
                            "-w", str(native), text], check=True)
            subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(native),
                            "-map_metadata", "-1", "-ac", "1", "-ar", str(RATE),
                            "-c:a", "pcm_s16le", str(converted)], check=True)
            samples = pcm(converted)
            # Remove the synthesizer's trailing pause, retaining 10 ms after the last
            # nontrivial sample. Whole-clip gain pins the intended policy amplitude band.
            last = max(i for i, value in enumerate(samples) if abs(value) > 32)
            samples = samples[:min(len(samples), last + 1 + RATE // 100)]
            scale = target_rms / max(tail_rms(samples))
            samples = [max(-32768, min(32767, round(v * scale))) for v in samples]
            if "period" in name:
                # A deliberately engineered soft tail exercises the base-cap band.
                # Normalize each non-silent tail window without changing sample timing.
                start = max(0, len(samples) - 3520)
                for offset, rms in zip(range(start, len(samples), 480), tail_rms(samples)):
                    if rms > 0.0001:
                        samples[offset:offset+480] = [round(v * 0.015 / rms)
                                                     for v in samples[offset:offset+480]]
            write_pcm(args.output / name, samples)
            props = [{"kind": "noCommaSpam"}]
            if "comma" in name:
                props.append({"kind": "spokenCommaConverted"})
            if "period" in name:
                props.append({"kind": "spokenPeriodAtEnd", "expectedSpokenPeriodEnd": True})
            manifest.append({"wav": name, "description": "Synthetic eSpeak NG English-US formant speech.",
                             "sourceText": text, "voice": voice, "wordsPerMinute": speed, "provenance": "ai-suggestion:unverified",
                             "modelSHA": "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
                             "tailWindowMaxRMSTarget": 0.015 if "period" in name else target_rms, "properties": props})
        period = pcm(args.output / TEXTS[2][0])
        name = "fixture-4-trailing-silence-period.wav"
        write_pcm(args.output / name, period + [0] * 6400)
        manifest.append({"wav": name, "description": "Synthetic fixture 3 plus exactly 400 ms of digital silence.",
                         "sourceText": TEXTS[2][1], "provenance": "ai-suggestion:unverified",
                         "modelSHA": manifest[2]["modelSHA"], "derivedFrom": TEXTS[2][0],
                         "appendedSilenceSamples": 6400, "properties": manifest[2]["properties"]})
        for fixture in manifest:
            wav = args.output / fixture["wav"]
            fixture["sha256"] = hashlib.sha256(wav.read_bytes()).hexdigest()
            fixture["sampleCount"] = len(pcm(wav))
        (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({f["wav"]: {"sha256": f["sha256"], "sampleCount": f["sampleCount"],
                               "tailRMS": tail_rms(pcm(args.output / f["wav"]))} for f in manifest}, indent=2))


if __name__ == "__main__":
    main()
