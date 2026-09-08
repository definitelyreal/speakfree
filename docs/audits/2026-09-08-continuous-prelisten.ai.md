<!-- ai-suggestion:unverified | session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 | date:2026-09-08 | asof:2026-09-08 -->
# Continuous pre-listening and AirPods capture

This engineering follow-up implements Michael's approved lifecycle refactor and his request to preserve SpeakFree pre-listening while releasing the AirPods microphone between dictations. It supersedes the proposed single-microphone idle policy in the earlier dictation audit.

## Behavior

- Automatic selection keeps the built-in microphone capturing the preceding half-second and starts an available Bluetooth microphone for live dictation. An explicit microphone selection wins. A physical non-Bluetooth microphone substitutes on Macs without a built-in input; automatic routing avoids virtual/aggregate inputs when a physical alternative exists.
- The base microphone remains running while Bluetooth starts and during the recording. Host-clock timestamps join the streams and trim overlap, preserving initial speech without repeating the handover. A buffered base tail covers Bluetooth disconnects and closes recordings whose Bluetooth audio is still arriving.
- Bluetooth stays warm for 30 seconds after dictation, then releases while the base continues pre-listening. With only a Bluetooth input available, continuous pre-listening necessarily keeps that input active.
- Independent device workers own engine creation, device binding, startup, tap removal, stopping, and destruction. Driver stalls cannot block the capture-control queue or UI. Startup attempts and recovery are bounded; superseded callbacks cannot resurrect old routes.
- Native format and capture timestamp cadence must agree before samples enter the recording. A mismatched clock causes recovery with fallback instead of accepting a suspect stream after retries.
- Settings distinguish Automatic from explicitly choosing the built-in microphone. The menu describes live dictation selection separately from actual capture status. Disconnected pins survive and resume when that microphone returns.
- Removed the speculative AirPods contention modal. Repeated routing events did not prove another device was taking the microphone. Status now reports connecting, actual capture, and fallback directly.

## Incident context

During development Michael reported AirPods switching back to the MacBook. The still-installed previous build logged the AirPods input disappearing at 12:13:07 PDT and retained its AirPods pin while falling back. Michael separately clarified that he unchecked Dictation Mode after the contention warning; turning that old mode off explicitly restored the previous/Mac input. These observations do not establish that another Apple device caused the disappearance. The replacement implementation had not yet been installed at the time of those reports.

## Verification

- Full debug suite: 1,213 tests, three opt-in render tests skipped, zero failures, 28.734 seconds. Log: `/tmp/speakfree-dual-final-tests.log`. The subsequently removed unused contention callback and modal have no remaining callers.
- New tests cover continuous pre-roll, delayed Bluetooth startup, exact sample ordering and overlap trimming, fallback tails, duplicate start/WAV integrity, wrong sample-clock cadence, 30-second idle release, explicit selections, virtual-device avoidance, and disconnect/reconnect without restarting the base microphone.
- Final optimized release regression set: 27 tests, zero failures. Log: `/tmp/speakfree-dual-release-final-tests.log`.
- A signed release-build hardware check used the actual MacBook and connected AirPods. Across 12.045 seconds it emitted 11.391 seconds of valid audio after initial startup: 86,444 samples from the MacBook and 95,819 from AirPods. Status progressed through built-in pre-listening, built-in capture while AirPods connected, AirPods capture with protected pre-listening, and back to the built-in microphone. Logs: `/tmp/speakfree-dual-hardware-launchservices.log` and its `-errors` counterpart.
- The new `audio-check` command exercises that route sequence without saving audio/transcripts or changing user preferences. LaunchServices was needed for the existing app microphone permission; direct shell launch had a different TCC context and was denied. No permissions were reset.
- Physical case-close/reopen, sleep/wake, prolonged simultaneous capture, and perceived audio quality remain dogfood checks. The hardware check establishes real sample delivery and route changes, not measured recognition accuracy.

## Recording review and remaining issues

Michael's supplied review is retained in the gitignored `build/2026-09-08-airpods-review/references.ai.md`, preserving tentative words and unknown spans. Clip 3 is a positive control. Clip 2 is reported as slow/static audio, so guessed transcript substitutions would hide a capture problem. A separate doubled-rate diagnostic copy did not yield a trustworthy restoration. Original recordings remain unchanged; no guessed corpus expectations or homophone regex rules were added.

Ark's root-owned `ANECompilerService` PID 91829 was still consuming approximately 100% of one CPU core at the latest check. Michael authorized termination, but SSH sudo required administrator authentication. A subsequent AppleScript administrator request failed immediately with authentication error -60007. No termination succeeded. The service predates this deployment; its original cause is not established.

## Fleet outcome

`bash scripts/dev-deploy-fleet.sh` completed the required trash-then-copy installation on all three Macs. Each installed bundle reports commit `ed96ad8`, passes deep code-signature verification, and is running. All three logged valid built-in pre-listening. Two-second samples showed responsive main event loops. MacBook and Studio completed Parakeet warm-up in 0.2 seconds.

Ark's model did not complete warm-up during verification. Its worker sample is waiting in CoreML's ANE compilation path while the pre-existing compiler service consumes a core. Capture/UI are responsive, but dictation on Ark is not yet ready. The remaining operator action is to stop PID 91829 through Activity Monitor's All Processes view using administrator authentication, then recheck model readiness. Deployment log: `/tmp/speakfree-prelisten-fleet-deploy.log`; local sample: `/tmp/speakfree-prelisten-m3-sample.txt`; remote samples: `/tmp/speakfree-prelisten-sample.txt`.

The MacBook's saved input preference was Automatic at verification, and AirPods were absent from its available input list. It correctly used the built-in microphone. No user microphone preference was overwritten during deployment.

### Later Ark recovery

At the next live check around 13:42 PDT, PID 91829 remained present but used 0% CPU. Ark's log records successful model loading at 12:36:32 after 790.17 seconds and successful warm-up after 790.2 seconds. This supersedes the outstanding termination instruction above: stopping the now-idle compiler is no longer necessary. No agent termination attempt succeeded.

## Evidence and trust

Sources are current code, XCTest output, direct hardware-check output, technical app logs, Michael's recording review, and live process listings. Earlier AI audit conclusions were treated as unverified leads. This report remains AI-unverified; automated tests and the bounded hardware exercise do not replace broader real-world validation.
