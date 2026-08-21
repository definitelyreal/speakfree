#!/usr/bin/env python3
"""Audit the vocabulary booster's substitution history for Karma-class havoc.

The 2026-08 incident: the alias kama->Karma silently rewrote ~40 spoken commas into
the name "Karma" over a week, and nothing surfaced it. This script mines the session
logs' "vocab boost applied" lines and flags the patterns that incident (and the
Cloudflare->Claude Code / instacart->Instagram rescorer misfires) would have tripped:

  1. MONOCULTURE  — one term whose hits come overwhelmingly from ONE source form.
     Genuine vocab rescue draws varied garbles; 40x the same source is a systematic
     collision (a punctuation command, a real word, another name).
  2. PUNCT-SHAPE  — source forms matching the comma/period/mark phoneme families
     (kVmV etc.) or carrying a trailing punctuation glyph ('Kama,'): the engine heard
     a spoken punctuation command, not the vocab term.
  3. REAL-WORD    — source is a dictionary word or known brand: the booster may be
     destroying legitimate content (Cloudflare, Instacart).

Usage: python3 scripts/vocab-boost-audit.py [--logs DIR] [--days N]
Reads logs only; writes nothing. Exit code 1 when any ALERT fires (cron-friendly).
"""

import argparse
import os
import re
import sys
from collections import Counter, defaultdict

PUNCT_FAMILY = re.compile(r"^[kgc][aeiou]{1,2}[lmn]{1,2}[aeiou]h?$", re.I)
KNOWN_BRANDS = {
    "cloudflare", "instacart", "instagram", "premiere", "photoshop", "airtable",
    "dropbox", "notion", "figma", "slack", "signal", "spotify", "youtube",
}


def load_dictionary():
    try:
        with open("/usr/share/dict/words") as fh:
            return {w.strip().lower() for w in fh if len(w.strip()) > 2}
    except OSError:
        return set()


def mine(logs_dir, days):
    import time
    cutoff = time.time() - days * 86400
    pair_re = re.compile(r"'([^']+)'→'([^']+)'")
    hits = defaultdict(Counter)  # term -> Counter(source)
    for name in os.listdir(logs_dir):
        if not name.endswith(".log"):
            continue
        path = os.path.join(logs_dir, name)
        if os.path.getmtime(path) < cutoff:
            continue
        with open(path, errors="ignore") as fh:
            for line in fh:
                if "vocab boost applied" not in line:
                    continue
                for src, dst in pair_re.findall(line):
                    hits[dst][src] += 1
    return hits


def audit(hits, dictionary):
    alerts, table = [], []
    for term, sources in sorted(hits.items(), key=lambda kv: -sum(kv[1].values())):
        total = sum(sources.values())
        top_src, top_n = sources.most_common(1)[0]
        bare = re.sub(r"[^A-Za-z]", "", top_src).lower()
        flags = []
        if total >= 5 and top_n / total >= 0.7 and len(sources) <= 3:
            flags.append("MONOCULTURE")
        if PUNCT_FAMILY.match(bare) or re.search(r"[,.!?;:]$", top_src):
            flags.append("PUNCT-SHAPE")
        for src in sources:
            b = re.sub(r"[^A-Za-z]", "", src).lower()
            if b in KNOWN_BRANDS or (b in dictionary and len(b) >= 5 and b != term.lower()):
                flags.append(f"REAL-WORD({src})")
                break
        table.append((term, total, f"{top_src} x{top_n}", " ".join(flags)))
        if flags and total >= 2:
            alerts.append((term, total, flags))
    return table, alerts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--logs", default=os.path.expanduser("~/.config/speakfree/logs"))
    ap.add_argument("--days", type=int, default=30)
    args = ap.parse_args()

    hits = mine(args.logs, args.days)
    if not hits:
        print("no vocab boost applications found in window")
        return 0
    table, alerts = audit(hits, load_dictionary())

    print(f"{'term':<16}{'hits':>5}  {'dominant source':<24}flags")
    for term, total, src, flags in table:
        print(f"{term:<16}{total:>5}  {src:<24}{flags}")
    if alerts:
        print("\nALERTS (term likely causing havoc — review its aliases/threshold):")
        for term, total, flags in alerts:
            print(f"  {term}: {total} hits — {' '.join(flags)}")
        return 1
    print("\nno havoc patterns detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Claude · 2026-08-20 · Session: 98484c82-8a73-497c-ab5f-fd5179093804
