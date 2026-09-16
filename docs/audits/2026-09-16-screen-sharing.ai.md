<!-- ai-processed:unverified | session:01a0a336-fe39-7870-bdab-33c820f98955 | date:2026-09-16 | asof:2026-09-16 -->
# Screen Sharing insertion regression

## Scope and evidence

Michael reported repeated `a` characters instead of dictation in macOS Screen Sharing.
The installed Apple viewer identifies itself as `com.apple.ScreenSharing`, which was
missing from TextInserter's remote-app classifier. The local fallback emits virtual
key 0 with a Unicode payload. A remote viewer forwarding the keycode instead of that
payload explains the symptom; actual remote reproduction has not yet been captured.

Changes are limited to insertion routing, remote failure recovery and regression tests.
No recording files, retention settings, recognition engine or model downloads changed.

Screen Sharing now follows the existing AppleScript remote backend, including after
refocusing. Remote insertion cannot fall back to Unicode key-0 events when the
clipboard is too large. AppleScript errors offer selectable-text recovery without
retrying a potentially partially delivered dictation. Automation denial names the
required macOS setting. Explicit Copy Dictation is the only recovery action that
replaces the clipboard.

Delayed remote pastes check the original process, bundle, clipboard generation,
Secure Input and captured AX focus before dispatch. If initial AX focus was unavailable,
only app identity can be checked. Recovery modals enter through the main run loop,
not a main-dispatch block, so clipboard restoration can continue.

## Checks on this candidate

- 58 tests passed, zero failures: ScreenSharingInsertionTests, ClipboardRestoreTests,
  SecureInputTests, AdversarialR1InsertionTests and AdversarialR2InsertionTests.
- Exact source release build passed in 35.97 seconds. Existing dependency deployment-
  target and concurrency warnings remain; this is not a clean full-repository warning gate.
- SwiftLint on the two changed Swift files and `git diff --check` passed.
- Test log: `build/release-readiness/2026-09-16-screen-sharing-tests.log`.
- Build log: `build/release-readiness/2026-09-16-screen-sharing-build.log`.
- Fresh-context Astra requirements review established a live remote acceptance oracle.
  Independent code-aware Astra review found the large-clipboard fallback and delayed-
  paste races, then the modal scheduling issue. Those findings were addressed and
  re-reviewed. This is code-level review, not a live remote acceptance pass.

## Still requires live acceptance

Actual voice-to-remote-document insertion, non-ASCII/emoji fidelity and remote clipboard
synchronization remain unverified. Multiline uses the remote clipboard path and depends
on the viewer's clipboard-sharing capability. Unit tests use a named pasteboard and
intercept Apple Events/keyboard backends; they cannot prove delivery on the second Mac.

After installing the identified candidate, test in a disposable TextEdit document on
the remote Mac: dictate mixed case, numbers and punctuation twice; insert accented text
and a newline; replace a selection; verify no duplication or repeated `a`; exercise
clipboard sharing disabled/unavailable and changing focus before delivery. Do not use
a terminal, message composer or password field for these checks.

## Disk policy clarification

Michael authorized bounded small builds below the general disk floor when estimated
additional use is at most 10 GB. The canonical shared POLICY.md now records that
exception, including peak staging/cache space and checks against actual growth.
This incremental build was budgeted below 3 GB; the existing build cache grew about
8 MB. Free disk fell independently from about 52 GB to 22 GB while Dropbox's incoming
cache grew. Active Dropbox staging and all recording backups were left untouched.
