#!/bin/bash
# Generate reference audio with macOS TTS, transcribe with whisper, compare.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WHISPER="/opt/homebrew/bin/whisper-cli"
MODELS_DIR="$HOME/.config/speakfree/models"
RESULTS="$SCRIPT_DIR/accuracy-results.md"

# Reference sentences
declare -a SENTENCES=(
    "The quick brown fox jumps over the lazy dog."
    "Hello, my name is Michael and I work in software engineering."
    "Please send the report to the team by Friday at five pm."
    "The weather forecast calls for partly cloudy skies with a high of seventy two degrees."
    "Can you schedule a meeting with Sarah and Tom for next Tuesday?"
    "I need to update the configuration file with the new API endpoint."
    "The restaurant on Main Street has excellent reviews for their pasta dishes."
    "Remember to pick up groceries on the way home, including milk, eggs, and bread."
)

mkdir -p "$SCRIPT_DIR/audio"

echo "# Accuracy Test Results" > "$RESULTS"
echo "" >> "$RESULTS"
echo "**Date:** $(date '+%Y-%m-%d %H:%M')" >> "$RESULTS"
echo "**Machine:** $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')" >> "$RESULTS"
echo "" >> "$RESULTS"

# Generate audio files
echo "Generating reference audio..."
for i in "${!SENTENCES[@]}"; do
    AUDIO="$SCRIPT_DIR/audio/sentence_${i}.wav"
    if [ ! -f "$AUDIO" ]; then
        TMP_AIFF="$SCRIPT_DIR/audio/tmp_${i}.aiff"
        say -o "$TMP_AIFF" "${SENTENCES[$i]}"
        afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP_AIFF" "$AUDIO"
        rm -f "$TMP_AIFF"
    fi
done

# Test each model
for model in "tiny.en" "base.en" "small.en"; do
    MODEL_PATH="$MODELS_DIR/ggml-${model}.bin"
    [ ! -f "$MODEL_PATH" ] && { echo "SKIP: $model (not found at $MODEL_PATH)"; continue; }

    echo "" >> "$RESULTS"
    echo "## Model: $model" >> "$RESULTS"
    echo "" >> "$RESULTS"
    echo "| # | Expected | Got | Match |" >> "$RESULTS"
    echo "|---|----------|-----|-------|" >> "$RESULTS"

    TOTAL=0
    MATCHES=0

    for i in "${!SENTENCES[@]}"; do
        AUDIO="$SCRIPT_DIR/audio/sentence_${i}.wav"
        EXPECTED="${SENTENCES[$i]}"

        # Transcribe
        GOT=$("$WHISPER" -m "$MODEL_PATH" -f "$AUDIO" -l en --no-timestamps -nt 2>/dev/null | tr -d '\n' | sed 's/^ *//' | sed 's/ *$//')

        # Normalize for comparison (lowercase, strip punctuation)
        NORM_EXPECTED=$(echo "$EXPECTED" | tr '[:upper:]' '[:lower:]' | tr -d '.,!?;:')
        NORM_GOT=$(echo "$GOT" | tr '[:upper:]' '[:lower:]' | tr -d '.,!?;:')

        TOTAL=$((TOTAL + 1))
        if [ "$NORM_EXPECTED" = "$NORM_GOT" ]; then
            MATCH="PASS"
            MATCHES=$((MATCHES + 1))
        else
            MATCH="FAIL"
        fi

        # Truncate for table
        GOT_SHORT=$(echo "$GOT" | cut -c1-60)
        EXP_SHORT=$(echo "$EXPECTED" | cut -c1-60)
        echo "| $i | $EXP_SHORT | $GOT_SHORT | $MATCH |" >> "$RESULTS"
    done

    echo "" >> "$RESULTS"
    echo "**Score: $MATCHES/$TOTAL**" >> "$RESULTS"
    echo ""
    echo "$model: $MATCHES/$TOTAL correct"
done

echo "" >> "$RESULTS"
echo "---" >> "$RESULTS"
echo "" >> "$RESULTS"

cat "$RESULTS"
