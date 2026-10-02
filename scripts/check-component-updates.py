#!/usr/bin/env python3
# Claude · 2026-09-20 · Session: b614566b-d45e-4a65-973e-58b0436c2c5d
"""
check-component-updates.py — speakfree component-update checker.

Discovers speakfree's third-party components by reading the repo itself (no
hardcoded version list to go stale) and reports current-vs-latest for each:

  - Swift packages pinned in Package.resolved (FluidAudio, Sparkle, anything
    else pinned) vs the latest GitHub release/tag of each package repo.
  - whisper.cpp: the vendored dylibs in scripts/vendor/dylibs vs the latest
    ggml-org/whisper.cpp GitHub release, plus the Homebrew whisper.cpp
    formula version (informational — see scripts/vendor/dylibs/README.md for
    why speakfree vendors instead of building against Homebrew).
  - Speech models referenced in Sources/ (parakeet-tdt-*, whisper.cpp GGML
    sizes) vs the latest commit on their Hugging Face model repos, flagging
    sibling versions (v2 vs v3, etc).
  - The minimum macOS deployment target in Package.swift vs the macOS major
    Apple is currently shipping (live-checked against Apple's own software
    update metadata endpoint; never guessed).
  - Optional: moonshine-swift, flagged as a candidate, not integrated.

Standard library only: urllib, json, re, subprocess (for `git`/`gh` when
present). No third-party packages, no API keys. Uses `gh api` when `gh` is on
PATH (authenticated, much higher GitHub rate limit); falls back to
unauthenticated GitHub REST otherwise.

Output: a markdown table to stdout, or `--json` for machine-readable output.

Exit codes:
  0 — ran cleanly, no PINNED component is behind.
  1 — ran cleanly, at least one PINNED component (Package.resolved entries,
      the vendored whisper.cpp dylib) is behind upstream.
  2 — a network/API failure prevented checking at least one component. This
      takes priority over exit 1: a report built on a failed fetch is not
      trustworthy enough to just say "1". Errors are never hidden — failed
      rows are shown in the table/JSON with the error message.

Usage:
  python3 scripts/check-component-updates.py [--repo PATH] [--json]
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Optional

NETWORK_TIMEOUT_SECS = 12
USER_AGENT = "speakfree-component-update-checker/1.0 (+internal tool, no auth)"


# --------------------------------------------------------------------------
# Errors
# --------------------------------------------------------------------------

class NotFoundError(Exception):
    """The remote resource genuinely does not exist (HTTP 404). Distinct from
    a network failure: callers use this to fall back (e.g. releases -> tags),
    not to abort the whole run."""


class NetworkError(Exception):
    """A real failure: timeout, DNS, rate limit, 5xx, bad JSON, gh not
    runnable, etc. Any row that hits this is reported as errored, and the
    overall run exits 2."""


# --------------------------------------------------------------------------
# HTTP / API helpers
# --------------------------------------------------------------------------

def _http_get_json(url: str, headers: Optional[dict] = None):
    req = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept": "application/json", **(headers or {})}
    )
    try:
        with urllib.request.urlopen(req, timeout=NETWORK_TIMEOUT_SECS) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise NotFoundError(f"404 fetching {url}")
        if e.code in (403, 429):
            reset = e.headers.get("X-RateLimit-Reset") if e.headers else None
            hint = f" (rate-limit reset at epoch {reset})" if reset else ""
            raise NetworkError(
                f"rate limited or forbidden (HTTP {e.code}) fetching {url}{hint} — "
                f"install/auth `gh` (gh auth login) to raise the limit"
            )
        raise NetworkError(f"HTTP {e.code} fetching {url}: {e.reason}")
    except urllib.error.URLError as e:
        raise NetworkError(f"network error fetching {url}: {e.reason}")
    except TimeoutError:
        raise NetworkError(f"timeout after {NETWORK_TIMEOUT_SECS}s fetching {url}")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise NetworkError(f"bad JSON from {url}: {e}")


def _gh_on_path() -> bool:
    return shutil.which("gh") is not None


def _gh_api_json(path: str):
    try:
        out = subprocess.run(
            ["gh", "api", path],
            capture_output=True,
            text=True,
            timeout=NETWORK_TIMEOUT_SECS,
        )
    except FileNotFoundError:
        raise NetworkError("gh not found on PATH")
    except subprocess.TimeoutExpired:
        raise NetworkError(f"`gh api {path}` timed out after {NETWORK_TIMEOUT_SECS}s")
    if out.returncode != 0:
        stderr = (out.stderr or "").strip()
        if "HTTP 404" in stderr or "'Not Found'" in stderr:
            raise NotFoundError(f"gh api {path}: 404")
        if "rate limit" in stderr.lower() or "HTTP 403" in stderr:
            raise NetworkError(f"gh api {path}: rate limited/forbidden — {stderr[:200]}")
        raise NetworkError(f"gh api {path} failed: {stderr[:300] or 'no stderr'}")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError as e:
        raise NetworkError(f"gh api {path} returned bad JSON: {e}")


def github_get(path: str, use_gh: bool = True):
    """GET a GitHub REST API path. Prefers `gh api` (authenticated, 5000/hr)
    when available and asked for; falls back to unauthenticated REST
    (60/hr/IP) on any gh-level failure other than a clean 404."""
    if use_gh and _gh_on_path():
        try:
            return _gh_api_json(path)
        except NotFoundError:
            raise
        except NetworkError:
            pass  # fall through to unauthenticated REST
    return _http_get_json(f"https://api.github.com/{path}")


def latest_github_release_or_tag(owner_repo: str, use_gh: bool = True):
    """Returns (version, released_on_date_or_None, html_url) for the latest
    release; falls back to the newest tag (with best-effort commit date) if
    the repo has no releases at all."""
    try:
        rel = github_get(f"repos/{owner_repo}/releases/latest", use_gh=use_gh)
        tag = rel.get("tag_name")
        if tag:
            published = rel.get("published_at")
            date = published[:10] if published else None
            url = rel.get("html_url") or f"https://github.com/{owner_repo}/releases/tag/{tag}"
            return tag, date, url
    except NotFoundError:
        pass  # no releases published — fall back to tags below

    tags = github_get(f"repos/{owner_repo}/tags", use_gh=use_gh)
    if not tags:
        raise NotFoundError(f"{owner_repo} has no releases and no tags")
    top = tags[0]
    tag_name = top["name"]
    sha = top.get("commit", {}).get("sha")
    date = None
    if sha:
        try:
            commit = github_get(f"repos/{owner_repo}/commits/{sha}", use_gh=use_gh)
            date = (commit.get("commit", {}).get("committer", {}).get("date") or "")[:10] or None
        except (NotFoundError, NetworkError):
            date = None  # date is best-effort for the tag-fallback path
    url = f"https://github.com/{owner_repo}/releases/tag/{tag_name}"
    return tag_name, date, url


def hf_model_info(repo_id: str):
    """Returns (last_modified_date, short_sha) for a Hugging Face model repo,
    via the unauthenticated public models API."""
    data = _http_get_json(f"https://huggingface.co/api/models/{repo_id}")
    last_modified = (data.get("lastModified") or "")[:10] or None
    sha = (data.get("sha") or "")[:12] or None
    return last_modified, sha


# --------------------------------------------------------------------------
# Repo discovery — every "current" value is read from the checkout, never
# hand-maintained, so this stays correct as the repo changes.
# --------------------------------------------------------------------------

def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def parse_package_resolved(repo: str):
    """Returns a list of {identity, location, owner_repo, revision, version}
    for every pin in Package.resolved (works for v1 and v2 schema)."""
    path = os.path.join(repo, "Package.resolved")
    data = json.loads(read_text(path))
    pins = data.get("pins") or data.get("object", {}).get("pins") or []
    result = []
    for pin in pins:
        state = pin.get("state", {})
        location = pin.get("location") or pin.get("repositoryURL") or ""
        owner_repo = None
        m = re.search(r"github\.com[:/]+([^/]+/[^/]+?)(?:\.git)?/?$", location)
        if m:
            owner_repo = m.group(1)
        result.append(
            {
                "identity": pin.get("package") or pin.get("identity") or "?",
                "location": location,
                "owner_repo": owner_repo,
                "revision": state.get("revision"),
                "version": state.get("version"),
            }
        )
    return result


def parse_macos_min_target(repo: str) -> Optional[str]:
    """Extracts the macOS platform requirement from Package.swift, e.g.
    `.macOS(.v14)` -> "14", `.macOS(.v10_15)` -> "10.15"."""
    text = read_text(os.path.join(repo, "Package.swift"))
    m = re.search(r"\.macOS\(\s*\.v(\d+(?:_\d+)?)\s*\)", text)
    if not m:
        return None
    return m.group(1).replace("_", ".")


def parse_vendored_whisper_dylibs(repo: str):
    """Scans scripts/vendor/dylibs for versioned filenames like
    libwhisper.1.8.3.dylib / libggml.0.9.5.dylib. Returns
    {"whisper": "1.8.3", "ggml": "0.9.5"} for whichever are present."""
    d = os.path.join(repo, "scripts", "vendor", "dylibs")
    found = {}
    if not os.path.isdir(d):
        return found
    for name in os.listdir(d):
        m = re.match(r"^lib(whisper|ggml)(?:-[a-z]+)?\.(\d+\.\d+\.\d+)\.dylib$", name)
        if m:
            lib, ver = m.group(1), m.group(2)
            # Keep the first (they should all agree; libggml-base/-cpu/-metal/-blas share one ver)
            found.setdefault(lib, ver)
    return found


def discover_referenced_models(repo: str):
    """Greps Sources/ for model identifiers the code actually references:
    Parakeet ids, FluidInference HF repo ids, and the whisper.cpp GGML size
    vocabulary. Returns a dict with sorted lists so the report reflects
    what's really in the code, not a hand-maintained list."""
    src = os.path.join(repo, "Sources")
    parakeet_ids = set()
    fluidinference_repos = set()
    whisper_sizes = set()

    parakeet_re = re.compile(r'"(parakeet-tdt-[A-Za-z0-9._-]+)"')
    fluidinf_re = re.compile(r'"(FluidInference/[A-Za-z0-9._-]+)"')
    # whisper.cpp's own fixed GGML size vocabulary (unchanged for years upstream);
    # we search for these as *quoted string literals* so we only count real usages.
    whisper_vocab = [
        "tiny.en", "tiny", "base.en", "base", "small.en", "small",
        "medium.en", "medium", "large-v3-turbo", "large-v3", "large-v2", "large",
    ]
    whisper_size_re = re.compile(r'"(' + "|".join(re.escape(s) for s in whisper_vocab) + r')"')

    if os.path.isdir(src):
        for dirpath, _dirnames, filenames in os.walk(src):
            for fn in filenames:
                if not fn.endswith((".swift",)):
                    continue
                try:
                    text = read_text(os.path.join(dirpath, fn))
                except (UnicodeDecodeError, OSError):
                    continue
                parakeet_ids.update(parakeet_re.findall(text))
                fluidinference_repos.update(fluidinf_re.findall(text))
                whisper_sizes.update(whisper_size_re.findall(text))

    return {
        "parakeet_ids": sorted(parakeet_ids),
        "fluidinference_repos": sorted(fluidinference_repos),
        "whisper_sizes": sorted(whisper_sizes, key=lambda s: whisper_vocab.index(s)),
    }


def git_context(repo: str):
    """Best-effort `git` annotation (branch, short sha) for the report
    header. Never fatal — this is traceability, not a requirement."""
    # `.git` is a directory in a normal clone but a plain file (gitdir pointer) in a
    # worktree checkout — speakfree-release is exactly that, so check existence of
    # either, not just isdir().
    if shutil.which("git") is None or not os.path.exists(os.path.join(repo, ".git")):
        return None
    try:
        branch = subprocess.run(
            ["git", "-C", repo, "branch", "--show-current"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        sha = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        if branch or sha:
            return {"branch": branch or "?", "sha": sha or "?"}
    except (subprocess.TimeoutExpired, OSError):
        pass
    return None


# --------------------------------------------------------------------------
# macOS deployment target vs current shipping major.
#
# Apple realigned macOS version numbers to the year in 2025 (Sequoia 15 ->
# Tahoe "26"), so a naive `current_major - pinned_major` subtraction across
# that jump is misleading. This table exists only to translate a raw major
# number into "how many real generations behind" — the live check for
# "what's currently shipping" comes from Apple's own software-update
# metadata endpoint (gdmf.apple.com), not a hardcoded guess.
# --------------------------------------------------------------------------

MACOS_MAJOR_SEQUENCE = [
    # (major_version_string, marketing_name, approx_release_year)
    ("11", "Big Sur", 2020),
    ("12", "Monterey", 2021),
    ("13", "Ventura", 2022),
    ("14", "Sonoma", 2023),
    ("15", "Sequoia", 2024),
    ("26", "Tahoe", 2025),
    ("27", "Golden Gate", 2026),  # shipped 2026-09-14 per Apple Newsroom; table updated 2026-09-20
    # 27+ : shipped after this table was last hand-updated (2026-01, Claude's
    # knowledge cutoff). Marketing name intentionally left "unknown" rather
    # than guessed; the live check below still reports the numeric major.
]
MACOS_TABLE_LAST_UPDATED = "2026-01 (Claude knowledge cutoff)"


def macos_generation_index(major: str) -> Optional[int]:
    for i, (v, _name, _year) in enumerate(MACOS_MAJOR_SEQUENCE):
        if v == major:
            return i
    return None


def fetch_current_macos_major():
    """Live-checks Apple's own software-update metadata (the endpoint
    `softwareupdate`/MDM tooling reads) for the macOS major currently being
    offered as a public asset. Returns (major_str, posting_date) or raises
    NetworkError. No guessing, no hardcoded "current version" — if this
    fails, the caller reports "unknown", per the brief."""
    data = _http_get_json("https://gdmf.apple.com/v2/pmv")
    macos_entries = data.get("PublicAssetSets", {}).get("macOS", [])
    if not macos_entries:
        raise NetworkError("gdmf.apple.com returned no macOS entries")
    best_major = None
    best_date = None
    for entry in macos_entries:
        pv = entry.get("ProductVersion", "")
        major = pv.split(".")[0]
        if not major.isdigit():
            continue
        if best_major is None or int(major) > int(best_major):
            best_major = major
            best_date = entry.get("PostingDate")
    if best_major is None:
        raise NetworkError("could not parse any ProductVersion from gdmf.apple.com")
    return best_major, best_date


# --------------------------------------------------------------------------
# Version comparison
# --------------------------------------------------------------------------

def _semver_tuple(s: str):
    s = s.lstrip("vV")
    nums = re.findall(r"\d+", s.split("-")[0].split("+")[0])
    return tuple(int(n) for n in nums) if nums else None


def is_behind(current: Optional[str], latest: Optional[str]) -> Optional[bool]:
    """True/False when comparable, None when we can't tell (e.g. current is
    a raw git revision rather than a version)."""
    if not current or not latest:
        return None
    ct, lt = _semver_tuple(current), _semver_tuple(latest)
    if ct is None or lt is None:
        return None
    # Pad shorter tuple with zeros for comparison.
    n = max(len(ct), len(lt))
    ct = ct + (0,) * (n - len(ct))
    lt = lt + (0,) * (n - len(lt))
    return ct < lt


def days_between(date_str: Optional[str], today: datetime.date) -> str:
    if not date_str:
        return "unknown"
    try:
        d = datetime.date.fromisoformat(date_str[:10])
    except ValueError:
        return "unknown"
    return str((today - d).days)


# --------------------------------------------------------------------------
# Row model + report assembly
# --------------------------------------------------------------------------

@dataclass
class Row:
    component: str
    current: str
    latest: str
    released_on: str
    days_behind: str
    link: str
    notes: str = ""
    pinned: bool = False       # counts toward the exit-1 gate when behind
    status: str = "ok"         # ok | behind | error | info


def build_rows(repo: str, use_gh: bool, today: datetime.date):
    rows: list[Row] = []
    had_network_error = False

    # --- Swift packages from Package.resolved ---
    try:
        pins = parse_package_resolved(repo)
    except (OSError, json.JSONDecodeError) as e:
        rows.append(Row("Package.resolved", "?", "?", "?", "?", "", f"ERROR reading Package.resolved: {e}",
                         pinned=True, status="error"))
        had_network_error = True
        pins = []

    for pin in pins:
        identity = pin["identity"]
        current = pin["version"] or (pin["revision"][:12] if pin["revision"] else "?")
        if not pin["owner_repo"]:
            rows.append(Row(f"{identity} (Swift package)", current, "?", "?", "?", pin["location"],
                             "non-GitHub location; skipped latest-release lookup", pinned=True, status="info"))
            continue
        try:
            latest, released_on, url = latest_github_release_or_tag(pin["owner_repo"], use_gh=use_gh)
        except NotFoundError as e:
            rows.append(Row(f"{identity} (Swift package)", current, "not found", "unknown", "unknown",
                             f"https://github.com/{pin['owner_repo']}", str(e), pinned=True, status="error"))
            continue
        except NetworkError as e:
            rows.append(Row(f"{identity} (Swift package)", current, "ERROR", "unknown", "unknown",
                             f"https://github.com/{pin['owner_repo']}", str(e), pinned=True, status="error"))
            had_network_error = True
            continue
        behind = is_behind(current, latest)
        status = "behind" if behind else "ok"
        rows.append(Row(
            f"{identity} (Swift package)", current, latest, released_on or "unknown",
            days_between(released_on, today), url,
            "pinned via Package.resolved" + ("" if behind is not None else " — could not compare versions numerically"),
            pinned=True, status=status,
        ))

    # --- whisper.cpp vendored dylib vs latest GitHub release ---
    vendored = parse_vendored_whisper_dylibs(repo)
    whisper_current = vendored.get("whisper")
    ggml_current = vendored.get("ggml")
    if whisper_current:
        try:
            latest, released_on, url = latest_github_release_or_tag("ggml-org/whisper.cpp", use_gh=use_gh)
            behind = is_behind(whisper_current, latest)
            status = "behind" if behind else "ok"
            note = f"vendored dylib in scripts/vendor/dylibs, pinned intentionally (ABI compat, see README)"
            if ggml_current:
                note += f"; paired with vendored libggml {ggml_current}"
            rows.append(Row(
                "whisper.cpp (vendored dylib)", whisper_current, latest, released_on or "unknown",
                days_between(released_on, today), url, note, pinned=True, status=status,
            ))
        except NotFoundError as e:
            rows.append(Row("whisper.cpp (vendored dylib)", whisper_current, "not found", "unknown", "unknown",
                             "https://github.com/ggml-org/whisper.cpp", str(e), pinned=True, status="error"))
        except NetworkError as e:
            rows.append(Row("whisper.cpp (vendored dylib)", whisper_current, "ERROR", "unknown", "unknown",
                             "https://github.com/ggml-org/whisper.cpp", str(e), pinned=True, status="error"))
            had_network_error = True
    else:
        rows.append(Row("whisper.cpp (vendored dylib)", "not found", "?", "?", "?", "",
                         "no libwhisper.*.dylib found under scripts/vendor/dylibs", pinned=False, status="info"))

    # --- Homebrew whisper.cpp formula (informational; the vendor README explains why
    #     speakfree does NOT build against whatever brew currently has) ---
    try:
        brew_version, brew_source = fetch_homebrew_formula_version(["whisper.cpp", "whisper-cpp"])
        rows.append(Row(
            "whisper.cpp (Homebrew formula, informational)", "n/a", brew_version, "unknown", "n/a",
            "https://formulae.brew.sh/formula/whisper.cpp",
            f"NOT what speakfree links against (source: {brew_source}); "
            f"vendoring exists because a past brew whisper-cpp/ggml pair broke ABI compat at model load — "
            f"see scripts/vendor/dylibs/README.md before bumping off this",
            pinned=False, status="info",
        ))
    except NetworkError as e:
        rows.append(Row("whisper.cpp (Homebrew formula, informational)", "n/a", "ERROR", "unknown", "n/a",
                         "https://formulae.brew.sh/formula/whisper.cpp", str(e), pinned=False, status="error"))
        had_network_error = True

    # --- Speech models referenced in Sources/ ---
    referenced = discover_referenced_models(repo)
    for model_id in referenced["parakeet_ids"]:
        hf_repo = f"FluidInference/{model_id}-coreml"
        try:
            last_modified, sha = hf_model_info(hf_repo)
        except NotFoundError:
            rows.append(Row(f"Speech model: {model_id}", model_id, "HF repo not found", "unknown", "n/a",
                             f"https://huggingface.co/{hf_repo}", "expected FluidInference/<id>-coreml naming",
                             pinned=False, status="error"))
            continue
        except NetworkError as e:
            rows.append(Row(f"Speech model: {model_id}", model_id, "ERROR", "unknown", "n/a",
                             f"https://huggingface.co/{hf_repo}", str(e), pinned=False, status="error"))
            had_network_error = True
            continue
        # Sibling note: which OTHER Parakeet id(s) the repo actually references (e.g. v3 when
        # reporting v2), so the reader can see a newer/alternate sibling exists without us
        # guessing at a "latest version number" that doesn't really apply to named model repos.
        other_ids = [i for i in referenced["parakeet_ids"] if i != model_id]
        sibling_note = f"other Parakeet id(s) referenced in code: {', '.join(other_ids)}" if other_ids else "no sibling version referenced in code"
        rows.append(Row(
            f"Speech model: {model_id}", model_id, f"HF repo updated {last_modified or 'unknown'}"
            + (f" (sha {sha})" if sha else ""),
            last_modified or "unknown", days_between(last_modified, today),
            f"https://huggingface.co/{hf_repo}",
            sibling_note + "; model id is unpinned in code (no stored commit sha), so 'behind' is not evaluated",
            pinned=False, status="info",
        ))

    if referenced["whisper_sizes"]:
        try:
            last_modified, sha = hf_model_info("ggerganov/whisper.cpp")
            rows.append(Row(
                "Speech models: whisper.cpp GGML sizes", ", ".join(referenced["whisper_sizes"]),
                f"HF repo updated {last_modified or 'unknown'}" + (f" (sha {sha})" if sha else ""),
                last_modified or "unknown", days_between(last_modified, today),
                "https://huggingface.co/ggerganov/whisper.cpp",
                "single HF repo hosts all ggml-*.bin sizes; default CLI download size is base.en (Sources/SpeakFree/main.swift)",
                pinned=False, status="info",
            ))
        except NotFoundError as e:
            rows.append(Row("Speech models: whisper.cpp GGML sizes", ", ".join(referenced["whisper_sizes"]),
                             "HF repo not found", "unknown", "n/a",
                             "https://huggingface.co/ggerganov/whisper.cpp", str(e), pinned=False, status="error"))
        except NetworkError as e:
            rows.append(Row("Speech models: whisper.cpp GGML sizes", ", ".join(referenced["whisper_sizes"]),
                             "ERROR", "unknown", "n/a",
                             "https://huggingface.co/ggerganov/whisper.cpp", str(e), pinned=False, status="error"))
            had_network_error = True

    # --- macOS deployment target vs current shipping major ---
    #
    # The brief explicitly allows two strategies here: a live fetch of Apple's release
    # notes/metadata, OR a hardcoded lookup table with a last-updated date — and says to
    # print "unknown" rather than guess if unsure. In practice the live endpoint
    # (gdmf.apple.com, the same metadata `softwareupdate`/MDM tooling reads) fails TLS
    # verification under Python's stdlib `ssl` in some environments even though `curl`
    # reaches it fine (a documented curl-vs-OpenSSL certificate-chain-building gap, not a
    # sign the data is wrong) — so a live-check failure here falls back to the static
    # table rather than erroring the whole run, exactly as the brief anticipates. This is
    # the only component whose live-check failure does NOT flip the run to exit code 2.
    target = parse_macos_min_target(repo)
    if target:
        target_major = target.split(".")[0]
        target_name = next((n for v, n, _y in MACOS_MAJOR_SEQUENCE if v == target_major), "unknown name")
        live_error = None
        current_major = posting_date = None
        source_note = ""
        try:
            current_major, posting_date = fetch_current_macos_major()
            source_note = "live via Apple software-update metadata (gdmf.apple.com)"
        except NetworkError as e:
            live_error = str(e)

        if current_major is None:
            # Static fallback: the newest entry in our hand-maintained table.
            current_major, _name, _year = MACOS_MAJOR_SEQUENCE[-1]
            posting_date = None
            source_note = (
                f"STATIC TABLE fallback (last updated {MACOS_TABLE_LAST_UPDATED}) — "
                f"live check failed: {live_error}. Actual current major may be newer; "
                f"verify at https://support.apple.com/en-us/109033 if this matters right now."
            )

        idx_target = macos_generation_index(target_major)
        idx_current = macos_generation_index(current_major)
        if idx_target is not None and idx_current is not None:
            gens_behind = idx_current - idx_target
            gens_note = f"{gens_behind} major macOS generation(s) behind current"
        elif idx_target is not None and idx_current is None:
            gens_note = (
                f"current major {current_major} is newer than this script's name table "
                f"(last updated {MACOS_TABLE_LAST_UPDATED}) — generation count unknown, not guessed"
            )
        else:
            gens_note = "target major not in this script's name table — generation count unknown, not guessed"
        current_name = next((n for v, n, _y in MACOS_MAJOR_SEQUENCE if v == current_major), "unknown name (post-cutoff release)")
        rows.append(Row(
            "macOS deployment target (Package.swift)",
            f"{target} ({target_name})",
            f"{current_major} ({current_name})",
            posting_date or "unknown", "n/a", "https://gdmf.apple.com/v2/pmv",
            f"{source_note}. {gens_note}. Apple realigned major numbers to the year in 2025 "
            "(Sequoia 15 -> Tahoe 26), so raw major-number subtraction across that jump is "
            "misleading — use the generation count instead.",
            pinned=False, status="info",
        ))
    else:
        rows.append(Row("macOS deployment target (Package.swift)", "not found", "unknown", "unknown", "unknown", "",
                         "could not parse `.macOS(.vNN)` from Package.swift", pinned=False, status="info"))

    # --- Optional: moonshine-swift candidate ---
    try:
        latest, released_on, url = latest_github_release_or_tag("moonshine-ai/moonshine-swift", use_gh=use_gh)
        rows.append(Row(
            "moonshine-swift (candidate, not integrated)", "not integrated", latest, released_on or "unknown",
            days_between(released_on, today), url,
            "not a speakfree dependency today; tracked here only as a future-engine candidate",
            pinned=False, status="info",
        ))
    except NotFoundError as e:
        rows.append(Row("moonshine-swift (candidate, not integrated)", "not integrated", "not found", "unknown",
                         "unknown", "https://github.com/moonshine-ai/moonshine-swift", str(e), pinned=False, status="info"))
    except NetworkError as e:
        rows.append(Row("moonshine-swift (candidate, not integrated)", "not integrated", "ERROR", "unknown",
                         "unknown", "https://github.com/moonshine-ai/moonshine-swift", str(e), pinned=False, status="error"))
        had_network_error = True

    return rows, had_network_error


def fetch_homebrew_formula_version(candidate_names: list[str]):
    """Prefers the local `brew` CLI (resolves renamed/old formula names, e.g.
    the historical "whisper-cpp" -> current "whisper.cpp"). Falls back to the
    formulae.brew.sh JSON API (needs the CURRENT formula name; old names
    404 there, so candidate_names should list current-name-first)."""
    if shutil.which("brew"):
        for name in candidate_names:
            try:
                out = subprocess.run(
                    ["brew", "info", "--json=v2", name],
                    capture_output=True, text=True, timeout=NETWORK_TIMEOUT_SECS,
                )
            except subprocess.TimeoutExpired:
                continue
            if out.returncode == 0:
                try:
                    data = json.loads(out.stdout)
                    formulae = data.get("formulae") or []
                    if formulae:
                        return formulae[0]["versions"]["stable"], "brew info --json=v2"
                except (json.JSONDecodeError, KeyError, IndexError):
                    pass
    # Fallback: formulae.brew.sh JSON API (unauthenticated, no key needed).
    last_err = None
    for name in candidate_names:
        try:
            data = _http_get_json(f"https://formulae.brew.sh/api/formula/{name}.json")
            return data["versions"]["stable"], "formulae.brew.sh API"
        except NotFoundError as e:
            last_err = e
            continue
        except NetworkError as e:
            last_err = e
            continue
    raise NetworkError(f"could not resolve Homebrew formula for any of {candidate_names}: {last_err}")


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def render_markdown(rows: list[Row], repo: str, git_info, today: datetime.date) -> str:
    lines = []
    lines.append(f"# speakfree component updates — {today.isoformat()}")
    lines.append("")
    lines.append(f"Repo: `{repo}`" + (f" (branch `{git_info['branch']}` @ `{git_info['sha']}`)" if git_info else ""))
    lines.append("")
    lines.append("| Component | Current | Latest | Released on | Days behind | Link | Notes |")
    lines.append("|---|---|---|---|---|---|---|")
    for r in rows:
        marker = {"behind": "⚠️ ", "error": "❌ ", "ok": "", "info": ""}[r.status]
        link_md = f"[link]({r.link})" if r.link else ""
        notes = r.notes.replace("|", "\\|")
        lines.append(
            f"| {marker}{r.component} | {r.current} | {r.latest} | {r.released_on} | {r.days_behind} | {link_md} | {notes} |"
        )
    lines.append("")
    n_behind = sum(1 for r in rows if r.pinned and r.status == "behind")
    n_error = sum(1 for r in rows if r.status == "error")
    lines.append(f"**{n_behind} pinned component(s) behind. {n_error} row(s) errored.**")
    return "\n".join(lines)


def render_json(rows: list[Row], repo: str, git_info, today: datetime.date) -> str:
    payload = {
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "repo": repo,
        "git": git_info,
        "components": [r.__dict__ for r in rows],
        "summary": {
            "pinned_behind": sum(1 for r in rows if r.pinned and r.status == "behind"),
            "errors": sum(1 for r in rows if r.status == "error"),
        },
    }
    return json.dumps(payload, indent=2)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Check speakfree's third-party components for updates.")
    parser.add_argument("--repo", default=".", help="Path to the speakfree checkout (default: current directory)")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a markdown table")
    parser.add_argument("--no-gh", action="store_true", help="Skip `gh api` even if gh is on PATH (unauthenticated REST only)")
    args = parser.parse_args(argv)

    repo = os.path.abspath(args.repo)
    if not os.path.isfile(os.path.join(repo, "Package.swift")):
        print(f"error: {repo} does not look like a Swift package checkout (no Package.swift)", file=sys.stderr)
        return 2

    today = datetime.datetime.now(datetime.timezone.utc).date()
    use_gh = not args.no_gh
    git_info = git_context(repo)

    rows, had_network_error = build_rows(repo, use_gh=use_gh, today=today)

    if args.json:
        print(render_json(rows, repo, git_info, today))
    else:
        print(render_markdown(rows, repo, git_info, today))

    if had_network_error:
        print("\nnetwork/API failure on one or more components — see rows above marked ERROR; "
              "exit code 2 (results are incomplete, not to be treated as a clean report)", file=sys.stderr)
        return 2

    if any(r.pinned and r.status == "behind" for r in rows):
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
