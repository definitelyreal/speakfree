<!-- ai-processed:unverified | session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 | date:2026-09-09 | asof:2026-09-09 -->
# Idle route churn: September 9 investigation

Michael reported disconnect/reconnect events while idle and asked what happens next.
Treat route stability as a release readiness gate alongside the deletion flow. Keep
accuracy/engine experiments on the separate research branch.

## Evidence from live logs

The three installed processes were still on the previously deployed build `3143a81`.
Read-only SSH checks confirmed the hosts Noah/Studio and matching UTC clocks.

| Local time (PDT) | Observed event |
|---|---|
| 14:20:56 | Studio's catalog added the AirPods |
| 14:21:01–02 | Noah's Apple Smart Routing daemon reported disconnection; SpeakFree catalog removed AirPods |
| 14:25:04.808 | Noah's Apple daemon initiated a Tipi2.0 Smart Routing connection |
| 14:25:08.112 | Apple reported `UserConnected no` |
| 14:25:09 | Noah's catalog added AirPods and recreated internal aggregate routes |
| 14:25:11–13 | Noah's built-in capture stopped supplying valid audio, then restarted |
| 14:25:13 | Studio's catalog removed AirPods |

This supports automatic handoff between the Macs, not a requirement for the user to touch
anything. The initiating foreground app/media event is not established. All eight SpeakFree
capture starts in Noah's current process log used the built-in microphone; no AirPods capture
start was logged. Do not claim that SpeakFree explicitly connected the AirPods in this episode.
Ark's current process log showed no corresponding Bluetooth churn after startup.

Noah's process snapshot (12:03–14:25) contained 17 Bluetooth catalog events, 39 internal
aggregate events, and seven capture failures/recoveries. These are three different quantities.
`CADefaultDeviceAggregate-*` devices are internal route graphs, not extra physical headsets.

## Old diagnostic poller

A Claude-launched audio watcher was still running after 14 days, invoking
`system_profiler SPAudioDataType` every two seconds. A bounded pause/restoration probe counted
203 `HALAudioDeviceChanged` log entries in the preceding 20 seconds and 21 during the pause.
This single short A/B supports a substantial contribution to log chatter; it does not establish
that the watcher caused the Bluetooth handoffs. The exact watcher process was then terminated,
with its command and logs preserved. Its Claude parent and the daily app were left running.

Private receipts live in the research checkout under `build/2026-09-09-route-investigation/`:
fleet snapshots, Bluetooth log, source hashes, `watcher-probe.json`, and the retired command.
Never commit these raw logs to the public repository.

## Candidate fix and limits

The current DeviceAudioSession never subscribed to engine configuration changes. An engine
stopped by an output change waited for the coordinator's 1.5-second missing-audio threshold
plus its one-second poll cadence before recovery. Apple documents that input **or output**
format changes can stop the engine, and forbids teardown inside the notification handler.
[Apple engine notification documentation](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange).

The release candidate now observes only its own engine, forwards notification handling to
its independent worker without blocking Apple's notification queue, and reports a stopped
engine promptly through existing bounded recovery. Running engines are left alone; cancelled
or already-reported sessions are ignored. Observers are removed before retirement. The
missing-sample watchdog remains a fallback. This reduces detection delay; it does not provide
seamless hardware continuity or disable Apple's automatic switching.

Internal aggregate churn now gets a separate `Audio graph` summary instead of physical-device
joined/left messages. Real Bluetooth catalog events retain their existing logs.

78 focused tests passed, including nonblocking delivery while the worker is occupied,
sender isolation, observer removal, microphone routing, resampling and capture recovery.
Log: `build/release-readiness/route-recovery-tests.log`. Hardware improvement remains unverified
until a candidate is installed and exercised across real output/ownership changes.
The optimized release build also passed (`route-recovery-build.log`, 83.20 seconds).
No new candidate has been installed yet; these changes cannot explain prior observed events.

## Next order of work

1. Resolve Michael's pending preference: keep Apple auto-switching, or set “Connect to This Mac”
   to “When Last Connected” on Noah and Studio. No setting has been changed. Apple's supported
   control is documented in [Switch AirPods between devices](https://support.apple.com/guide/airpods/switch-airpods-between-apple-devices-dev228ba3df8/26/web/26).
2. Validate the release candidate on all three Macs with normal input/output selection and
   AirPods handoffs. Require intelligible first/last words, preserved built-in pre-listening,
   bounded recovery without deadlock/retry exhaustion, and no new routing churn. Do not confuse
   fewer log messages with stable capture.
3. Complete the deletion UI gate and release CI, then present the concrete signed candidate
   for public release. Do not publish from the research branch.
4. Continue offline vocabulary-cost ablation and decoder-bias/model comparisons independently,
   using persistent human annotations and reviewed corpus candidates.
