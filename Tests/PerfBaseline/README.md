# Performance baselines

<!-- ai-suggestion:unverified | session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b | date:2026-10-01 | asof:2026-10-01 -->
> The October 1 synthetic fixture replacement keeps the four filenames and deterministic tail
> cases, but changes their audio bytes. Earlier wall-clock inference/total-latency measurements
> in `baseline.json` and `latency-ratchet.json` are **not comparable** to these new fixtures.
> No ceiling was raised or new timed baseline claimed. Review and establish a new timing identity
> on a quiet machine before drawing timing conclusions; deterministic policy checks remain valid.
> See [fixture generation and provenance](../SpeakFreeTests/AudioFixtures/README.md).
<!-- /ai -->

## `latency-ratchet.json`: key-release-to-text may only get faster

The ratchet holds ceilings for how long speakfree takes from releasing the dictation key to having
text ready, measured on the four golden fixtures in `Tests/SpeakFreeTests/AudioFixtures`. Ceilings
may be lowered and never raised. A change that makes a fixture slower than its ceiling fails.

It has two layers.

| Layer | What it measures | Tolerance | Where it blocks |
|---|---|---|---|
| Deterministic | The post-release wait the production `PostBufferPolicy` decides on each fixture's tail (90 ms, 220 ms, or the 1.2 s speech extension) | 0 | Everywhere: the unit-test suite (`PerfRatchetCLITests`) and the CI `Latency ratchet` step |
| Timed | Median simulated key-release-to-text (post-release wait + engine inference + text pipeline) and median inference, per fixture and engine | `timedTolerancePct` (15%), one automatic re-measure | Run by hand (`ratchet check`) on a machine whose fingerprint (CPU, cores, arch) has an entry, today the dev M3 Max; nothing runs it automatically yet |

Wall-clock time is not gated on CI because shared runners swing 35 to 66 percent between runs on
identical code. The post-release wait is the part that produced the 1.2 s field peak, and it is
arithmetic, so CI blocks on it with no tolerance. It is a batch model of the live poll loop: the
last 220 ms of each fixture stands in for the audio after release, and a fixture whose tail is
still speech pays the full 1.2 s extension (fixtures 1 and 2), where the live app would stop at the
first 90 ms of silence. So those two ceilings pin the extension itself; fixtures 3 and 4 pin the
cap, the silence rule and the thresholds. The Whisper timed entry runs Homebrew `whisper-cli`
as a subprocess, so a `brew upgrade` can move it with no speakfree change. CI also runs `ratchet monotonic` against the base
commit, so a pull request cannot raise or delete a ceiling.

Timed runs use an empty config directory (`.build/perf-ratchet-config`, only the Whisper model
folder linked in) so a user's vocabulary and settings cannot move the numbers.

### Check

```sh
xcrun swift build -c release --product perf-harness   # release: FluidAudio asserts in debug inference
.build/release/perf-harness ratchet check              # both layers on a gated machine
.build/release/perf-harness ratchet check --deterministic-only
```

Exit 0 is a pass, 1 is a regression, 2 is a usage or runtime error.

### Lower it (after a speed-up lands)

```sh
.build/release/perf-harness ratchet lower              # engines already gated on this machine
.build/release/perf-harness ratchet lower --engines parakeet,whisper --iterations 9
git diff Tests/PerfBaseline/latency-ratchet.json       # every changed number must go down
```

`lower` measures, then writes `min(old, measured)` for every ceiling, rounded up to a whole
millisecond. It never raises one. Run it on a quiet machine (no dictation, no builds) because a
lucky fast run becomes the new ceiling. Commit the file on its own with the before and after numbers
in the message.

To gate a new machine, run `ratchet lower` there; it adds an entry for that fingerprint. To gate a
new fixture, add it to the manifest and run `ratchet lower`; `check` fails until it has ceilings
in both layers.

### Raising a ceiling

Only on purpose, with the maintainer's OK (for example, a change that trades a little speed for fewer lost
words). Edit the number by hand and say why in the commit. The CI monotonic guard will fail that
pull request and the push that merges it (it compares against the previous commit); that red run
is the record that a human made the call.

## `baseline.json`: the older +15% comparison

Written by `perf-harness run --policy adaptive --out Tests/PerfBaseline/baseline.json` and read by
`perf-harness bench-and-gate --baseline Tests/PerfBaseline/baseline.json`. Refreshed 2026-09-24 on
the dev M3 Max (Parakeet English v2 and Whisper tiny.en, current post-release policy, empty config
directory via `SPEAKFREE_CONFIG_DIR`). It replaced a June file that assumed a flat 300 ms wait.
The ratchet above is the gate that matters; this file is kept for the existing CI perf job's
tooling. The CI perf job itself compares against `baseline-ci.json`, seeded on the runner.
