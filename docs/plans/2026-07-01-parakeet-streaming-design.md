<!-- ai:suggestion | session: f2070c71-48d2-4d03-8ed9-c08a87a52eb5 | date: 2026-07-01 -->
# Parakeet streaming — live preview on the default engine (design)

**Status:** direction greenlit by Michael 2026-07-01; open product decisions marked **DECISION NEEDED (Michael)** below. Prior contract research in [build/26-06-07-parakeet-impl/research/01-fluidaudio-contract.md](../../build/26-06-07-parakeet-impl/research/01-fluidaudio-contract.md); 2026-06-24 migration decisions in [build/26-06-24-parakeet-streaming-migration/PROMPT.md](../../build/26-06-24-parakeet-streaming-migration/PROMPT.md).

## Intent

Parakeet (`parakeet-tdt-0.6b-v2`) is the default engine for new users, but it is batch-only: the recording overlay shows nothing while dictating, where whisper users see a live, sentence-stable preview. This design closes that UX gap — live preview while dictating on Parakeet — without touching the final-pass text path (which stays batch, keeps the 3s truncation pad, and keeps the no-silent-fallback discipline), and without regressing the stability commits (6533232 pad, c5cef82 teardown).

## Current state

- **Protocol:** `TranscriptionEngine.supportsStreaming` ([TranscriptionEngine.swift:9](../../Sources/SpeakFreeLib/TranscriptionEngine.swift#L9)) and `transcribeStreaming(samples:language:prompt:suppressRegex:onPartialResult:) async throws -> String` ([TranscriptionEngine.swift:21-25](../../Sources/SpeakFreeLib/TranscriptionEngine.swift#L21)). `ParakeetEngine` reports `supportsStreaming = false` ([ParakeetEngine.swift:249](../../Sources/SpeakFreeLib/ParakeetEngine.swift#L249)) and throws `.streamingUnsupported` ([ParakeetEngine.swift:309-315](../../Sources/SpeakFreeLib/ParakeetEngine.swift#L309)).
- **Driver:** `AppDelegate.startStreamingTimer` gates on `config.streamingEnabled` (default true) + `transcriber.supportsStreaming` ([AppDelegate.swift:1137-1141](../../Sources/SpeakFreeLib/AppDelegate.swift#L1137)), then a **2.0s repeating timer** calls `processStreamingChunk` ([:1146](../../Sources/SpeakFreeLib/AppDelegate.swift#L1146)). Each tick snapshots the FULL buffer since record-start (`recorder.currentSamples()`, `[Float]` @16 kHz), requires >1s of audio, enforces one pass in flight, and calls `transcriber.transcribeStreaming` over the whole buffer ([:1166-1216](../../Sources/SpeakFreeLib/AppDelegate.swift#L1166)). So the existing "streaming" contract is **periodic batch re-transcription of a growing buffer** — `WhisperEngine.transcribeStreaming` is one `whisper_full` run per tick with a `new_segment_callback` delivering partials mid-run ([WhisperEngine.swift:311-332](../../Sources/SpeakFreeLib/WhisperEngine.swift#L311)).
- **Stabilization:** partials go through `buildStableDisplayText` → `StreamingTextAssembler.append` — text through the last `.!?` is committed/frozen, the volatile tail follows on a new line ([AppDelegate.swift:1244-1248](../../Sources/SpeakFreeLib/AppDelegate.swift#L1244), [StreamingTextAssembler.swift:24-67](../../Sources/SpeakFreeLib/StreamingTextAssembler.swift#L24)). A `streamingGeneration` token discards callbacks from a superseded recording ([AppDelegate.swift:1191, 1207-1208, 1158](../../Sources/SpeakFreeLib/AppDelegate.swift#L1191)).
- **Finalization today:** the final pass is always a fresh batch `transcribe` with prompt/VAD/TextPipeline; the T2.3 `StreamingReuse` gate that could substitute the last partial is **DEFAULT OFF** because measured partial-vs-final divergence was ~5%, >5× the locked <1% gate ([AppDelegate.swift:966-985](../../Sources/SpeakFreeLib/AppDelegate.swift#L966), [StreamingReuse.swift:15-27](../../Sources/SpeakFreeLib/StreamingReuse.swift#L15)).
- **Scaffold:** `feat/parakeet-streaming` carries runtime isolation only — `scripts/install-streaming.sh` builds a separate **SpeakFree Streaming.app** (bundle id `com.definitelyreal.speakfree.streaming`) and `Config.configDir` maps the `.streaming` bundle-id suffix → `~/.config/speakfree-streaming` (models symlinked from production). No engine code exists on the branch yet.

## FluidAudio 0.15.1 streaming contract (pinned in Package.resolved)

Two distinct surfaces; only one applies to TDT:

1. **`StreamingAsrManager` (protocol) — NOT usable for us as-is.** It is the interface for *cache-aware true-streaming* engines ([Streaming/StreamingAsrManager.swift:4-20](../../.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Streaming/StreamingAsrManager.swift#L4)): `appendAudio(AVAudioPCMBuffer)`, `processBufferedAudio()`, `finish()`, `setPartialTranscriptCallback` (:34-55). Its conformers require **different model bundles** than our v2/v3 TDT CoreML: Parakeet **EOU 120M** (160/320/1280ms chunks) or **Nemotron 0.6B** (560-2240ms), each from its own HF repo ([ParakeetModelVariant.swift:14-31, 46-55](../../.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Streaming/ParakeetModelVariant.swift#L14)). TDT is explicitly excluded from this protocol (:7-9). Adopting these means a second ~model download and an engine whose accuracy we have never corpus-tested — out of scope for this design.
2. **`SlidingWindowAsrManager` (actor) — the TDT streaming path.** Wraps the same batch `AsrManager`/`AsrModels` we already load (`loadModels(_ models: AsrModels)` accepts pre-loaded models, [SlidingWindowAsrManager.swift:140-148](../../.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift#L140) — so it shares our `ParakeetModelManager` cache, no extra download). Session API: `startStreaming()` (:156), push `streamAudio(AVAudioPCMBuffer)` (:212, any format, resampled internally), consume `transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>` (:217) with two-tier `volatile`/`confirmed` text + confidence (:41-42, :803-825), then `finish() -> String` (:231) / `reset()` (:271) / `cleanup()` (:295). Decoder state and accumulated tokens persist across windows via `transcribeChunk(_, decoderState:, previousTokens:, isLastChunk:)` (:416-421) so each sample is **encoded once**, unlike our re-transcribe-everything poll.
   - **Latency structure:** a window is processed only once `chunk + rightContext` samples exist past the window start (:330). Defaults are 15s chunk/2s right (:699-706); the `.streaming` preset is 11s/2s (:711-718) — i.e. **first partial after 13s of speech**. Getting dictation-grade partial latency requires a custom config (e.g. 2s chunk / 2s right → first partial ~4s, then every 2s), whose accuracy on short windows is unmeasured.
   - **Version-gated caveat:** the config's `hypothesisChunkSeconds` "quick hypothesis" track (:682, :713) is **not wired into the 0.15.1 processing loop** — it appears only in config plumbing and the CLI. A future FluidAudio bump may land the dual-track (fast volatile + slow confirmed) design; that would change the calculus below in favor of the session path.
   - v2 needs `tdtConfig` passed explicitly (blankId 1024 vs v3's 8192 default, :693-696).
   - Bonus (not this design): `configureVocabularyBoosting` (:86-116) — the native-biasing goal from the 06-24 migration plan lives on this same manager, so the session path is shared infrastructure with that effort.

## Design

### Recommended: Phase 1 — polled batch preview (ship this)

Make `ParakeetEngine` conform to the **existing** streaming contract by doing exactly what whisper does per tick — one batch inference over the supplied buffer:

- `supportsStreaming` → `true` **when the streaming-preview flag is on** (see flags below); `transcribeStreaming` = `core.transcribe(samples:language:)` (same pad, same teardown/`active` discipline, [ParakeetEngine.swift:154-196](../../Sources/SpeakFreeLib/ParakeetEngine.swift#L154)), invoking `onPartialResult` once with the result before returning. AppDelegate also consumes the returned value ([AppDelegate.swift:1217-1223](../../Sources/SpeakFreeLib/AppDelegate.swift#L1217)), so a single callback is contract-sufficient; no mid-inference partials exist in TDT batch anyway.
- **Keep the trailing-silence pad in streaming passes.** Without the 3s flush pad the TDT decoder silently drops the tail clause ([ParakeetEngine.swift:30-33, 163-176](../../Sources/SpeakFreeLib/ParakeetEngine.swift#L30)); padded, the preview shows the words just spoken instead of lagging a clause behind. The pad is silence — near-free on ANE (~110ms encoder cost, flat with length).
- `prompt`/`suppressRegex` remain ignored (no Parakeet equivalent; already documented at [ParakeetEngine.swift:295-296](../../Sources/SpeakFreeLib/ParakeetEngine.swift#L295)). Parakeet auto-punctuates, which is exactly what `StreamingTextAssembler`'s `.!?` commit rule wants — no assembler changes.
- **Zero AppDelegate changes** beyond flag plumbing: timer, generation token, one-in-flight gate, overlay, and reuse bookkeeping all work unchanged because the contract shape is identical to whisper's.

Why this over the session manager first:
1. **Cost is fine at dictation lengths.** Batch is ~110ms for ≤15s audio; FluidAudio auto-chunks past the 240k-sample cap, so a 60s dictation costs ~4×110ms per tick — still well under the 2s interval. The re-encode-everything inefficiency only bites on very long dictations (bounded, measurable, see harness gate).
2. **The session path's 0.15.1 latency structure is wrong for dictation** (first partial at `chunk+right`; no quick-hypothesis track — see above). Fixing it means unvalidated small-window configs or waiting for an upstream bump.
3. **Minimal diff, maximal reuse** of battle-tested stabilization/generation machinery; nothing new to teardown-audit.

### Phase 2 (deferred, evidence-gated) — `SlidingWindowAsrManager` session

If Phase 1 measurement shows unacceptable per-tick cost growth on long dictations, ANE energy issues, or an upstream FluidAudio bump lands the dual-track hypothesis path: add a session-based seam. Sketch: `Core` owns an optional `SlidingWindowAsrManager` built from the same `AsrModels`; on each `transcribeStreaming` call, feed only the **delta** samples (buffer beyond what was already streamed, wrapped in an `AVAudioPCMBuffer`) and return `confirmed + volatile`; recording-stop tears the session down via `cancel()`/`reset()`. The `volatile`/`confirmed` two-tier maps naturally onto `StreamingTextAssembler`'s committed/volatile model — possibly replacing it for Parakeet. This inherits the teardown/drain discipline requirements (gate + drain before `cleanup()`, [ParakeetEngine.swift:129-142, 200-214](../../Sources/SpeakFreeLib/ParakeetEngine.swift#L129)). Not planned in detail here; it needs its own measurement round.

### Finalization strategy

**The final text always comes from the existing batch pass on the full buffer** (prompt-primed, VAD-trimmed, TextPipeline'd, 3s pad). The streaming hypothesis is preview-only. This is the direct lesson of the T2.3/AR-2 reuse experiment: the preview path lacks prompt priming and VAD trim, and measured ~5% word divergence against the final pass ([AppDelegate.swift:968-976](../../Sources/SpeakFreeLib/AppDelegate.swift#L968)). `StreamingReuse` stays DEFAULT OFF for Parakeet exactly as for whisper; the reuse bookkeeping keeps recording state so a future measurement could revisit (see DECISION 4). Note the latency picture that motivated reuse is different here: Parakeet's final pass is ~110ms, so there is almost nothing to save by reusing a partial.

### Error / fallback behavior — never silent

- A failed streaming tick is already non-fatal: logged via `DiagnosticLogger`, in-flight flag cleared, next tick proceeds ([AppDelegate.swift:1235-1240](../../Sources/SpeakFreeLib/AppDelegate.swift#L1235)). Final pass is unaffected by any preview failure. Keep this.
- Per the 2026-06-11 postmortem directive (no silent fallback — see the no-silent-fallback rule referenced at [AppDelegate.swift:1285-1288](../../Sources/SpeakFreeLib/AppDelegate.swift#L1285) and [memory/project_dictation_collapse_2026_06_11.md]): a streaming failure must **never** swap engines, models, or degrade the final path. If N consecutive ticks fail (N=3), stop the timer for the remainder of the recording and log loudly; do not disable the config flag behind the user's back.
- `TdtDecoderState` is fresh per pass (built per call, [ParakeetEngine.swift:183-184](../../Sources/SpeakFreeLib/ParakeetEngine.swift#L183)), so a bad tick cannot poison later ticks or the final pass.

### Memory / ANE lifecycle

Phase 1 adds no lifecycle surface: streaming passes go through the same `Core.transcribe` (`tearingDown` gate + `active` counter), so unload/model-swap safety is inherited — a mid-recording engine swap already snapshots the transcriber per tick ([AppDelegate.swift:1181-1188](../../Sources/SpeakFreeLib/AppDelegate.swift#L1181)). Model warmup is the existing `keepModelLoaded` policy; the first tick fires ≥1s into recording, by which point the record-start load path has completed or the tick simply errors non-fatally. No second `AsrManager`, no extra CoreML residency. (Phase 2 would add one lightweight `AsrManager` wrapper inside `SlidingWindowAsrManager` sharing the same `AsrModels` — bounded, but it is the main new lifecycle audit item there.)

## Test & rollout plan

1. **Unit seams** (headless, no real engine): flag→`supportsStreaming` gating; `transcribeStreaming` fires exactly one partial equal to the return value (fake engine); N-consecutive-failure timer stop; existing `StreamingTextAssembler` tests already cover display stabilization. Respect worktree/test safety rules (Config.configDirOverride seam; never touch live config — [memory/project_worktree_and_test_safety.md]).
2. **PerfHarness gates** ([Sources/PerfHarness](../../Sources/PerfHarness)):
   - Extend the `divergence` subcommand ([main.swift:203](../../Sources/PerfHarness/main.swift#L203), [Divergence.swift:22](../../Sources/PerfHarness/Divergence.swift#L22)) to measure Parakeet preview-final divergence over the golden fixtures — expectation: preview is cosmetic, so this is informational, not a ship gate (final text is untouched by construction).
   - **Tick-cost benchmark** (new or via `benchmark`): per-tick latency at 5/15/30/60/120s buffer lengths. Ship gate: p95 tick cost < tick interval at 60s; no final-pass regression vs the existing baseline fingerprint.
3. **Dogfood via SpeakFree Streaming.app**: `scripts/install-streaming.sh` (branch) installs the side-by-side app with isolated config (`~/.config/speakfree-streaming`) — streaming flag ON there, production untouched. Michael dictates on it for real work; watch DiagnosticLogger for tick failures/truncation.
4. **Flag strategy:** new `parakeetStreamingPreview: FlexBool?` alongside `streamingEnabled`/`reuseStreamingPartial` ([Config.swift:23-27](../../Sources/SpeakFreeLib/Config.swift#L23)). Default **OFF** on main; seeded **ON** in the streaming app's config by `install-streaming.sh`. Both flags must be true for Parakeet preview (whisper behavior unchanged).
5. **Ship criteria:** full suite green (482 tests); perf gates above; ≥1 week dogfood with no tail-truncation or overlay regressions; then flip the default ON in a release and delete the flag one release later (or keep as kill-switch — see DECISION 6).

## DECISION NEEDED (Michael)

1. **Preview UX parity vs simplified.** Recommended: full parity (same overlay, same sentence-commit behavior — falls out of the design for free). Alternative: a simpler tail-only preview if the committed/volatile display feels wrong with Parakeet's punctuation cadence. Decide after first dogfood, not before.
2. **Tick cadence / latency target.** Whisper uses 2.0s ticks; Parakeet's ~110ms pass could support 1.0s (snappier preview, ~2× ANE duty cycle). Recommend measuring both in the streaming app and picking by feel + energy numbers.
3. **v2-only or v2+v3.** v2 (English, product default) is the validated target. v3 works through the same code path (language hint per pass) but its preview quality is unmeasured. Recommend: enable for both, corpus-check v2 only, note v3 as best-effort.
4. **Final text source.** Recommended and assumed above: always batch re-pass (quality; reuse saves only ~110ms here). Alternative: revive a StreamingReuse-style gate for Parakeet if a valid measurement ever clears the <1% divergence bar. History says don't — confirm this is settled.
5. **Phase 2 trigger.** Is the sliding-window session worth pursuing proactively (shared infra with the vocabulary-biasing migration), or strictly if Phase 1 fails its perf gates / FluidAudio ships the dual-track hypothesis path?
6. **Rollout endpoint.** After dogfood: flip prod default ON in which release, and does the flag stay as a permanent kill-switch or get removed?

## Effort

| Piece | Size |
|---|---|
| Phase 1 engine change (flag-gated `supportsStreaming` + `transcribeStreaming` via `core.transcribe`) | S |
| Config flag + AppDelegate/settings plumbing | S |
| Unit tests (fake-engine seams, failure-stop) | S |
| PerfHarness tick-cost benchmark + Parakeet divergence extension | M |
| Dogfood round on SpeakFree Streaming.app + tuning (cadence, N-failure stop) | M |
| Release (flag flip, docs, appcast) | S |
| Phase 2 session engine (deferred) | L |

---
_Claude · 2026-07-01 · Session: f2070c71-48d2-4d03-8ed9-c08a87a52eb5_
