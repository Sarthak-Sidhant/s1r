#!/bin/bash

# Test box extraction with adjustable parameters
INPUT_IMAGE="$1"
OUTPUT_DIR="/tmp/box-test"

if [ -z "$INPUT_IMAGE" ]; then
    echo "Usage: $0 <input_image>"
    exit 1
fi

# Updated parameters based on precise measurements
GRID_COLS=3
GRID_ROWS=10
RECORD_WIDTH=298
RECORD_HEIGHT=121
START_X=22  # Horizontal page margin
START_Y=42  # Vertical page margin
GAP_X=5     # Horizontal gap between boxes
GAP_Y=5     # Vertical gap between boxes

echo "Extracting test boxes with updated parameters:"
echo "  Grid: ${GRID_COLS}x${GRID_ROWS}"
echo "  Box size: ${RECORD_WIDTH}x${RECORD_HEIGHT}"
echo "  Start position: (${START_X}, ${START_Y})"
echo "  Gaps: ${GAP_X}px horizontal, ${GAP_Y}px vertical"

rm -rf "$OUTPUT_DIR"/*

# Extract just the first few records for testing
for row in $(seq 0 2); do  # First 3 rows
    for col in $(seq 0 2); do  # All 3 columns
        RECORD_NUM=$((row * GRID_COLS + col))
        RECORD_ID=$(printf "%02d" $RECORD_NUM)
        
        X=$((START_X + col * (RECORD_WIDTH + GAP_X)))
        Y=$((START_Y + row * (RECORD_HEIGHT + GAP_Y)))
        
        echo "Record ${RECORD_ID}: (${X}, ${Y}) ${RECORD_WIDTH}x${RECORD_HEIGHT}"
        
        convert "$INPUT_IMAGE" -crop "${RECORD_WIDTH}x${RECORD_HEIGHT}+${X}+${Y}" \
                "$OUTPUT_DIR/record_${RECORD_ID}.png" 2>/dev/null
    done
done

echo "Extracted boxes to $OUTPUT_DIR"
echo "Check them with: ls -la $OUTPUT_DIR"