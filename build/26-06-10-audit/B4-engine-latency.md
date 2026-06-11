<!-- ai:processed | session: 5b06900b-1498-4764-a786-48f408c36626 | date: 2026-06-10 -->
# B4 — Engine latency: Whisper vs Parakeet (local measurement)

Companion to [PLAN.md](PLAN.md) PERF-BRAINSTORM **B4 engine auto-select**. Produced by the T2.0
perf-regression harness (`swift run perf-harness run --engines whisper,parakeet`) over the three
tracked audio golden fixtures. This is the measurable-latency input to Michael's open B4 decision
(Parakeet/ANE is faster for English; cost = no live preview).

**A Parakeet model WAS on disk locally**, so this was measurable without any download:
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/` (full Encoder/Decoder/
Joint/Preprocessor `.mlmodelc` set + vocab).

## Machine / run

- **Machine:** Apple M3 Max · 16 cores · arm64 · macOS 26.0 (25A354)
- **Iterations:** 7 timed per fixture (1 warm-up discarded), medians reported
- **Fixtures:** the 3 AudioGoldenTests WAVs (~9–11 s of real dictation each)
- **Whisper model:** `tiny.en` (`ggml-tiny.en.bin`) — the CI/baseline model
- **Parakeet model:** `parakeet-tdt-0.6b-v3`
- Source report: [b4-both-engines.json](../26-06-10-perf-harness/b4-both-engines.json)

## Results — median latency (ms)

| fixture | audio | whisper infer(med) | whisper e2e(med) | parakeet infer(med) | parakeet e2e(med) |
|---|---|---|---|---|---|
| fixture-1-clean.wav | 11.1s | 629.9 | 930.6 | 184.4 | 485.2 |
| fixture-2-spoken-comma.wav | 9.4s | 632.8 | 934.7 | 180.3 | 481.1 |
| fixture-3-spoken-period-end.wav | 11.0s | 621.2 | 921.9 | 177.5 | 478.3 |
| **median of medians** | — | **629.9** | **930.6** | **180.3** | **481.1** |

- `infer` = engine inference wall-clock only.
- `e2e` = simulated key-release → text-ready = flat post-buffer (300 ms today) + inference +
  TextPipeline post-processing.

**Headline:** Parakeet v3 is **~3.5× faster on inference** (180 ms vs 630 ms median) and **~1.9×
faster end-to-end** (481 ms vs 931 ms median) on this machine for these clips. The e2e gap is
smaller than the inference gap because the flat 300 ms post-buffer is a fixed tax on both engines
(it dominates Parakeet's e2e — see T2.1 adaptive-post-buffer, which would help Parakeet most).

## Methodology caveats (read before acting on these numbers)

1. **NOT a pure apples-to-apples inference comparison.** Whisper's in-process ggml/Metal backend
   aborts outside the GUI-app process (`devices=0` → `GGML_ABORT`), exactly as `ProcessCommand`
   documents. So the harness drives whisper through the **`whisper-cli` subprocess** (the same
   production fallback the golden tests use), which **reloads `tiny.en` from disk and spawns a
   process on every call**. Parakeet runs **in-process on the ANE with the model kept loaded**.
   The whisper number therefore *includes* subprocess + model-load overhead the in-app whisper
   path would not pay on a warm model. The real in-app whisper inference is faster than 630 ms;
   the true engine gap is smaller than 3.5×. Treat this as a **floor on Parakeet's advantage**,
   not an exact ratio.
2. **Model-size mismatch is intentional but matters.** `tiny.en` is the smallest, fastest whisper
   model. The app's default is larger (`base.en` in the user config; users pick up to `large-v3-turbo`).
   Against a larger whisper model Parakeet's advantage widens substantially.
3. **`tiny.en` vs Parakeet accuracy differ** — this doc measures latency only. B4 is a latency/UX
   tradeoff (Parakeet has no live-preview streaming path; `transcribeStreaming` throws
   `streamingUnsupported`). The accuracy axis is out of scope here.
4. **Single machine, light load.** M3 Max, otherwise-idle. Numbers will differ on Intel / smaller
   Apple Silicon and under load. The harness fingerprints the machine so a baseline is only ever
   compared like-for-like.

## What to run later for a cleaner comparison

- Re-measure whisper **in-process, warm** from inside the GUI app (or a test host where the Metal
  device initializes) to remove the CLI subprocess + reload tax — that yields the true in-app
  whisper inference latency for an honest engine-vs-engine ratio.
- Repeat against the **shipping default whisper model** (`base.en` / `large-v3-turbo`), not just
  `tiny.en`, to size the advantage at the quality level users actually run.
- Layer in **accuracy** (corpus WER) so B4 is decided on latency *and* accuracy, not latency alone.

**Bottom line for B4:** On-disk Parakeet v3 is materially faster than whisper here even with the
methodology handicap stacked against it — a real latency win, at the cost of the live-preview
overlay. The decision (auto-select Parakeet in some/all modes) is Michael's; this gives the
measured latency side of it.

---
_Claude · 2026-06-10 · Session: 5b06900b-1498-4764-a786-48f408c36626_
