#!/bin/bash
# Benchmark whisper-cli: model load time, inference time, peak memory per model
# Usage: ./benchmark.sh [audio_file]
#
# If no audio file provided, generates a 5-second test tone.

set -euo pipefail

WHISPER="/opt/homebrew/bin/whisper-cli"
MODELS_DIR="$HOME/.config/speakfree/models"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_FILE="$SCRIPT_DIR/results.md"

# Models to benchmark (in order of size)
MODELS=(
    "tiny.en"
    "base.en"
    "small.en"
    "medium.en"
    "large-v3"
)

# Generate test audio if none provided
if [ -n "${1:-}" ] && [ -f "$1" ]; then
    AUDIO_FILE="$1"
    echo "Using provided audio: $AUDIO_FILE"
else
    AUDIO_FILE="$SCRIPT_DIR/test_audio.wav"
    if [ ! -f "$AUDIO_FILE" ]; then
        echo "Generating 10-second test audio (speech-like tone)..."
        # Generate 10 seconds of varied tones to simulate speech-length audio
        sox -n -r 16000 -c 1 -b 16 "$AUDIO_FILE" \
            synth 10 sine 200:800 vol 0.3 \
            2>/dev/null || {
            # Fallback if sox not available: use say + afconvert
            echo "sox not found, using macOS say command..."
            SAY_TMP="$SCRIPT_DIR/test_say.aiff"
            say -o "$SAY_TMP" "This is a test of the whisper speech recognition system. The quick brown fox jumps over the lazy dog. Testing one two three four five six seven eight nine ten."
            afconvert -f WAVE -d LEI16@16000 -c 1 "$SAY_TMP" "$AUDIO_FILE"
            rm -f "$SAY_TMP"
        }
    fi
    echo "Using test audio: $AUDIO_FILE"
fi

AUDIO_DURATION=$(afinfo "$AUDIO_FILE" 2>/dev/null | grep "estimated duration" | awk '{print $3}' || echo "unknown")
echo "Audio duration: ${AUDIO_DURATION}s"
echo ""

# Header
cat > "$RESULTS_FILE" <<EOF
# Whisper Model Benchmark Results

**Date:** $(date "+%Y-%m-%d %H:%M")
**Machine:** $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
**RAM:** $(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $1/1024/1024/1024}')
**Audio:** ${AUDIO_DURATION}s test clip
**Whisper:** $($WHISPER --version 2>&1 | head -1 || echo "unknown version")

| Model | Disk Size | Peak RSS (MB) | Load+Inference (s) | Run 2 (cached) (s) | Run 3 (s) | Transcript |
|-------|-----------|---------------|--------------------|--------------------|-----------|------------|
EOF

echo "=== Whisper Model Benchmark ==="
echo ""

for model in "${MODELS[@]}"; do
    MODEL_PATH="$MODELS_DIR/ggml-${model}.bin"

    if [ ! -f "$MODEL_PATH" ]; then
        echo "SKIP: $model (not downloaded)"
        echo "| $model | - | - | - | - | - | (not downloaded) |" >> "$RESULTS_FILE"
        continue
    fi

    DISK_SIZE=$(ls -lh "$MODEL_PATH" | awk '{print $5}')
    echo "--- Benchmarking: $model ($DISK_SIZE) ---"

    # Clear OS disk cache as much as possible for cold run
    # (purge requires sudo, so we just accept warm-ish cache)

    TIMES=()
    PEAK_RSS=0
    TRANSCRIPT=""

    for run in 1 2 3; do
        # Use /usr/bin/time for memory measurement (RSS)
        TIME_OUTPUT=$( { /usr/bin/time -l "$WHISPER" \
            -m "$MODEL_PATH" \
            -f "$AUDIO_FILE" \
            -l en \
            --no-timestamps \
            -nt \
            2>&1 1>"$SCRIPT_DIR/transcript_tmp.txt"; } 2>&1 )

        # Extract wall clock time from /usr/bin/time output
        # Format: "X.XX real ..." or "        X.XX real"
        WALL_TIME=$(echo "$TIME_OUTPUT" | grep "real" | awk '{print $1}' | head -1)

        # Extract peak RSS (in bytes on macOS, reported as "maximum resident set size")
        RSS_BYTES=$(echo "$TIME_OUTPUT" | grep "maximum resident set size" | awk '{print $1}')
        RSS_MB=$(echo "$RSS_BYTES" | awk '{printf "%.0f", $1/1048576}')

        if [ "$run" -eq 1 ]; then
            PEAK_RSS="$RSS_MB"
            TRANSCRIPT=$(cat "$SCRIPT_DIR/transcript_tmp.txt" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-80)
        fi

        # Track higher RSS if seen
        if [ -n "$RSS_MB" ] && [ "$RSS_MB" -gt "$PEAK_RSS" ] 2>/dev/null; then
            PEAK_RSS="$RSS_MB"
        fi

        TIMES+=("$WALL_TIME")
        echo "  Run $run: ${WALL_TIME}s (RSS: ${RSS_MB}MB)"
    done

    echo "| $model | $DISK_SIZE | $PEAK_RSS | ${TIMES[0]} | ${TIMES[1]} | ${TIMES[2]} | ${TRANSCRIPT:0:50}... |" >> "$RESULTS_FILE"
    echo ""
done

rm -f "$SCRIPT_DIR/transcript_tmp.txt"

echo ""
echo "=== Results saved to $RESULTS_FILE ==="
echo ""
cat "$RESULTS_FILE"
