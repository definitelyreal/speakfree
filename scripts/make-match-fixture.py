#!/usr/bin/env python3
# ai-suggestion:unverified · session:feat-dictation-trace · 2026-09-24
"""Build a synthetic speakfree recordings archive for timing `speakfree match`.

Usage: make-match-fixture.py <config-dir> [recent_takes=5000] [old_takes=20000]

Writes <config-dir>/config.json (saving on) and <config-dir>/recordings/ with empty .wav
files plus .txt / .raw.txt / .meta.json sidecars, like the real archive. Recent takes are
spread over the last 13 days, old takes over the year before. All text is synthetic.
Also writes recordings/recent-takes.index, the names-only index the app maintains; delete
it to time the slower folder-listing fallback.
Prints one known recent take's text so a caller can query it.
"""
import datetime
import json
import os
import random
import sys
import uuid

WORDS = ("the a to and of in that it is for you we on with this be have not are but "
         "can will just so what about there if like from all they one would should could "
         "please fix build test run check file code model engine speakfree whisper parakeet "
         "claude codex prompt branch commit review draft email meeting tomorrow today week "
         "comma period question think need want make sure look again update install delete "
         "screen window menu setting option trace dot invisible match hook latency fast").split()


def sentence(rng, n):
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def main():
    root = sys.argv[1]
    recent = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    old = int(sys.argv[3]) if len(sys.argv) > 3 else 20000
    rng = random.Random(7)
    rec = os.path.join(root, "recordings")
    os.makedirs(rec, exist_ok=True)
    with open(os.path.join(root, "config.json"), "w") as f:
        json.dump({"hotkey": {"keyCode": 63, "modifiers": []}, "modelSize": "large-v3-turbo",
                   "language": "en", "saveRecordings": True}, f)
    now = datetime.datetime.now()
    known = None
    bases = []
    for i in range(recent + old):
        if i < recent:
            t = now - datetime.timedelta(seconds=rng.uniform(60, 13 * 86400))
        else:
            t = now - datetime.timedelta(days=rng.uniform(15, 380))
        base = "recording-%s-%s" % (t.strftime("%Y-%m-%d-%H%M%S"),
                                    uuid.UUID(int=rng.getrandbits(128)).hex[:8].upper())
        text = " ".join(sentence(rng, rng.randint(4, 25)) for _ in range(rng.randint(1, 3)))
        raw = text.lower().replace(".", " period")
        open(os.path.join(rec, base + ".wav"), "w").close()
        with open(os.path.join(rec, base + ".txt"), "w") as f:
            f.write(text)
        with open(os.path.join(rec, base + ".raw.txt"), "w") as f:
            f.write(raw)
        words = raw.split()
        meta = {"appVersion": "dev", "engine": "whisper", "model": "large-v3-turbo",
                "date": t.astimezone().isoformat(timespec="seconds"), "durationSeconds": 5.0,
                "transcriptChars": len(text), "targetApp": "com.anthropic.claudefordesktop",
                "transcriptionDiagnostics": {
                    "lowConfidenceTailTokensRemoved": 0, "vadTrimmedSeconds": 0,
                    "uncertain": False,
                    "lowConfidenceWords": [{"word": words[1], "score": 0.31}]}}
        with open(os.path.join(rec, base + ".meta.json"), "w") as f:
            json.dump(meta, f)
        bases.append(base)
        if i == recent // 2:
            known = text
    # The names-only index the app keeps (RecordingStore.recentIndexURL): newest 10,000.
    with open(os.path.join(rec, "recent-takes.index"), "w") as f:
        f.write("".join(b + "\n" for b in sorted(bases)[-10000:]))
    print(known)


main()
