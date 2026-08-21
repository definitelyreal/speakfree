#!/usr/bin/env python3
"""Regenerate ~/.config/speakfree/established-words.txt from the recordings corpus.

Words the user has dictated >= THRESHOLD times in FINAL transcripts that the system
dictionary does not know. The vocabulary booster's real-word guard treats them as
real words: never overwritten on acoustic evidence alone (curated aliases still win).
The threshold is 3 (not higher): the 2026-08 damage victims were rare brand names
(cloudflare x3, partiful x4); a first-time word is unprotectable by frequency and is
covered by the proper-noun-shape guard in VocabularyBoost instead.
"""
import collections
import os
import re

THRESHOLD = 3
rec = os.path.expanduser("~/.config/speakfree/recordings")
counts = collections.Counter()
scanned = 0
with os.scandir(rec) as it:
    for e in it:
        if not e.name.endswith(".txt") or e.name.endswith(
            (".raw.txt", ".whisper.txt", ".parakeet.txt", ".bt.raw.txt")
        ):
            continue
        scanned += 1
        try:
            text = open(e.path, errors="ignore").read()
        except OSError:
            continue
        for tok in re.findall(r"[A-Za-z][A-Za-z']{3,}", text):
            counts[tok.lower()] += 1
try:
    dictionary = {w.strip().lower() for w in open("/usr/share/dict/words")}
except OSError:
    dictionary = set()
# Never establish a known MISHEAR: curated aliases are by definition wrong surface
# forms (Codex review 2026-08-21 — establishing "rorlik" would permanently block the
# rorlik->Rohrlich rescue it exists to enable).
aliases = set()
import json
cv = os.path.expanduser("~/.config/speakfree/custom-vocabulary.json")
try:
    for t in json.load(open(cv)).get("terms", []):
        for a in t.get("aliases") or []:
            aliases.add(re.sub(r"[^a-z']", "", a.lower()))
except (OSError, ValueError):
    pass
est = sorted(w for w, c in counts.items()
             if c >= THRESHOLD and w not in dictionary and w not in aliases)
out = os.path.expanduser("~/.config/speakfree/established-words.txt")
with open(out, "w") as fh:
    fh.write("# Established personal vocabulary — auto-generated, do not hand-edit.\n")
    fh.write(f"# Words dictated >={THRESHOLD}x in {scanned} final transcripts, absent from\n")
    fh.write("# the system dictionary. The booster's real-word guard protects these.\n")
    fh.write("# Regenerate: python3 scripts/build-established-words.py\n")
    fh.write("\n".join(est) + "\n")
print(f"{len(est)} established words -> {out} (from {scanned} finals)")
