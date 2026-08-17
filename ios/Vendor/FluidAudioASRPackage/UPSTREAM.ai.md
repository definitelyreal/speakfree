<!-- ai-processed:unverified | session:01a00cac-80fe-7e81-ad7f-32c2599da24d | date:2026-08-17 | asof:2026-08-17 -->

# FluidAudio ASR vendor provenance

This package vendors FluidAudio revision `e8bd3a205fb8ecef926f7747499d184cbb6d0cc6`, distributed under Apache-2.0.

The upstream source trees are preserved except for `TTS/Shared/NemoTextNormalizer.swift`, which is an identity stub. SpeakFree does not use FluidAudio TTS; omitting the unused native NeMo binary avoids its generic `module.modulemap` colliding with ExecuTorch during a combined iOS archive.

SpeakFree additionally pins the EOU and Parakeet-v2 Hugging Face download URLs/tree listings to immutable repository commits in `ModelRegistry.swift`; upstream follows mutable `main`.

SpeakFree uses only the Parakeet ASR APIs. Model weights are downloaded separately and retain their own upstream licenses.
