#!/bin/bash

# Fixed-coordinate OCR for standardized voter register layout
# Uses known positions since all government forms are identical

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
mkdir -p "$BOXES_DIR" "$OCR_DIR"

echo -e "${CYAN}Processing ${IMAGE_NAME} with fixed coordinates...${RESET}"

# Fixed layout for Indian voter register - based on precise measurements
# 30 records in 10 rows x 3 columns
GRID_COLS=3
GRID_ROWS=10
RECORD_WIDTH=298
RECORD_HEIGHT=121
START_X=22  # Horizontal page margin
START_Y=42  # Vertical page margin
GAP_X=5     # Horizontal gap between boxes
GAP_Y=5     # Vertical gap between boxes

VALID_RECORDS=0
TOTAL_RECORDS=$((GRID_COLS * GRID_ROWS))
WORK_DIR="$OUTPUT_DIR/work"
mkdir -p "$WORK_DIR"

# Initialize batch file lists
> "$WORK_DIR/serial_files.txt"
> "$WORK_DIR/epic_files.txt" 
> "$WORK_DIR/text_files.txt"

echo -e "${CYAN}Step 1: Extracting all regions...${RESET}"

for row in $(seq 0 $((GRID_ROWS - 1))); do
    for col in $(seq 0 $((GRID_COLS - 1))); do
        RECORD_NUM=$((row * GRID_COLS + col))
        RECORD_ID=$(printf "%02d" $RECORD_NUM)
        
        # Calculate position with gaps
        X=$((START_X + col * (RECORD_WIDTH + GAP_X)))
        Y=$((START_Y + row * (RECORD_HEIGHT + GAP_Y)))
        
        # Extract the full record box
        convert "$INPUT_IMAGE" -crop "${RECORD_WIDTH}x${RECORD_HEIGHT}+${X}+${Y}" \
                "$BOXES_DIR/record_${RECORD_ID}.png" 2>/dev/null
        
        # Extract specific regions based on precise measurements:
        # Serial number: first 150 pixels of top 25 pixel strip
        convert "$BOXES_DIR/record_${RECORD_ID}.png" -crop "150x25+0+0" \
                "$BOXES_DIR/record_${RECORD_ID}_serial.png" 2>/dev/null
        
        # EPIC ID: from pixel 200 onwards of top 25 pixel strip (98 pixels wide)
        convert "$BOXES_DIR/record_${RECORD_ID}.png" -crop "98x25+200+0" \
                "$BOXES_DIR/record_${RECORD_ID}_epic.png" 2>/dev/null
        
        # Hindi text: underneath, 220 pixels wide and 90 pixels tall
        convert "$BOXES_DIR/record_${RECORD_ID}.png" -crop "220x90+0+25" \
                "$BOXES_DIR/record_${RECORD_ID}_text.png" 2>/dev/null
        
        # Store region files for batch OCR later
        echo "$BOXES_DIR/record_${RECORD_ID}_serial.png" >> "$WORK_DIR/serial_files.txt"
        echo "$BOXES_DIR/record_${RECORD_ID}_epic.png" >> "$WORK_DIR/epic_files.txt" 
        echo "$BOXES_DIR/record_${RECORD_ID}_text.png" >> "$WORK_DIR/text_files.txt"
    done
done

echo -e "${CYAN}Step 2: Running batch OCR...${RESET}"

# Batch OCR processing - much faster than individual calls
echo "Processing serial numbers..."
cat "$WORK_DIR/serial_files.txt" | while read img_file; do
    record_id=$(basename "$img_file" _serial.png | sed 's/^record_//')
    tesseract "$img_file" "$OCR_DIR/record_${record_id}_serial" \
        -l eng --oem 1 --psm 8 \
        -c tessedit_char_whitelist=0123456789 \
        quiet 2>/dev/null || echo "FAILED" > "$OCR_DIR/record_${record_id}_serial.txt"
done &

echo "Processing EPIC IDs..."
cat "$WORK_DIR/epic_files.txt" | while read img_file; do
    record_id=$(basename "$img_file" _epic.png | sed 's/^record_//')
    tesseract "$img_file" "$OCR_DIR/record_${record_id}_epic" \
        -l eng --oem 1 --psm 8 \
        -c tessedit_char_whitelist=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \
        quiet 2>/dev/null || echo "FAILED" > "$OCR_DIR/record_${record_id}_epic.txt"
done &

echo "Processing Hindi text..."
cat "$WORK_DIR/text_files.txt" | while read img_file; do
    record_id=$(basename "$img_file" _text.png | sed 's/^record_//')
    # Preprocess for better Hindi OCR
    processed_img="${img_file%.png}_processed.png"
    convert "$img_file" -colorspace gray -normalize -threshold 70% "$processed_img" 2>/dev/null
    tesseract "$processed_img" "$OCR_DIR/record_${record_id}_text" \
        -l hin+eng --oem 1 --psm 6 \
        quiet 2>/dev/null || echo "FAILED" > "$OCR_DIR/record_${record_id}_text.txt"
    rm -f "$processed_img"
done &

# Wait for all background jobs to complete
wait

echo -e "${CYAN}Step 3: Validating results...${RESET}"

# Now validate all records
for record_num in $(seq 0 $((TOTAL_RECORDS - 1))); do
    RECORD_ID=$(printf "%02d" $record_num)
    
    SERIAL=$(cat "$OCR_DIR/record_${RECORD_ID}_serial.txt" 2>/dev/null | tr -d '\n\r' || echo "")
    EPIC=$(cat "$OCR_DIR/record_${RECORD_ID}_epic.txt" 2>/dev/null | tr -d '\n\r' || echo "")
    TEXT=$(cat "$OCR_DIR/record_${RECORD_ID}_text.txt" 2>/dev/null || echo "")
    
    if [[ ${#SERIAL} -ge 1 && ${#EPIC} -ge 6 && ${#TEXT} -ge 20 ]]; then
        echo "VALID" > "$OCR_DIR/record_${RECORD_ID}.status"
        VALID_RECORDS=$((VALID_RECORDS + 1))
    else
        echo "INSUFFICIENT_DATA" > "$OCR_DIR/record_${RECORD_ID}.status"
    fi
done

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