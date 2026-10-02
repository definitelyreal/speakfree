<!-- ai-suggestion:unverified | session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b | date:2026-10-01 | asof:2026-10-01 -->
# Synthetic speech fixtures

These four WAVs use eSpeak NG English-US formant synthesis and invented test sentences.
No microphone recording, voice clone, personal transcript, or network service is an input.
`manifest.json` records the exact source text, synthesis settings, sample counts, SHA-256
fingerprints and assertions. The text, generator and generated fixtures are provided under
the repository's [MIT license](../../../LICENSE).

| Fixture | Purpose |
|---|---|
| `fixture-1-clean.wav` | A clean sentence with a strong speech tail |
| `fixture-2-spoken-comma.wav` | A three-item list with two spoken comma commands and a strong tail |
| `fixture-3-spoken-period-end.wav` | A final spoken period with a deliberately soft tail |
| `fixture-4-trailing-silence-period.wav` | Exactly fixture 3 followed by 6,400 zero samples (400 ms) |

## Regeneration

Install [eSpeak NG 1.52.0](https://github.com/espeak-ng/espeak-ng/releases/tag/1.52.0),
FFmpeg 8.1, and Python 3, then run from the repository root:

```sh
python3 Tests/SpeakFreeTests/AudioFixtures/regenerate_AI_.py
```

Use `--output /path/to/comparison-directory` to regenerate separately and compare hashes.
The generator pins eSpeak's version, voice (`en-us`), rate, pitch and amplitude.
It resamples to mono 16 kHz signed 16-bit PCM, removes the synthesizer's final pause while
retaining 10 ms after the last sample above its trim threshold, and normalizes amplitude.
The first two tails target a maximum 30 ms-window RMS of 0.06. Fixture 3 normalizes each
non-silent tail window to 0.015. This deliberately exercises the policy's strong/soft bands;
it is not a natural speech distribution. No phoneme samples are shortened by the adaptive
silence test. The canonical WAV writer includes only `fmt` and `data` chunks.

The generation tools are installed separately; their executables, models and source are not
bundled here. eSpeak NG has its own [GPLv3 license](https://github.com/espeak-ng/espeak-ng/blob/1.52.0/COPYING).
FFmpeg licensing depends on its build; see [FFmpeg's license documentation](https://ffmpeg.org/legal.html).
The tool licenses and the generated fixtures' project license describe different artifacts.

## Validation and timing limits

`AudioFixtureProvenanceTests` validates hashes, PCM containers and the exact silence suffix.
`AudioGoldenTests` runs local Whisper tiny.en with fixed English/hybrid settings and no user
vocabulary. `AdaptiveBufferCorpusTests` checks deterministic waits of 1,200 / 1,200 / 220 / 90 ms,
then decodes the full and adaptively shortened silence canary. Its complete speech prefix must
remain sample-identical and the final spoken period must survive.

These synthetic fixtures replace older bytes under the same filenames. **Historical wall-clock
inference and total-latency baselines are not comparable.** No timing ceiling was raised or
recalibrated for this replacement. Existing deterministic policy ceilings remain enforced.
A new quiet-machine timing baseline requires an explicit review; passing a synthetic decode
or a deterministic wait check is not evidence of real-world recognition accuracy or speed.
