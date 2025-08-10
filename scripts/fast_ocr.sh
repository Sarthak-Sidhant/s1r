#!/bin/bash

# Fast parallel OCR for voter register pages
# Uses multiprocessing to OCR all regions simultaneously

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

if [ $# -lt 2 ]; then
    echo "Usage: $0 <input_image> <output_dir>"
    exit 1
fi

INPUT_IMAGE="$1"
OUTPUT_DIR="$2"
IMAGE_NAME=$(basename "$INPUT_IMAGE" .png)

# Create output directories
BOXES_DIR="$OUTPUT_DIR/boxes/${IMAGE_NAME}"
OCR_DIR="$OUTPUT_DIR/ocr/${IMAGE_NAME}"
WORK_DIR="$OUTPUT_DIR/work"
mkdir -p "$BOXES_DIR" "$OCR_DIR" "$WORK_DIR"

echo -e "${CYAN}Fast OCR processing for ${IMAGE_NAME}...${RESET}"

# Precise measurements for Indian voter register
GRID_COLS=3
GRID_ROWS=10
RECORD_WIDTH=298
RECORD_HEIGHT=121
START_X=22
START_Y=42
GAP_X=5
GAP_Y=5

TOTAL_RECORDS=$((GRID_COLS * GRID_ROWS))
PARALLEL_JOBS=$(nproc)

echo "Extracting ${TOTAL_RECORDS} records and running OCR with ${PARALLEL_JOBS} parallel jobs..."

# Function to process a single record (extract regions + OCR)
process_record() {
    local row=$1
    local col=$2
    local record_num=$((row * 3 + col))
    local record_id=$(printf "%02d" $record_num)
    
    # Calculate position
    local x=$((START_X + col * (RECORD_WIDTH + GAP_X)))
    local y=$((START_Y + row * (RECORD_HEIGHT + GAP_Y)))
    
    # Extract full record
    convert "$INPUT_IMAGE" -crop "${RECORD_WIDTH}x${RECORD_HEIGHT}+${x}+${y}" \
            "$BOXES_DIR/record_${record_id}.png" 2>/dev/null
    
    # Extract regions
    convert "$BOXES_DIR/record_${record_id}.png" -crop "150x25+0+0" \
            "$BOXES_DIR/record_${record_id}_serial.png" 2>/dev/null
    
    convert "$BOXES_DIR/record_${record_id}.png" -crop "98x25+200+0" \
            "$BOXES_DIR/record_${record_id}_epic.png" 2>/dev/null
    
    convert "$BOXES_DIR/record_${record_id}.png" -crop "220x90+0+25" \
            "$BOXES_DIR/record_${record_id}_text.png" 2>/dev/null
    
    # OCR each region immediately
    # Serial (digits)
    tesseract "$BOXES_DIR/record_${record_id}_serial.png" \
              "$OCR_DIR/record_${record_id}_serial" \
              -l eng --oem 1 --psm 8 \
              -c tessedit_char_whitelist=0123456789 \
              quiet 2>/dev/null || echo "FAILED" > "$OCR_DIR/record_${record_id}_serial.txt"
    
    # EPIC (alphanumeric)
    tesseract "$BOXES_DIR/record_${record_id}_epic.png" \
              "$OCR_DIR/record_${record_id}_epic" \
              -l eng --oem 1 --psm 8 \
              -c tessedit_char_whitelist=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \
              quiet 2>/dev/null || echo "FAILED" > "$OCR_DIR/record_${record_id}_epic.txt"
    
    # Hindi text
    local processed_text="$BOXES_DIR/record_${record_id}_text_processed.png"
    convert "$BOXES_DIR/record_${record_id}_text.png" \
            -colorspace gray -normalize -threshold 70% \
            "$processed_text" 2>/dev/null
    
    tesseract "$processed_text" \
              "$OCR_DIR/record_${record_id}_text" \
              -l hin+eng --oem 1 --psm 6 \
              quiet 2>/dev/null || echo "FAILED" > "$OCR_DIR/record_${record_id}_text.txt"
    
    rm -f "$processed_text"
    
    # Quick validation
    local serial=$(cat "$OCR_DIR/record_${record_id}_serial.txt" 2>/dev/null | tr -d '\n\r' || echo "")
    local epic=$(cat "$OCR_DIR/record_${record_id}_epic.txt" 2>/dev/null | tr -d '\n\r' || echo "")  
    local text=$(cat "$OCR_DIR/record_${record_id}_text.txt" 2>/dev/null || echo "")
    
    if [[ ${#serial} -ge 1 && ${#epic} -ge 6 && ${#text} -ge 20 ]]; then
        echo "VALID" > "$OCR_DIR/record_${record_id}.status"
        echo "Record ${record_id}: VALID"
    else
        echo "INSUFFICIENT_DATA" > "$OCR_DIR/record_${record_id}.status"
        echo "Record ${record_id}: INSUFFICIENT (S:${#serial}, E:${#epic}, T:${#text})"
    fi
}

# Export function and variables for parallel execution
export -f process_record
export INPUT_IMAGE BOXES_DIR OCR_DIR START_X START_Y RECORD_WIDTH RECORD_HEIGHT GAP_X GAP_Y

# Generate all row,col combinations and process in parallel
{
    for row in $(seq 0 $((GRID_ROWS - 1))); do
        for col in $(seq 0 $((GRID_COLS - 1))); do
            echo "$row $col"
        done
    done
} | if command -v parallel &>/dev/null && parallel --version 2>/dev/null | grep -q GNU; then
    # Use GNU parallel
    parallel -j "$PARALLEL_JOBS" --colsep ' ' process_record {1} {2}
else
    # Fallback to xargs
    xargs -n 2 -P "$PARALLEL_JOBS" bash -c 'process_record "$@"' --
fi

# Count results
VALID_RECORDS=$(ls -1 "$OCR_DIR"/*.status 2>/dev/null | xargs grep -l "VALID" | wc -l)

# Summary
SUMMARY_FILE="$OUTPUT_DIR/summary/${IMAGE_NAME}.json"
mkdir -p "$OUTPUT_DIR/summary"

cat > "$SUMMARY_FILE" <<EOF
{
  "page": "${IMAGE_NAME}",
  "total_records": ${TOTAL_RECORDS},
  "valid_records": ${VALID_RECORDS},
  "invalid_records": $((TOTAL_RECORDS - VALID_RECORDS)),
  "validity_ratio": $(echo "scale=2; $VALID_RECORDS / $TOTAL_RECORDS" | bc)
}
EOF

echo -e "Page ${IMAGE_NAME}: ${GREEN}${VALID_RECORDS}${RESET}/${TOTAL_RECORDS} valid records"

exit 0