<!-- ai-processed:unverified | session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 | date:2026-09-13 | asof:2026-09-13 -->
# Existing-code release: start here

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
and the September 13 rerun has the same 28 file/line/message findings, with no additions.
and per-file comparison to the lane's `1d86b3a` base. Resolve applicable lint failures before
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

The user has been asked to open Settings → Your corpus → Click here to delete, then
choose **Cancel**. Response is pending. No actual deletion has occurred, and cancellation
on the installed build would not qualify the uninstalled candidate. Refresh backup
coverage before the destructive step and let the user perform the final deletion click
as part of this interactive check. Verify the on-disk outcome, restore missing files
without overwriting new recordings, and confirm the restored count/UI afterwards.

## Boundaries

- This checkout: `codex/release-readiness`, forked from `1d86b3a`.
- Research checkout: sibling `../speakfree`, branch `codex/accuracy-research`.
- Installed fleet build observed September 9: `3143a81`; Noah rechecked September 13.
  Public release last checked via GitHub September 9: `v1.7.1`.
- No open PR existed at review. No new build has been installed or published in this lane.
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
