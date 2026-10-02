<!-- Claude · 2026-09-20 · Session: b614566b-d45e-4a65-973e-58b0436c2c5d -->
# Component updates

An internal tool that checks speakfree's third-party components — Swift package
dependencies, the vendored whisper.cpp binaries, and the speech models the app
downloads — against what's currently available upstream, so an outdated pin doesn't
sit unnoticed for months.

## What it checks

Everything is *discovered from the repo itself* (Package.resolved, Package.swift,
`scripts/vendor/dylibs/`, and grep over `Sources/`) — nothing here is a hand-maintained
version list that can silently go stale:

| Component | Current, from | Latest, from |
|---|---|---|
| Swift packages (FluidAudio, Sparkle, anything else pinned) | `Package.resolved` | Latest GitHub release/tag of each package's repo |
| whisper.cpp (vendored dylib) | Filenames in `scripts/vendor/dylibs/` (e.g. `libwhisper.1.8.3.dylib`) | Latest `ggml-org/whisper.cpp` GitHub release |
| whisper.cpp (Homebrew formula) | n/a — informational only | `brew info --json=v2 whisper-cpp`, or the formulae.brew.sh API if brew isn't installed |
| Speech models (Parakeet, whisper.cpp GGML sizes) | Model ids referenced in `Sources/` (`parakeet-tdt-*`, `tiny.en`/`base.en`/etc) | Hugging Face model repo's `lastModified` + commit sha; flags when a sibling version (v2/v3) is referenced elsewhere in the code |
| macOS deployment target | `.macOS(.vNN)` in `Package.swift` | The macOS major Apple is currently shipping, live-checked against Apple's own software-update metadata; falls back to a hardcoded, dated table if the live check fails |
| moonshine-swift | n/a — not a dependency | Latest release, flagged `candidate, not integrated` |

The whisper.cpp row carries extra context on purpose: speakfree vendors a pinned
`libwhisper`/`libggml` pair instead of building against Homebrew because a past
brew `whisper-cpp` + `ggml` update broke ABI compatibility and crashed dictation on
first load (see `scripts/vendor/dylibs/README.md` in the app repo). The Homebrew row
here is informational context for that decision, not something to blindly chase.

## How to run it locally

```bash
python3 scripts/check-component-updates.py --repo /path/to/speakfree-release
```

Defaults to the current directory if `--repo` is omitted, so from inside a speakfree
checkout you can just run:

```bash
python3 scripts/check-component-updates.py
```

Flags:

- `--json` — machine-readable output instead of the markdown table.
- `--no-gh` — skip the `gh` CLI even if it's on `PATH` (forces unauthenticated GitHub
  REST, useful for testing rate-limit behavior).

Requires only Python 3's standard library. It shells out to `git`, `gh`, and `brew`
when they're present on `PATH` (all optional — `gh` raises the GitHub API rate limit
from 60/hr to 5000/hr; `brew` gives a more reliable Homebrew formula lookup than the
public JSON API; `git` only adds a branch/commit line to the report header). No API
keys, no third-party packages.

### Exit codes

- **0** — ran cleanly, nothing pinned is behind.
- **1** — ran cleanly, at least one *pinned* component (a `Package.resolved` entry, or
  the vendored whisper.cpp dylib) is behind upstream. Informational rows (models,
  the Homebrew reference row, the macOS target, moonshine-swift) never trigger this.
- **2** — a network/API call failed, so the report is incomplete. This takes priority
  over exit 1 — a report built on a failed fetch isn't trustworthy enough to just say
  "1." Failures are never hidden: the affected row shows `ERROR` and the actual error
  message, both in the table and on stderr.

## What a correct result looks like

Run against the release checkout on 2026-09-20 (branch `launch-fixes`, commit
`0fcc0f2`), the script found FluidAudio, Sparkle, and the vendored whisper.cpp dylib
all behind their latest upstream releases, no failed fetches, and exited 1. That's the
expected shape of a healthy run: every pinned component gets a real current-vs-latest
comparison with a working link, informational rows fill in without erroring, and the
exit code matches what the table shows. The macOS deployment target row falls back to
its static table (labeled as such, with the live-check error shown) in some sandboxed
environments where Apple's `gdmf.apple.com` endpoint fails Python's TLS chain
validation even though `curl` reaches it fine — a real, documented gap between
`curl`/SecureTransport and Python's stdlib `ssl`, not a bug in this script. That's a
correct "unknown, don't guess" result for that one row, not a failure of the run.

A run that instead prints only `?`/`unknown` across most rows, or that exits 0/1
without ever hitting the network, means the discovery step (parsing
`Package.resolved`, `Package.swift`, or `scripts/vendor/dylibs/`) found nothing —
check that `--repo` actually points at a speakfree checkout with those files present.

## How to add a component

1. Add a discovery step in `scripts/check-component-updates.py` that reads the
   component's *current* value from the repo (a file, a grep pattern, a filename
   convention) — never hardcode a version number here, only how to find one.
2. Add a lookup for its *latest* value: `latest_github_release_or_tag(owner_repo)` for
   anything on GitHub, `hf_model_info(repo_id)` for a Hugging Face model repo, or a new
   helper following the same `NotFoundError`/`NetworkError` pattern for anything else.
3. Append a `Row(...)` in `build_rows()` with `pinned=True` only if being behind should
   fail the run (exit 1) and gate CI attention — leave informational additions
   (`pinned=False`, `status="info"`) for anything that's a reference point rather than
   a real pin.
4. Run `python3 scripts/check-component-updates.py --repo /path/to/speakfree-release`
   and confirm the new row renders with a real current/latest/link, not `ERROR`.
