<!-- ai-processed:unverified | session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 | date:2026-09-13 | asof:2026-09-14 -->
# Existing-code release: start here

Current runtime checkpoint, September 14: **release-test `c90b1bc` is installed and
running on Noah and Ark**. Noah PID 23308 logged hotkey readiness, permissions/controls OK,
and successful Parakeet warm-up. Ark's guarded installer returned `remote RUNNING`, then
an independent process/plist check found PID 48881 and `SFBuildCommit=c90b1bc`; its
signature passed and executable SHA256 matches Noah and the staged candidate. Studio's
transfer failed before verification via SFTP, legacy SCP, EC2 relay and bounded small
chunks. No Studio stop/install was attempted; retry after connectivity recovers. Do not
describe the fleet as fully updated.
The signed vendored package and partial-fleet receipt are retained privately under
`build/release-readiness/c90b1bc/` and the receipt's temporary staging path. Studio's failed
transport did not hold Noah closed: Noah was already stopped, so no stop warning was
needed there. All remote stops still require the staged quiet/warning guard.

The candidate includes `02150d2` recording-group leases and atomic Trash claims. Active
and newly created takes, pending finalizations, readers, recovery and shadow work retain
their whole artifact group while background Trash proceeds. New Fn recordings and final
metadata publication remain available while filesystem Trash blocks. Final combined
qualification passed **189 tests**, zero failures, process exit 0; all 19 inert deployment
tests passed. Changed guard sources pass strict SwiftLint. Private log:
`build/release-readiness/2026-09-13-final-qualified-tests.log`.

Michael confirmed the fresh backup in Finder. The real candidate Trash/speed test is still
pending. CUA times out attaching to the menu-bar app, so Michael has been asked to open
Settings and its `→ 🗑️` confirmation manually; do not substitute an inert preview or claim
the real dialog is open. Refresh backup coverage for any new dictations before the final
interactive Trash action. Existing full archive and restoration helper remain intact. A completed 80.61-second
Noah take after reopening has four files protected by the full-extraction/hash/mode-checked
`2026-09-14T000656-post-relaunch-supplement` (2,581,216 content bytes). This proves a
capture completed, not transcript accuracy or absence of all audio gaps. The durable
`CURRENT-RECOVERY-INDEX.json` links the supplement; inspect for further arrivals before Trash.

The compatible update guard recognizes exact source-known legacy menu/config/health
formats; 24 focused tests and plain native observation probes passed. Ark completed its
live guard, which checks visible panel state and successful tone initiation before returning
ready. Physical audibility was not independently observed. Unknown activity remains
fail-closed. Research carries the exact compatible guard through `0b22230`.

Historical staging: `913874a` fixed startup state and bounded SSH transport. The older
`31851cc` package passed local signature/CLI checks, but its Studio transfer stalled and
was canceled without touching SpeakFree. Its receipt remains ineligible for installation.

September 13 evening: Michael authorized installing the updated release-test build on the
fleet after a fresh full backup and Finder confirmation, then reopening the recordings
confirmation for a live Trash/speed test. He chose **Trash only**, removing permanent
deletion from the user-facing flow, with `→ 🗑️`, progress and measured completion time.
This replaces the earlier install-approval-pending state, but not public-release approval.
Longer experiments and incomplete fixes remain in research; see sibling research
`docs/BUILD-PLAN.ai.md`. The old Noah process exited gracefully before the fresh backup.
Trash backend/UI is committed at `f0c80a9`. The final focused suite passed 116 tests
with zero failures and exit 0; the optimized build passed in 33.01 seconds. Changed Trash
source/UI/tests pass strict SwiftLint; this does not clear the pre-existing repository findings.
Logs: `build/release-readiness/2026-09-13-trash-final-{tests,build}.log`.
The fresh full snapshot `2026-09-13T211114` contains 74,321 files / 6,950,207,201 content
bytes, including 18,768 WAV files and all 58 annotations. Full separate extraction matched
hashes, sizes and modes; source stability passed. Archive SHA256:
`0bb8d3c1b8fc180fed939ae82a28663f4be5023056ede9d544ccfcb4e0c9354b`.
Originals and this backup were opened side by side in Finder; Michael confirmed he sees the backup.
At that snapshot the old Noah app was stopped; the current installation state is above. Fresh installed-app rollback
archives also exist on every host under `~/Library/Application Support/speakfree/AppBackups/2026-09-13-before-trash-update/`;
each archived executable matched its installed executable before replacement. Inert preview processes were closed
after Michael opened their test-folder link; the preview now has an explicit UI TEST banner.

Michael additionally requires a tone and visible warning before future agent-driven stops,
no active dictation, and 30 seconds since the last dictation. Release `prepare-update` and guarded fleet installation are implemented. The final
combined suite passed 129 tests (13 new update-policy/observer regressions); all 17 inert
deployment tests passed. Changed helper/UI sources and tests pass strict SwiftLint.
The worker caches directory membership, stats at most 256 recent artifacts per scan,
parses only new log events, and rejects stale observations. Cancel remains on main.
The native tone/window still needs observation during the actual guarded update. Build/vendor/transfer before interruption; never
force-kill to finish deployment. Old-app external observation has an unavoidable race with
a new Fn press after the final check; do not claim app-coordinated atomic admission.


Earlier hardware-test candidate, September 13: `66a0e6d` includes the existing deletion
and route-recovery fixes plus the selective capture/lifecycle fixes below. Optimized build
and 153 focused tests passed. The signed vendored bundle passes signature and CLI loading
on Noah, Studio, and Ark; remote archive/executable hashes match the local candidate.
It is staged only, not installed. Receipt: `build/release-readiness/66a0e6d/candidate-receipt.json`.
Later September 13 playback evidence adds a capture gate: CoreAudio at 20:08:50.572
attributes an AirPods HFP input start/output reconfiguration to installed SpeakFree PID 30910
despite its built-in pin. The recovery candidate does not yet establish input isolation.
Read research `docs/accuracy/STATUS.ai.md` and private corpus `analyses/2026-09-13-playback/`.
Public release still requires live deletion/capture checks, the AppKit quit-flow decision,
and existing lint cleanup. The September 9 candidate evidence below remains historical.

September 9 follow-up: [ROUTE-STABILITY.ai.md](ROUTE-STABILITY.ai.md) records the live
Noah/Studio handoffs, removed stale diagnostic poller, and stopped-engine recovery candidate.
Route stability is now a release gate; deletion correctness alone is insufficient.

September 9 afternoon candidate checkpoint: `a795f6b` is packaged, signature-checked,
and its CLI loads on Noah, Studio, and Ark. Each Mac has a rollback archive of installed
`3143a81`. No candidate is installed yet; the current task has requested the final fleet
rollout approval. Private source/binary/archive hashes and UI observations are in
`build/release-readiness/a795f6b/candidate-receipt.json`.

The previously blocked deletion UI check now passes on isolated inert previews of the
candidate's executable payload: cancel; simulated failure alert; acknowledgement returning
to the confirmation; retry; cancel after failure retaining “Keep my recordings”; and
simulated success returning with “Continue”. Previews used a scratch recording-count fixture;
the fixture remained intact. Separate bundle identifiers/signatures change signed bytes, but
unsigned executable payload hashes match the candidate. This checks UI behavior; actual
filesystem success/failure/retry remains covered by the earlier real-fixture unit tests.
Hardware capture/route smoke testing and release CI are still open.

September 13 capture follow-up: the proven partial-tail silence veto (`5fe97ef` research)
and post-buffer/quick-repress preservation (`d5ff19c` research) have been selectively
applied here, together with synthetic regression tests and corrected routing comments.
No vocabulary research, new recognizer, or iOS diagnostic changes were merged.
The earlier `a795f6b` bundle does not contain these changes and is not the new candidate.
Partial-tail tests passed 55/55. The combined capture/deletion suite reported 150 passing
assertions, then its xctest process crashed with SIGSEGV during CoreML CTC compilation
while the main thread was exiting. An identical repeat exited successfully, so do not
erase the intermittent failure or call the initial run green. The real-model test awaits
unload, but that engine did not drain its background auxiliary setup tasks. The selective
`f6cb042` research port now serializes lifecycle operations and cancels AND awaits both
auxiliary tasks before cleanup, with generation guards for stale publication. The final
combined suite passed 153 tests with zero failures and process exit 0; its log is
`build/release-readiness/2026-09-13-capture-deletion-lifecycle-final.log`. Research also
preserves a real cached-CTC integration that waited for a 14.5-second native setup, plus
deterministic regressions that fail if the completion waits are removed. Test configurations
are isolated from Michael's vocabulary and skip missing cached model assets.
The optimized release build passed (`swift build -c release -j 2`, 35.36 seconds).
The build still reports the existing Homebrew whisper dylib's newer macOS deployment
target; the fleet bundle must use the vendored dylibs and be checked on each host.
Logs: `build/release-readiness/2026-09-13-{capture-deletion-tests,capture-deletion-repeat}.log`;
crash receipt is also preserved in the research corpus `analyses/2026-09-13-capture/`.
The separate `unloadModelSync()` bridge still returns after two seconds during AppKit
termination. Even after the awaited engine lifecycle fix, actual app exit is not guaranteed
to drain a longer native compile. A responsive asynchronous quit flow remains a separate
gate; do not claim the test-process fix proves all daily-app shutdown crashes resolved.

Additional local release checks: all version surfaces agree at 1.7.1. `swiftlint --strict`
with 0.63.2 reports 28 violations, including vendored iOS code and unchanged existing source;
none are in the capture/deletion files changed in this lane. Do not report release CI as
green. Private `a795f6b/{swiftlint.log,lint-findings.json,version-check.log}` retains details
and per-file comparison to the lane's `1d86b3a` base. The September 13 rerun has the same
28 file/line/message findings, with no additions. Resolve applicable lint failures before
public release; this does not establish a runtime fault in the prepared hardware-test build.

Michael's September 9 direction: release the existing app once the relevant flow is
working, while pursuing accuracy/engine development independently. On September 13 he
explicitly requested an interactive deletion test after backing up the transcripts.
That resolves the earlier wording ambiguity; it does not authorize public publication.

September 13 live check: installed Noah build remains `3143a81`. Before touching real
recordings, a private archive outside the deletion target captured all recordings,
persistent corpus and relevant vocabulary/config files: 73,933 files / 6,750,864,286
content bytes. A full separate extraction matched every content hash, size and mode.
An initial tar extraction narrowed permissions under umask 077; re-extraction with
preserved permissions passed the complete check. A missing-only restore helper also
passed no-overwrite and mode-preservation checks; it is saved beside the backup.
The private pointer is in the research checkout's
`build/2026-09-13-checks/backup-location.json`. Do not depend on disposable build storage:
the backup itself is under `~/Library/Application Support/speakfree/DeletionBackups/`.

Michael confirmed Cancel returned normally, then clicked Delete and reported an apparent
freeze. By 20:44 the installed `3143a81` had removed all 73,855 original top-level targets;
91 nested `orphaned/` files survived as specified. A subsequent process sample showed
normal event handling. Its synchronous main-thread delete explains the temporary UI
stall; this candidate already dispatches deletion off-main and surfaces pending/errors.
This is a live test of the old build, not qualification of this uninstalled candidate.

Recovery restored 73,855 base files and 12 additional post-snapshot files without overwrites
or conflicts. The latter had copies in the extracted backup but no original manifest entry;
they now have a separate verified supplement. Eight newer survivors were also backed up.
Base snapshot: `2026-09-13T202403/`; surviving-file supplement:
`2026-09-13T204454-supplement/`; recovered-copy supplement:
`2026-09-13T204806-recovered-supplement/`, all under
`~/Library/Application Support/speakfree/DeletionBackups/`. Keep all three manifests.
The original corpus/config snapshot at `2026-09-13T185739/` remains intact. Full restore
receipts and the process sample persist in research corpus `analyses/2026-09-13-deletion/`.
Michael confirmed Settings responds, chose Trash only, and requested a second interactive
Trash/speed test after the fresh backup and updated install described above. The old process's
cached count may need a same-build relaunch after external restoration. Future interactive
delete drills must secure newly arriving takes before leaving a destructive step pending.

## Boundaries

- This checkout: `codex/release-readiness`, forked from `1d86b3a`.
- Research checkout: sibling `../speakfree`, branch `codex/accuracy-research`.
- Installed fleet build observed September 9: `3143a81`; Noah rechecked September 13.
  Public release last checked via GitHub September 9: `v1.7.1`.
- No open PR existed at review. Current local/fleet test installation is recorded above; no public build has been published in this lane.
- Do not merge the experimental branch wholesale. Its corpus, diagnostics, and model work
  must not hold up the existing-code release. Port individual approved fixes deliberately.

## Deletion findings and fixes under validation

The prior deletion API discarded its result; the confirmation sheet always dismissed and
acknowledged success. Directory enumeration errors were swallowed and could reset the cached
count to zero. These are source-inspection findings, independently reproduced by scratch tests.

The candidate returns removed/failed counts and enumeration failure, invalidates counts on
failure, and treats an absent directory as already empty. The UI performs the operation off
the main thread, prevents repeated clicks, and keeps the sheet open with a retryable error
when removal fails. Original artifact allow-list, non-recursion, and mutation lock remain.

Validation September 9:

- Before changes: 47 targeted storage/notice/post-buffer tests passed.
- After changes: 49 storage/notice/performance/privacy tests passed, including new real
  filesystem fixtures for unreadable enumeration, denied removal, successful retry, and absence.
- Final combined regression: 144 tests passed across audio routing/resampling/resilience,
  capture timelines/coordinator, configuration notifications, post-buffer, storage, notices,
  performance and privacy. Log: `build/release-readiness/final-regression-tests.log`.
- Commands: `swift test --filter 'RecordingStoreTests|RecordingsNoticeTests|PerfBatchMTests|AdversarialR2PrivacyTests'`.
- Logs initially `/tmp/speakfree-release-{readiness,deletion}-tests.log`; retain in private
  `build/release-readiness/` before delivery.
- UI success/cancel/failure behavior in an isolated scratch config completed at the afternoon
  checkpoint above. Still required: live capture/route fleet smoke check and release CI.

An inert `notice-preview` bundle was built successfully with unique bundle ID
`com.definitelyreal.speakfree.delete-preview`. `SPEAKFREE_NOTICE_PREVIEW_FAILURE=1` selects
a simulated failure result; no actual deletion or config changes occur in preview actions.
The app reported its dialog open, but CUA `getApp` timed out three times with error -10005,
including lookup by the observed bundle ID. The preview was terminated; the user's daily
app remained running. **At that earlier checkpoint the UI gate remained unverified.** Preview artifacts and logs
are private under `build/release-readiness/`. Continue other release/research work while this
automation limitation is unresolved; arrange a brief manual check if needed.

## Release mechanics

Read current `scripts/build.sh` and `scripts/publish-release.sh` before acting. The old ship
skill names an obsolete `scripts/deploy.sh` and `Sources/OpenWisprLib/Version.swift`; those
paths do not exist here. Current version source is `Sources/SpeakFreeLib/Version.swift`.
`build.sh` creates a draft release; `publish-release.sh` makes it public and pushes the appcast.
Keep those external mutations separate from local readiness testing. User has expressed
release intent, not yet approved a concrete signed candidate for public publication.

Every dev redeploy goes to all three Macs using the fleet script and trash-then-copy sequence.
Do not change recording-saving preferences for tests. Routine automated tests use scratch
recordings. The September 13 user-requested interactive deletion test is an explicit
exception: require a fresh verified backup and the user's concrete final deletion action.
