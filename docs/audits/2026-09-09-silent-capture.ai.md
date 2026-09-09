<!-- ai-suggestion:unverified | session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 | date:2026-09-09 | asof:2026-09-09 -->
# Silent capture after the pre-listening deployment

## Direct findings

The seven Noah recordings from 11:55:05 through 11:56:26 on September 9 contain exclusively zero-valued PCM samples, including their pre-roll. Durations range from 0.84 to 5.60 seconds. These are capture failures, not recognition mistakes. The retained recordings were inspected numerically without interpreting their spoken contents; originals were not modified.

The app repeatedly logged that capture was being rebuilt after each silent take. In the new coordinator, `recover()` only checked callback freshness: a stream delivering zeros had recent callbacks and was kept. The intended recovery therefore never occurred. This is a regression introduced by the September 8 refactor. The pre-recording “all OK” log also overstated what the asynchronous capture check established.

The preceding eleven September 9 recordings had nonzero signal. Their longest consecutive runs of exact zero PCM samples were at most 0.0003 seconds. A full second of digital zeros is substantially different from those quiet-but-working recordings. This supports a bounded digital-zero guard for this incident; it does not establish behavior for every possible muted/noise-gated input device.

## Fleet log review

Reviewed retained SpeakFree session logs on all three Macs, current Bluetooth/CoreAudio state, diagnostic-report inventories, relevant Ark resource reports, and numeric signal properties of recent Noah recordings. Session counts for build `ed96ad8` before the mitigation restart:

| Machine | Takes | Completed | Empty short takes | Silent failures | Capture failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| Noah | 42 | 31 | 4 | 7 | 24 across two sessions |
| Studio | 10 | 10 | 0 | 0 | 21 |
| Ark | 1 | 1 | 0 | 0 | 9 |

Completed dictation latency medians were 0.39 seconds on Noah, 0.59 on Studio, and 0.50 for Ark's single take. These completion counts and latencies do not measure text accuracy. The four empty takes on Noah were approximately 0.6–0.8 seconds long; intent cannot be inferred from duration.

Capture failures frequently coincided with Bluetooth/default-device aggregate changes and missing callbacks. Studio also logged a sample-clock disagreement and a transient 24 kHz engine format against its 48 kHz built-in microphone. Many failures recovered within roughly two seconds. The logs do not establish the original cause of every driver interruption, nor do they establish that another Mac stole the microphone.

No SpeakFree, CoreAudio, or Bluetooth crash report was found in the inspected user/system report directories. Ark has earlier ANE compiler CPU/disk resource reports; one documents 8,589.94 MB dirtied over 25,736 seconds before the September 8 deployment. Its current compiler is idle, and the model finished loading yesterday. That old compiler issue does not explain today's zero-filled Noah recordings.

## Repair

- A failed/empty capture now invokes an explicit stream restart, clears stale pre-roll/timeline state, refreshes devices, and rejects callbacks from retired generations. Routine preflight checks retain the lightweight health check.
- A full second of exact digital zeros fails the individual stream and enters existing bounded recovery. Quiet nonzero audio is accepted. Zero-filled secondary audio does not take over from the base microphone; a secondary becoming zero-filled returns delivery to the base while recovery proceeds.
- Retry-exhausted capture reports unavailable audio, and a missing base microphone no longer produces a claim that backup pre-listening is protected.
- The general health log says which checks completed and that audio recovery is asynchronous.
- `audio-check` now records nonzero sample counts and RMS per source in its numeric result. Counting frames alone did not prove audio quality in the prior hardware check.

Noah was gracefully restarted at 11:57 as an immediate mitigation while preparing the code fix. No microphone preferences or retained recordings were changed.

## Validation and limits

Full suite: 1,216 tests, three opt-in tests skipped, zero failures. New regressions reproduce recent zero buffers surviving recovery, verify working-base retention under zero-filled AirPods, and distinguish quiet nonzero input from digital zeros. Existing delayed-start, overlap, disconnect, pre-roll, WAV, and resampling coverage remains passing. Log: `/tmp/speakfree-silent-recovery-full-tests.log`.

This repair addresses a demonstrated recovery regression. The initial reason both streams supplied zeros after waking remains unresolved. The multi-device audio lifecycle and perceived AirPods playback/word quality still need real-use validation; previous AI audit conclusions are leads, not independent ground truth.
