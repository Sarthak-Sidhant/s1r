#!/bin/bash

# Extract and OCR all images from a tar file
# This runs as an optional stage after compression

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Check arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <file_number>"
    echo "Example: $0 1  (processes 1.tar)"
    exit 1
fi

FILE_NUM="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$BASE_DIR/data"
COMPLETED_DIR="$DATA_DIR/3.completed"
OCR_DIR="$DATA_DIR/4.ocr"
CSV_DIR="$DATA_DIR/5.csv"

TAR_FILE="$COMPLETED_DIR/${FILE_NUM}.tar"
WORK_DIR="$OCR_DIR/${FILE_NUM}"
OUTPUT_CSV="$CSV_DIR/${FILE_NUM}.csv"

# Check if tar file exists
if [ ! -f "$TAR_FILE" ]; then
    echo -e "${RED}Error: ${TAR_FILE} not found${RESET}"
    echo "Run 'make process-${FILE_NUM}' first"
    exit 1
fi

# Check dependencies
echo -e "${CYAN}Checking OCR dependencies...${RESET}"
for cmd in tesseract convert python3; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: $cmd is not installed${RESET}"
        exit 1
    fi
done

# Check for Hindi language pack
if ! tesseract --list-langs 2>/dev/null | grep -q "^hin$"; then
    echo -e "${RED}Error: Hindi language pack not installed${RESET}"
    echo "Install with: sudo apt-get install tesseract-ocr-hin"
    exit 1
fi

echo -e "${BOLD}Extracting and OCR'ing file ${FILE_NUM}${RESET}"

# Create work directory
mkdir -p "$WORK_DIR" "$CSV_DIR"

# Step 1: Extract tar file and nested tars
echo -e "${CYAN}Extracting images from tar...${RESET}"
cd "$WORK_DIR"
tar -xf "$TAR_FILE"

# The main tar contains individual tar files for each PDF
# Extract all the nested tar files to get the PNG images
echo -e "${CYAN}Extracting nested tar files...${RESET}"
TAR_FILES=$(find . -name "*.tar" -type f)
TAR_COUNT=$(echo "$TAR_FILES" | wc -l)
echo -e "Found ${YELLOW}${TAR_COUNT}${RESET} nested tar files"

for nested_tar in $TAR_FILES; do
    # Extract each nested tar in place
    echo "Extracting $(basename "$nested_tar")"
    tar -xf "$nested_tar" -C "$(dirname "$nested_tar")"
    # Remove the nested tar file to save space
    rm -f "$nested_tar"
done

# Now find all PNG images
PNG_COUNT=$(find . -name "*.png" -type f | wc -l)
echo -e "Found ${YELLOW}${PNG_COUNT}${RESET} PNG images total"

if [ "$PNG_COUNT" -eq 0 ]; then
    echo -e "${RED}No PNG images found after extraction${RESET}"
    exit 1
fi

# Step 2: Process each image with OCR
echo -e "${CYAN}Running OCR on images...${RESET}"

# Process images in batches to avoid overwhelming the system
PROCESSED=0
FAILED=0

find . -name "*.png" -type f | sort | while read png_file; do
    # Create a unique page name from the full path
    # e.g., ./tars/2025-EROLLGEN-S04-1-SIR-DraftRoll-Revision1-HIN-100-WI/page-1/img-000.png
    # Extract the PDF name and page info properly
    PDF_DIR=$(echo "$png_file" | cut -d'/' -f3)  # Get the PDF directory name
    PAGE_DIR=$(echo "$png_file" | cut -d'/' -f4)  # Get page-N
    IMG_NAME=$(basename "$png_file" .png)        # Get img-000
    
    PAGE_PATH="${PDF_DIR}_${PAGE_DIR}_${IMG_NAME}"
    
    PROCESSED=$((PROCESSED + 1))
    echo -e "[${PROCESSED}/${PNG_COUNT}] Processing ${PDF_DIR}/${PAGE_DIR}..."
    
    # Run OCR on this page
    if bash "$SCRIPT_DIR/ocr_page.sh" "$png_file" "$WORK_DIR" >> "$WORK_DIR/ocr.log" 2>&1; then
        echo -e "  ${GREEN}✓${RESET} OCR completed"
    else
        echo -e "  ${YELLOW}⚠${RESET} OCR had issues (check log)"
        FAILED=$((FAILED + 1))
    fi
    
    # Clean up the original PNG to save space
    rm -f "$png_file"
done

echo -e "${GREEN}OCR complete: ${PROCESSED} pages processed${RESET}"

# Step 3: Parse OCR results into CSV
echo -e "${CYAN}Parsing OCR results to CSV...${RESET}"

python3 "$SCRIPT_DIR/parse_ocr.py" "$WORK_DIR" "$OUTPUT_CSV"

# Check if CSV was created
if [ -f "$OUTPUT_CSV" ]; then
    RECORD_COUNT=$(tail -n +2 "$OUTPUT_CSV" | wc -l)
    CSV_SIZE=$(du -h "$OUTPUT_CSV" | cut -f1)
    echo -e "${GREEN}✓ Created CSV with ${RECORD_COUNT} records (${CSV_SIZE})${RESET}"
else
    echo -e "${RED}Failed to create CSV${RESET}"
    exit 1
fi

# Step 4: Cleanup (optional - keep OCR results for debugging)
echo -e "${CYAN}Cleaning up temporary files...${RESET}"
# Keep tiles and OCR text for debugging, but remove processed images
find "$WORK_DIR" -name "*_processed.png" -delete

# Create summary
SUMMARY_FILE="$CSV_DIR/${FILE_NUM}_summary.json"
cat > "$SUMMARY_FILE" <<EOF
{
  "file_number": ${FILE_NUM},
  "pages_processed": ${PNG_COUNT},
  "csv_records": ${RECORD_COUNT},
  "csv_file": "${OUTPUT_CSV}",
  "timestamp": "$(date -Iseconds)"
}
EOF

echo -e "${BOLD}${GREEN}✓ OCR extraction complete for file ${FILE_NUM}${RESET}"
echo -e "CSV output: ${CYAN}${OUTPUT_CSV}${RESET}"

exit 0