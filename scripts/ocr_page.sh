#!/bin/bash

# OCR processing for a single page image
# Splits into 30 tiles (3x10), OCRs each, and validates

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <input_image> <output_dir>"
    echo "Example: $0 page.png output/"
    exit 1
fi

INPUT_IMAGE="$1"
OUTPUT_DIR="$2"
IMAGE_NAME=$(basename "$INPUT_IMAGE" .png)

# Create output directories
TILES_DIR="$OUTPUT_DIR/tiles/${IMAGE_NAME}"
OCR_DIR="$OUTPUT_DIR/ocr/${IMAGE_NAME}"
mkdir -p "$TILES_DIR" "$OCR_DIR"

# Step 1: Split image into 30 tiles (3 columns x 10 rows)
echo -e "${CYAN}Splitting ${IMAGE_NAME} into tiles...${RESET}"

# Use ImageMagick to crop into 3x10 grid
# The @ means divide equally, +repage removes virtual canvas, +adjoin outputs separate files
convert "$INPUT_IMAGE" -crop 3x10@ +repage +adjoin "$TILES_DIR/tile_%02d.png" 2>/dev/null || {
    echo -e "${RED}Failed to split image: $INPUT_IMAGE${RESET}"
    exit 1
}

# Count tiles created
TILE_COUNT=$(ls -1 "$TILES_DIR"/tile_*.png 2>/dev/null | wc -l)
if [ "$TILE_COUNT" -ne 30 ]; then
    echo -e "${YELLOW}Warning: Expected 30 tiles, got $TILE_COUNT${RESET}"
fi

# Step 2: Preprocess and OCR each tile
echo -e "${CYAN}Running OCR on tiles...${RESET}"

VALID_TILES=0
INVALID_TILES=0

for tile in "$TILES_DIR"/tile_*.png; do
    TILE_NAME=$(basename "$tile" .png)
    
    # Preprocess: enhance contrast and convert to grayscale
    # This improves OCR accuracy on low-quality scans
    PROCESSED_TILE="$TILES_DIR/${TILE_NAME}_processed.png"
    convert "$tile" \
        -colorspace gray \
        -normalize \
        -threshold 60% \
        "$PROCESSED_TILE" 2>/dev/null
    
    # Run OCR with Hindi + English
    # --oem 1 uses LSTM neural net, --psm 6 treats as uniform block of text
    tesseract "$PROCESSED_TILE" "$OCR_DIR/$TILE_NAME" \
        -l hin+eng \
        --oem 1 \
        --psm 6 \
        quiet 2>/dev/null || {
            echo -e "${YELLOW}OCR failed for $TILE_NAME${RESET}"
            echo "OCR_FAILED" > "$OCR_DIR/${TILE_NAME}.txt"
            INVALID_TILES=$((INVALID_TILES + 1))
            continue
        }
    
    # Quick validation: check if we got meaningful text
    OCR_TEXT=$(cat "$OCR_DIR/${TILE_NAME}.txt" 2>/dev/null || echo "")
    
    # Check for minimum text length and key Hindi markers
    if [ ${#OCR_TEXT} -lt 20 ]; then
        echo "INSUFFICIENT_TEXT" > "$OCR_DIR/${TILE_NAME}.status"
        INVALID_TILES=$((INVALID_TILES + 1))
    elif ! echo "$OCR_TEXT" | grep -qE "(निर्वाचक|नाम|उम्र|लिंग|[A-Z]{3}[0-9]{6})" 2>/dev/null; then
        # No voter fields detected
        echo "NO_VOTER_FIELDS" > "$OCR_DIR/${TILE_NAME}.status"
        INVALID_TILES=$((INVALID_TILES + 1))
    else
        echo "VALID" > "$OCR_DIR/${TILE_NAME}.status"
        VALID_TILES=$((VALID_TILES + 1))
    fi
    
    # Clean up processed tile
    rm -f "$PROCESSED_TILE"
done

# Step 3: Create summary
SUMMARY_FILE="$OUTPUT_DIR/summary/${IMAGE_NAME}.json"
mkdir -p "$OUTPUT_DIR/summary"

cat > "$SUMMARY_FILE" <<EOF
{
  "page": "${IMAGE_NAME}",
  "total_tiles": ${TILE_COUNT},
  "valid_tiles": ${VALID_TILES},
  "invalid_tiles": ${INVALID_TILES},
  "validity_ratio": $(echo "scale=2; $VALID_TILES / $TILE_COUNT" | bc)
}
EOF

# Report results
echo -e "Page ${IMAGE_NAME}: ${GREEN}${VALID_TILES}${RESET} valid, ${YELLOW}${INVALID_TILES}${RESET} invalid tiles"

# Return success only if we got at least 50% valid tiles
if [ $VALID_TILES -ge 15 ]; then
    exit 0
else
    echo -e "${YELLOW}Page has too many invalid tiles, may need manual review${RESET}"
    exit 1
fi