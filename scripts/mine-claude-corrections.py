#!/usr/bin/env python3
# Claude · 2026-08-21 · Session: 2ac29c26-0aed-4f1e-839a-ee90d216d795
"""Mine correction pairs from Michael's Claude Code inputs.

Both sides of every correction already exist on disk, captured by systems that
were built for other reasons:

  INSERTED  ~/.config/speakfree/recordings/recording-*.txt      what speakfree typed
            (+ .meta.json: targetApp bundle id, UTC date, duration)
  SENT      ~/.claude/projects/*/<session>.jsonl                what he actually sent
            (user-role messages, UTC timestamps)

For recordings whose targetApp is a Claude surface, this script finds the sent
user message that near-matches the inserted text (timestamp window + token
overlap), word-diffs inserted-vs-sent, and emits correction pairs
(original span -> corrected span) with full provenance.

Ground rules (Michael's ruling 2026-08-21):
  * A LACK of correction is NEVER approval — identical matches emit nothing.
  * An explicit correction is ALWAYS a signpost — every divergence is emitted.
  * NOTHING here auto-applies. Output is a reviewable JSONL; pairs go through
    the review-gate philosophy (the June CorrectionMonitor auto-apply produced
    the "I Will" bug). This script reads two archives and writes one file.

Output lands in build/corrections/ (gitignored — the repo is public and the
pairs quote Michael's messages; they must never be committed).

Known limitation: only Claude Code CLI sessions leave local transcripts.
Dictations sent to the Claude desktop/web app have no local SENT side and will
report "no matching message" — that is a surface gap, not a matcher failure.

Usage:
  python3 scripts/mine-claude-corrections.py                     # last 30 days
  python3 scripts/mine-claude-corrections.py --days 90
  python3 scripts/mine-claude-corrections.py --validate 2026-08-21-123806-D943539E
  python3 scripts/mine-claude-corrections.py --self-test         # no disk reads

Designed to generalize (2026-08-21 personalization direction): all paths are
parameterized, the JSONL schema is documented below, and nothing assumes
Michael-specific vocabulary. Schema per output line:

  {
    "recording_id":  "2026-08-21-123806-D943539E",
    "recording_wav": "/abs/path/recording-....wav",
    "target_app":    "com.googlecode.iterm2",
    "recording_utc": "2026-08-21T19:38:06Z",
    "duration_s":    12.4,
    "session":       "98484c82-....jsonl session id",
    "project_dir":   "-Users-...-speakfree",
    "message_uuid":  "d086058a-...",
    "message_utc":   "2026-08-21T19:39:06.425Z",
    "match_coverage": 0.83,          # fraction of inserted tokens aligned
    "corrections": [
      { "kind": "word-sub" | "case-only" | "punct-only" | "insert" | "delete",
        "original": "a Airtable builder",   # inserted span ("" for insert)
        "corrected": "a Fable builder",     # sent span ("" for delete)
        "before": "want to start",          # up to CONTEXT_TOKENS of context
        "after": "in the dev" }
    ]
  }
"""

import argparse
import datetime as dt
import difflib
import json
import os
import re
import sys
from collections import Counter

# ---------------------------------------------------------------------------
# Configuration

HOME = os.path.expanduser("~")
DEFAULT_RECORDINGS = os.path.join(HOME, ".config/speakfree/recordings")
DEFAULT_PROJECTS = os.path.join(HOME, ".claude/projects")
DEFAULT_OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                               "build", "corrections")

# Bundle ids where a dictation may be a Claude Code prompt. Terminals carry the
# CLI; VS Code carries the extension; the Anthropic ids are the desktop app
# (kept so the surface-gap report is accurate even though it has no transcript).
CLAUDE_SURFACE_IDS = {
    "com.microsoft.VSCode",
    "com.vscodium",
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "io.alacritty",
    "com.anthropic.claudefordesktop",
}
CLAUDE_SURFACE_SUBSTRINGS = ("claude", "anthropic", "cursor", "windsurf")

# Matching thresholds
MIN_INSERTED_TOKENS = 4       # too short to match reliably below this
MIN_COVERAGE = 0.5            # fraction of inserted tokens that must align
WINDOW_BEFORE_S = 60          # message may predate the recording slightly (clock skew)
WINDOW_AFTER_S = 180          # ±3 min per spec: he edits, then sends
CONTEXT_TOKENS = 5

WORD_RE = re.compile(r"[\w']+", re.UNICODE)
FILENAME_TS_RE = re.compile(r"^recording-(\d{4}-\d{2}-\d{2}-\d{6})-([0-9A-Fa-f]{8})\.meta\.json$")


# ---------------------------------------------------------------------------
# Small helpers

def parse_iso_utc(s):
    """ISO-8601 with or without fractional seconds / trailing Z -> aware UTC."""
    if not s:
        return None
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        d = dt.datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.astimezone(dt.timezone.utc)


def parse_filename_ts_local(ts):
    """'2026-08-21-123806' (local wall clock) -> aware UTC datetime."""
    try:
        naive = dt.datetime.strptime(ts, "%Y-%m-%d-%H%M%S")
    except ValueError:
        return None
    return naive.astimezone().astimezone(dt.timezone.utc)


def tokenize(text):
    """-> (raw_tokens, norm_tokens). Whitespace tokens, matched on a lowercase
    alphanumeric core so punctuation/case edits diff but don't block alignment."""
    raw = text.split()
    norm = []
    for tok in raw:
        m = WORD_RE.findall(tok)
        norm.append("".join(m).lower() if m else tok.lower())
    return raw, norm


def is_claude_surface(bundle_id):
    if not bundle_id:
        return False
    if bundle_id in CLAUDE_SURFACE_IDS:
        return True
    low = bundle_id.lower()
    return any(s in low for s in CLAUDE_SURFACE_SUBSTRINGS)


# ---------------------------------------------------------------------------
# Recordings side

def scan_recordings(recordings_dir, since_utc, until_utc, only_id=None):
    """One scandir pass; filename-timestamp prefilter BEFORE any file opens
    (never glob or stat 60k sidecars you don't need)."""
    out = []
    skipped_no_txt = 0
    app_counter = Counter()
    try:
        entries = os.scandir(recordings_dir)
    except OSError as e:
        sys.exit("cannot read recordings dir %s: %s" % (recordings_dir, e))
    with entries:
        for entry in entries:
            m = FILENAME_TS_RE.match(entry.name)
            if not m:
                continue
            rec_id = "%s-%s" % (m.group(1), m.group(2))
            if only_id and rec_id != only_id:
                continue
            ts_local = parse_filename_ts_local(m.group(1))
            if ts_local is None:
                continue
            # generous prefilter; the meta's own UTC date decides finally
            if not (since_utc - dt.timedelta(days=1) <= ts_local <= until_utc + dt.timedelta(days=1)):
                continue
            meta_path = entry.path
            try:
                with open(meta_path) as fh:
                    meta = json.load(fh)
            except (OSError, ValueError):
                continue
            app = meta.get("targetApp")
            app_counter[app or "(none)"] += 1
            if not is_claude_surface(app):
                continue
            rec_utc = parse_iso_utc(meta.get("date")) or ts_local
            if not (since_utc <= rec_utc <= until_utc):
                continue
            base = meta_path[:-len(".meta.json")]
            txt_path = base + ".txt"
            text = None
            for candidate in (txt_path, base + ".raw.txt"):
                try:
                    with open(candidate) as fh:
                        text = fh.read().strip()
                    break
                except OSError:
                    continue
            if not text:
                skipped_no_txt += 1
                continue
            out.append({
                "id": rec_id,
                "wav": base + ".wav",
                "app": app,
                "utc": rec_utc,
                "duration": float(meta.get("durationSeconds") or 0.0),
                "text": text,
            })
    out.sort(key=lambda r: r["utc"])
    return out, skipped_no_txt, app_counter


# ---------------------------------------------------------------------------
# Claude transcripts side

def extract_user_text(rec):
    """Transcript jsonl line (already parsed) -> sent text, or None."""
    if rec.get("type") != "user" or rec.get("isMeta"):
        return None
    msg = rec.get("message")
    if not isinstance(msg, dict) or msg.get("role") != "user":
        return None
    content = msg.get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts = [b.get("text", "") for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        text = " ".join(p for p in parts if p)
    else:
        return None
    text = text.strip()
    if not text or text.startswith("<command-") or "<local-command" in text:
        return None       # slash-command bookkeeping, not typed prose
    return text


def scan_transcripts(projects_dir, since_utc, until_utc):
    """All user messages in the window, across every project. Files are
    mtime-prefiltered so old sessions cost one stat each."""
    messages = []
    files_read = 0
    window_start_epoch = since_utc.timestamp()
    try:
        project_dirs = [d for d in os.scandir(projects_dir) if d.is_dir()]
    except OSError as e:
        sys.exit("cannot read Claude projects dir %s: %s" % (projects_dir, e))
    for pdir in project_dirs:
        try:
            entries = list(os.scandir(pdir.path))
        except OSError:
            continue
        for entry in entries:
            if not entry.name.endswith(".jsonl"):
                continue
            try:
                st = entry.stat()
            except OSError:
                continue
            if st.st_size == 0 or st.st_mtime < window_start_epoch:
                continue
            files_read += 1
            session = entry.name[:-len(".jsonl")]
            try:
                fh = open(entry.path, errors="replace")
            except OSError:
                continue
            with fh:
                for line in fh:
                    if '"type":"user"' not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    text = extract_user_text(rec)
                    if not text:
                        continue
                    ts = parse_iso_utc(rec.get("timestamp"))
                    if ts is None or not (since_utc <= ts <= until_utc):
                        continue
                    messages.append({
                        "text": text,
                        "utc": ts,
                        "session": session,
                        "project": pdir.name,
                        "uuid": rec.get("uuid"),
                    })
    messages.sort(key=lambda m: m["utc"])
    return messages, files_read


# ---------------------------------------------------------------------------
# Matching + diffing

def align(inserted_norm, sent_norm):
    """-> (coverage, matching_blocks) of inserted tokens inside the sent tokens."""
    sm = difflib.SequenceMatcher(None, inserted_norm, sent_norm, autojunk=False)
    blocks = [b for b in sm.get_matching_blocks() if b.size > 0]
    matched = sum(b.size for b in blocks)
    coverage = matched / len(inserted_norm) if inserted_norm else 0.0
    return coverage, sm


def classify(orig_raw, corr_raw):
    o, c = " ".join(orig_raw), " ".join(corr_raw)
    if not orig_raw:
        return "insert"
    if not corr_raw:
        return "delete"
    if o.lower() == c.lower():
        return "case-only"
    strip = lambda s: "".join(WORD_RE.findall(s)).lower()
    if strip(o) == strip(c) and strip(o):
        return "punct-only"
    return "word-sub"


def diff_pairs(ins_raw, ins_norm, sent_raw, sent_norm, sm):
    """Walk opcodes inside the aligned region; every divergence becomes a pair.
    The sent message's unmatched prefix/suffix (text he typed around the
    dictation) is NOT a correction and is excluded."""
    blocks = [b for b in sm.get_matching_blocks() if b.size > 0]
    if not blocks:
        return []
    first, last = blocks[0], blocks[-1]
    lo_a, lo_b = first.a, first.b
    hi_a, hi_b = last.a + last.size, last.b + last.size
    pairs = []
    for tag, a1, a2, b1, b2 in sm.get_opcodes():
        if tag == "equal":
            continue
        # keep only edits inside the aligned span (with the inserted side's
        # own head/tail included — dropped leading/trailing words are real)
        if a2 < lo_a and b2 <= lo_b and a1 == a2:
            continue      # pure insert before alignment = his surrounding prose
        if a1 >= hi_a and b1 >= hi_b and a1 == a2:
            continue      # pure insert after alignment = his surrounding prose
        orig = ins_raw[a1:a2]
        corr = sent_raw[b1:b2]
        pairs.append({
            "kind": classify(orig, corr),
            "original": " ".join(orig),
            "corrected": " ".join(corr),
            "before": " ".join(ins_raw[max(0, a1 - CONTEXT_TOKENS):a1]),
            "after": " ".join(ins_raw[a2:a2 + CONTEXT_TOKENS]),
        })
    return pairs


def best_match(recording, messages):
    """Best-scoring sent message within the time window, or None."""
    ins_raw, ins_norm = tokenize(recording["text"])
    if len(ins_norm) < MIN_INSERTED_TOKENS:
        return None
    lo = recording["utc"] - dt.timedelta(seconds=WINDOW_BEFORE_S)
    hi = (recording["utc"] + dt.timedelta(seconds=recording["duration"] + WINDOW_AFTER_S))
    best = None
    for msg in messages:
        if msg["utc"] < lo:
            continue
        if msg["utc"] > hi:
            break     # messages sorted by time
        sent_raw, sent_norm = tokenize(msg["text"])
        coverage, sm = align(ins_norm, sent_norm)
        if coverage < MIN_COVERAGE:
            continue
        if best is None or coverage > best["coverage"]:
            best = {"msg": msg, "coverage": coverage, "sm": sm,
                    "ins": (ins_raw, ins_norm), "sent": (sent_raw, sent_norm)}
    return best


# ---------------------------------------------------------------------------
# Self-test (positive + negative controls, zero disk reads)

def self_test():
    failures = []

    def check(name, cond):
        print("  %-42s %s" % (name, "ok" if cond else "FAIL"))
        if not cond:
            failures.append(name)

    now = dt.datetime(2026, 8, 21, 19, 38, 6, tzinfo=dt.timezone.utc)
    rec = {"id": "test", "utc": now, "duration": 10.0,
           "text": "Doesn't it mean that I want to start a Airtable builder "
                   "in the dev account and be talking to a question mark?"}
    sent_pos = {"text": "Doesn't it mean that I want to start a Fable builder "
                        "in the dev account and be talking to a ?",
                "utc": now + dt.timedelta(seconds=45),
                "session": "s", "project": "p", "uuid": "u"}
    sent_neg = {"text": "Completely unrelated message about the fleet deploy "
                        "scripts and the release checklist for tomorrow",
                "utc": now + dt.timedelta(seconds=50),
                "session": "s", "project": "p", "uuid": "u2"}
    sent_late = dict(sent_pos, utc=now + dt.timedelta(minutes=30))
    sent_exact = dict(sent_pos, text=rec["text"])

    print("self-test:")
    # positive control: the known Airtable->Fable shape is recovered
    m = best_match(rec, [sent_neg, sent_pos])
    check("matches the corrected message", m is not None and m["msg"] is sent_pos)
    if m:
        pairs = diff_pairs(m["ins"][0], m["ins"][1], m["sent"][0], m["sent"][1], m["sm"])
        subs = [p for p in pairs if p["kind"] == "word-sub"]
        check("recovers Airtable->Fable pair",
              any("Airtable" in p["original"] and "Fable" in p["corrected"] for p in subs))
    # negative control: unrelated text must not match
    check("rejects unrelated message", best_match(rec, [sent_neg]) is None)
    # window control: same text outside +-window must not match
    check("rejects out-of-window message", best_match(rec, [sent_late]) is None)
    # identical control: exact send emits zero corrections (silence != approval,
    # but identity is not a correction either)
    m = best_match(rec, [sent_exact])
    check("identical send emits no pairs",
          m is not None and not diff_pairs(m["ins"][0], m["ins"][1],
                                           m["sent"][0], m["sent"][1], m["sm"]))
    # case/punct classification
    check("classify case-only", classify(["will"], ["Will"]) == "case-only")
    check("classify punct-only", classify(["builder"], ["builder,"]) == "punct-only")
    if failures:
        sys.exit("self-test FAILED: %s" % ", ".join(failures))
    print("self-test passed.")


# ---------------------------------------------------------------------------

def main():
    global MIN_COVERAGE  # declared up-front: it is read at line ~447 (argparse default)
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--recordings-dir", default=DEFAULT_RECORDINGS)
    ap.add_argument("--projects-dir", default=DEFAULT_PROJECTS)
    ap.add_argument("--days", type=int, default=30, help="lookback window (default 30)")
    ap.add_argument("--since", help="ISO date, overrides --days")
    ap.add_argument("--until", help="ISO date (default now)")
    ap.add_argument("--out", help="output JSONL (default build/corrections/corrections-<utc>.jsonl)")
    ap.add_argument("--validate", metavar="REC_ID",
                    help="run only this recording id and print detail")
    ap.add_argument("--min-coverage", type=float, default=MIN_COVERAGE)
    ap.add_argument("--full-text", action="store_true",
                    help="embed complete inserted+sent texts in each record")
    ap.add_argument("--self-test", action="store_true",
                    help="run built-in fixtures; reads nothing from disk")
    args = ap.parse_args()

    if args.self_test:
        self_test()
        return

    MIN_COVERAGE = args.min_coverage

    until_utc = parse_iso_utc(args.until) if args.until else dt.datetime.now(dt.timezone.utc)
    since_utc = (parse_iso_utc(args.since) if args.since
                 else until_utc - dt.timedelta(days=args.days))
    if not since_utc or not until_utc:
        sys.exit("bad --since/--until")

    recordings, skipped_no_txt, app_counter = scan_recordings(
        args.recordings_dir, since_utc, until_utc, only_id=args.validate)
    claude_recs = recordings
    print("recordings in window on Claude surfaces: %d (skipped, no txt: %d)"
          % (len(claude_recs), skipped_no_txt))
    if not args.validate:
        top = ", ".join("%s×%d" % (a, n) for a, n in app_counter.most_common(8))
        print("targetApp distribution (all surfaces): %s" % top)

    messages, files_read = scan_transcripts(args.projects_dir, since_utc, until_utc)
    print("sent user messages in window: %d (from %d session files)"
          % (len(messages), files_read))

    results, unmatched, exact = [], [], 0
    for rec in claude_recs:
        m = best_match(rec, messages)
        if m is None:
            unmatched.append(rec)
            continue
        pairs = diff_pairs(m["ins"][0], m["ins"][1], m["sent"][0], m["sent"][1], m["sm"])
        if not pairs:
            exact += 1        # sent verbatim; NOT approval, just no signal
            continue
        out_rec = {
            "recording_id": rec["id"],
            "recording_wav": rec["wav"],
            "target_app": rec["app"],
            "recording_utc": rec["utc"].isoformat(),
            "duration_s": rec["duration"],
            "session": m["msg"]["session"],
            "project_dir": m["msg"]["project"],
            "message_uuid": m["msg"]["uuid"],
            "message_utc": m["msg"]["utc"].isoformat(),
            "match_coverage": round(m["coverage"], 3),
            "corrections": pairs,
        }
        if args.full_text:
            out_rec["inserted_text"] = rec["text"]
            out_rec["sent_text"] = m["msg"]["text"]
        results.append(out_rec)

    if args.validate:
        for rec in claude_recs:
            print("\nvalidate %s  app=%s  utc=%s  dur=%.1fs" %
                  (rec["id"], rec["app"], rec["utc"].isoformat(), rec["duration"]))
            print("  inserted: %r" % rec["text"][:300])
        if results:
            for r in results:
                print("  matched message %s (coverage %.2f) in %s/%s" %
                      (r["message_utc"], r["match_coverage"], r["project_dir"], r["session"]))
                for p in r["corrections"]:
                    print("    [%s] %r -> %r  (…%s _ %s…)" %
                          (p["kind"], p["original"], p["corrected"], p["before"], p["after"]))
        elif exact:
            print("  sent verbatim — no corrections (identity is not approval)")
        else:
            print("  NO matching sent message in local Claude Code transcripts.")
            print("  If this dictation went to the Claude desktop/web app, the sent side")
            print("  has no local archive — a surface gap, not a matcher failure.")
            sys.exit(1)
        return

    out_path = args.out or os.path.join(
        DEFAULT_OUT_DIR,
        "corrections-%s.jsonl" % dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S"))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as fh:
        for r in results:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.chmod(out_path, 0o600)

    n_pairs = sum(len(r["corrections"]) for r in results)
    kinds = Counter(p["kind"] for r in results for p in r["corrections"])
    print("\nmatched with corrections: %d recordings, %d pairs (%s)"
          % (len(results), n_pairs,
             ", ".join("%s×%d" % kv for kv in kinds.most_common())))
    print("matched verbatim (no signal): %d" % exact)
    print("no sent match (desktop app / non-Claude dictation / heavy rewrite): %d"
          % len(unmatched))
    print("wrote %s" % out_path)
    print("REVIEW GATE: these are candidate labels. Nothing is applied anywhere "
          "until a human (or the review pipeline) approves each pair.")


if __name__ == "__main__":
    main()
