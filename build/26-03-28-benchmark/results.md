# Whisper Model Benchmark Results

**Date:** 2026-03-28 03:06
**Machine:** Apple M3 Max
**RAM:** 64 GB
**Audio:** 10.277313s test clip
**Whisper:** error: unknown argument: --version

| Model | Disk Size | Peak RSS (MB) | Load+Inference (s) | Run 2 (cached) (s) | Run 3 (s) | Transcript |
|-------|-----------|---------------|--------------------|--------------------|-----------|------------|
| tiny.en | 74M | 232 | 7.75 | 0.58 | 0.58 |  This is a test of the whisper speech recognition ... |
| base.en | 141M | 331 | 0.60 | 0.59 | 0.59 |  This is a test of the whisper speech recognition ... |
| small.en | 465M | 807 | 1.09 | 0.59 | 0.59 |  This is a test of the Whisper Speech Recognition ... |
| medium.en | 1.4G | 2135 | 1.59 | 1.60 | 1.11 |  This is a test of the whisper speech recognition ... |
| large-v3 | 2.9G | 3982 | 2.61 | 2.10 | 2.10 |  This is a test of the whisper speech recognition ... |
