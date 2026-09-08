<!-- ai-suggestion:unverified | session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 | date:2026-09-08 | asof:2026-09-08 -->
# speakfree stability and usability audit — September 8, 2026

The MacBook's reported crash was a live main-thread deadlock after an AirPods format change. All three installed bundles identified themselves as commit `a241315`, built August 21. The working tree started clean at `b4eed23`.

## Direct evidence

At 09:58 PDT, `/usr/bin/sample 52340 3` sampled every MacBook main-thread observation (2,590 samples) in this chain:

```text
AudioRecorder.startEngine()
-[AVAudioEngine dealloc]
_dispatch_sync_f_slow
__DISPATCH_WAIT_FOR_QUEUE__
```

Two audio engine queues were simultaneously waiting in:

```text
AVAudioEngineImpl::IOUnitConfigurationChanged()
-[NSNotificationCenter postNotificationName:object:userInfo:]
-[NSOperation waitUntilFinished]
_pthread_cond_wait
```

The last local session log entries were September 7 at 17:50:19: an engine pinned to AirPods reported 48 kHz against a 24 kHz hardware rate, was rejected as stale, and scheduled retry 1. The expected completion never followed. This binds the return from rejected startup to the engine destructor, which waited for an engine queue whose notification was itself waiting for main.

The September 3 MacBook session also ended immediately after the same stale-format retry (attempt 2), consistent with this failure but without a retained stack sample.

The Studio process was running and its sampled main thread was servicing the event loop. Ark had no running process; its last retained session log ended with a model unload on August 26. No speakfree crash report was found in the searched DiagnosticReports folders. This does **not** establish what stopped Ark or explain every historical incident.

## Implemented changes

- **Critical — audio deadlock:** configuration notifications now post asynchronously to main. They transport an identity rather than retaining an engine in UI work. Rejected startup candidates, normal rebuilds, pre-buffer shutdown, recording stop, and app shutdown all transfer engine ownership to background teardown. Startup's temporary references stay inside a non-inlined function. Resources linger eight seconds after teardown for late device callbacks; final release also stays off main.
- **High — recovery robustness:** failed engine starts catch both Swift errors and Objective-C exceptions and schedule bounded retry. Converter and tap failures also retry. Pending rebuilds cannot resurrect capture after shutdown or while pre-buffer is off and no recording is active. Rebuild logs distinguish success from failure.
- **Medium — recording integrity:** repeated starts return before opening/truncating a WAV. Pre-roll writes are enqueued while the recording-state lock is held, ahead of incoming live buffers.
- **Medium — shared state:** audio meters use the existing buffer-health lock. Initial routing and pre-buffer changes are applied together on main instead of mixing setup-thread and main-thread engine state.
- **Performance — WAV encoding:** allocate the PCM byte buffer once and fill it directly, eliminating one Data append per sample. Preserve the previous finite-sample quantization and explicit little-endian encoding; non-finite input becomes silence.
- **Usability — unavailable Edit mode:** the settings picker offers Hold and Toggle. Existing Edit configurations retain their stored value and explicitly show `Toggle (Edit unavailable)`, matching the current fallback; no unimplemented editing window is advertised.
- **Deployment integrity:** failed removal of an old app now aborts installation before copying; remote installation stops on command errors. This enforces the required trash-then-copy sequence instead of silently falling through to an in-place replacement.

## Validation

- Baseline: 1,179 tests, three skipped, zero failures.
- Final full suite: 1,188 tests, three skipped, zero failures (26.277 seconds). The skips were opt-in HUD, Help and Settings rendering harnesses; the functional audio/pipeline tests ran.
- Optimized release regression set: 58 tests, zero failures. Covers notification delivery with main deliberately occupied, blocked and rapid resource destruction, linger/completion ordering, routing/format recovery, startup failures, and WAV recovery/encoding.
- PCM encoding equivalence covers 131,069 signal values across the full finite sample range, plus explicit clipping, byte order, empty and non-finite cases.
- M3 Max, optimized standalone microbenchmark, 4,096 samples × 1,000 iterations, median of seven runs: previous encoder **83.075 ms**, new encoder **4.854 ms**, **17.11×** faster. This measures only PCM conversion, not transcription or total app latency. Reproduce with `scripts/benchmark-wav-encoding.swift` using its header command.
- Fleet installation completed using `bash scripts/dev-deploy-fleet.sh`. All three installed bundles report `d4c677e` and pass `codesign --verify --deep`. Post-install samples on M3 (PID 61759), Studio (59373), and Ark (34064) showed normal main event loops; each logged healthy startup audio and hotkeys. M3 and Studio completed model warm-up. At 10:22 PDT, Ark remained responsive but model warm-up was still inside Apple’s ANE compiler, whose process was actively consuming one CPU core. Ark’s transcription readiness is therefore **not yet confirmed**; installation and main-loop responsiveness are confirmed. Physical AirPods reconnect and sleep/wake were not exercised; the notification deadlock was tested deterministically.

## Remaining recommendations, in priority order

These are code-review findings and proposals, not independently verified historical crash causes.

1. **Bound Whisper subprocess work.** `Transcriber.transcribeWithCLI` waits for stdout/stderr and exit without a deadline. A hung CLI can strand a foreground rescue or background shadow. It also gives each CLI all logical processors. Add cancellation, a duration-aware timeout, a concurrency limit for shadows, and a conservative thread budget; test with a deliberately stalled child process before changing live behavior.
2. **Move the remaining device-start calls off the UI thread.** The specific circular wait is fixed, but input-node creation, device binding and engine start still call driver/OS code on main. A serial audio-lifecycle executor with generation checks would contain other driver stalls. This deserves a separate lifecycle refactor with physical AirPods, sleep/wake and pre-buffer-off testing.
3. **Make resampling consume each input buffer once.** The tap's converter callback currently always returns the same input buffer as `.haveData`. Audit with 24/44.1/48 kHz synthetic sequences and check continuity before switching to a one-shot input provider and reusable output buffers. The current audit does not establish that this caused dropped or duplicated speech.
4. **Serialize and bound diagnostic logging.** `DiagnosticLogger` still shares mutable enable/file state across callers, formats time on the calling thread and opens a file per line. A queue-owned writer with throwing I/O and rotation would reduce overhead and avoid logger failures affecting dictation. Preserve disabled-logging behavior and owner-only permissions.
5. **Coalesce concurrent setup.** Ark’s post-install log contains two `Setup started` entries and two event-tap creations during the same launch. `setup()` has no in-flight guard, and `reloadConfig()` can schedule another full setup before `isSetupComplete` becomes true. Add a startup gate and consume pending settings changes after completion to avoid competing model warm-ups and repeated hotkey registration. This is a separate observed startup issue, not the sampled MacBook deadlock.
6. **Add explicit readiness/hang diagnostics to fleet checks.** A live PID alone cannot distinguish the observed deadlock from a healthy app. Do not label the app ready before its initial model warm-up finishes. Add a main-loop heartbeat/readiness probe and microphone-buffer age, and retain a compact stack sample on missed heartbeats. The present deployment was additionally checked manually with process samples.

## Sources and trust

Direct sources: current source files and git metadata; local and remote Info.plists; app diagnostic logs; local and Studio process samples; XCTest output; optimized microbenchmark. Prior AI-authored comments were treated as leads, not as evidence for historical claims. This report remains AI-unverified; passing tests have not promoted it to human-verified status.

Local raw sample: `/tmp/speakfree-hang-sample.txt`, SHA-256 `961afead5cb57ded486e442b65988ef38f9b51ae538e860395edfac488aa35e9`; via `/usr/bin/sample` on macOS 26.6.2 (25G83), captured 2026-09-08 09:58:40 PDT. The relevant stack evidence is preserved above because temporary raw files may later be removed.
