<!-- ai-processed:unverified | session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 | date:2026-09-09 | asof:2026-09-09 -->
# Existing-code release: start here

September 9 follow-up: [ROUTE-STABILITY.ai.md](ROUTE-STABILITY.ai.md) records the live
Noah/Studio handoffs, removed stale diagnostic poller, and stopped-engine recovery candidate.
Route stability is now a release gate; deletion correctness alone is insufficient.

Michael's September 9 direction: release the existing app once the relevant flow is
working, while pursuing accuracy/engine development independently. He said “deletion
flow”; clarification whether this meant dictation is pending in the current task.
Do not reinterpret the pending answer as approval to publish.

## Boundaries

- This checkout: `codex/release-readiness`, forked from `1d86b3a`.
- Research checkout: sibling `../speakfree`, branch `codex/accuracy-research`.
- Installed fleet build: `3143a81`. Public latest release observed via GitHub: `v1.7.1`.
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
- Still required: live UI success/cancel/failure behavior in an isolated scratch config,
  exact candidate build/fleet smoke check, and release CI. Unit tests are not the UI gate.

An inert `notice-preview` bundle was built successfully with unique bundle ID
`com.definitelyreal.speakfree.delete-preview`. `SPEAKFREE_NOTICE_PREVIEW_FAILURE=1` selects
a simulated failure result; no actual deletion or config changes occur in preview actions.
The app reported its dialog open, but CUA `getApp` timed out three times with error -10005,
including lookup by the observed bundle ID. The preview was terminated; the user's daily
app remained running. **UI gate remains unverified, not passed.** Preview artifacts and logs
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
Never change the user's recording-saving preference or delete real recordings to run tests.
