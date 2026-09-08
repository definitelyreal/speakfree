<!-- ai-suggestion:unverified | session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 | date:2026-09-08 | asof:2026-09-08 -->
# Dictation and AirPods follow-up

## Obvious bugs fixed

- Startup is coalesced through final main-thread initialization. Pending settings changes run afterward. Existing hotkey listeners and health timers are stopped before replacement.
- Microphone, hotkey and punctuation changes retain the speech engine when engine/model/language are unchanged. Previously each save rebuilt it and initiated another model warm-up.
- The microphone resampler supplies each input buffer exactly once, preserves conversion history, rounds output capacity upward, and reuses output storage. A continuous 173 Hz synthetic signal at 24/44.1/48 kHz catches discontinuities from the old repeated-input behavior. The replacement passes duration and continuity checks. This establishes signal integrity on synthetic inputs, not a measured gain in word accuracy.
- Whisper subprocesses drain both pipes with bounded output and a monotonic deadline. A stuck helper is terminated, then killed if it ignores termination. Foreground budgets scale with recording duration, capped at 30 minutes; background diagnostic shadows cap at two minutes. Only one shadow runs at once, with at most two CPU threads. Foreground rescue retains its full CPU budget.
- Diagnostic logging serializes file state and enable/disable transitions, caches its timestamp formatter and file handle, bounds queued messages, uses throwing I/O, and rotates each session across three files of at most 8 MiB. Separate processes get unique files. Directory/file permissions remain 0700/0600. Logging stays asynchronous.
- The menu reports model loading separately from hotkey readiness. A failed warm-up no longer prints a success message. The AirPods menu tooltip no longer claims universally better recognition in noisy rooms.

## What the available data supports

Metadata dated August 21 onward contains 2,341 recordings labeled exactly `MacBook Pro Microphone` and 36 labeled AirPods. Their median model confidence is 0.9665 and 0.9622 respectively; 266 and 8 score below 0.92. Empty transcript counts are 81 and 1. These are model-confidence and output-length measurements, **not accuracy scores**. The AirPods group is small and the recordings were not a controlled comparison. No transcript text was used to infer what Michael intended.

The earlier operational-log aggregation found median completed-dictation latency of 0.53 seconds and p95 of 2.1 seconds over 1,043 completions. It also found 24 stale-format events, two engine-start failures and two missing-first-buffer events. Log retention, routing changes, and missing completions prevent treating these as per-microphone failure rates. The directly sampled AirPods format-change deadlock remains stronger evidence than a guessed accuracy difference.

For headphone listening quality, keeping the built-in microphone as the automatic choice is already implemented in `AudioRecorder.effectivePin`; explicit microphone selections win. Apple documents reduced Bluetooth headphone playback quality while their microphone is active ([Apple Support](https://support.apple.com/en-mide/102217)). Apple's newer AirPods high-quality recording option is described for iOS 26 ([WWDC25](https://developer.apple.com/videos/play/wwdc2025/251/)); the installed macOS SDK explicitly marks `configuresApplicationAudioSessionForBluetoothHighQualityRecording` unavailable on macOS. It is not a switch this native Mac app can simply enable through that API.

## Decisions left to Michael

1. Keep the current automatic built-in-microphone preference, or prefer the AirPods microphone when connected. Explicit choices stay intact. Recommendation: retain the current built-in preference for listening quality; choose AirPods explicitly when distance/noise makes its microphone useful.
2. Authorize the larger audio-lifecycle refactor that moves remaining driver startup and routing calls off the UI thread. Recommendation: do it, with physical AirPods reconnect, sleep/wake, and pre-buffer-off validation. The specific observed teardown deadlock is already fixed; this contains other possible driver stalls.
3. Accuracy tuning needs confirmed intended text for representative troublesome recordings. Second-model disagreements can identify candidates, but neither model is ground truth. No guessed homophone substitutions or corpus expectations were added.

## Validation and deployment

- Full debug suite: 1,199 tests, three opt-in render harnesses skipped, zero failures (52.910 seconds).
- New targeted checks cover simultaneous full stdout/stderr pipes, an infinite writer, a child ignoring SIGTERM, startup coalescing, continuous resampling, logger concurrency, rotation, file permissions, and disable/re-enable ordering.
- A negative control restoring repeated resampler input fails the signal test; the corrected implementation passes.
- Optimized release regression set: 27 tests, zero failures (1.429 seconds). Fleet verification follows below.

## Sources and limitations

Current repository code, XCTest outputs in `/tmp/speakfree-followup-full-tests.log`, `/tmp/speakfree-obvious-tests2.log`, and `/tmp/speakfree-resampler-negative-control.log`; local recording metadata; retained app logs; remote process status. The prior audit's conclusions remain AI-unverified and were used as leads. Metadata counts above were recomputed during this follow-up. Physical AirPods handoff behavior and recognition accuracy still require real-device/ground-truth validation. No recordings were deleted or modified.
