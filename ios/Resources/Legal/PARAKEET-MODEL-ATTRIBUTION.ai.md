<!-- ai-processed:unverified | session:01a00cac-80fe-7e81-ad7f-32c2599da24d | date:2026-08-16 | asof:2026-08-16 -->

# NVIDIA Parakeet speech models

## Parakeet Realtime EOU 120M v1

SpeakFree uses a Core ML conversion for low-latency, revisable preview text:

- Original model: https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1
- Core ML conversion: https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml
- License: NVIDIA Open Model License
- License terms: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/

FluidInference converted the model for Core ML. SpeakFree downloads that conversion and runs it
locally; SpeakFree does not modify the downloaded weights.

## Parakeet TDT 0.6B v2

SpeakFree downloads a Core ML conversion of NVIDIA’s Parakeet TDT 0.6B v2 model:

- Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- Core ML conversion: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- License text: https://creativecommons.org/licenses/by/4.0/legalcode

FluidInference converted the model for Core ML. SpeakFree
downloads that conversion and runs it locally; SpeakFree does not modify the downloaded weights.
