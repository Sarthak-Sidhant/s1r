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
    # Extract each nested tar to its own subdirectory to avoid overwrites
    BASENAME=$(basename "$nested_tar" .tar)
    EXTRACT_DIR="extracted_$BASENAME"
    echo "Extracting $BASENAME to $EXTRACT_DIR"
    
    # Create extraction directory
    mkdir -p "$EXTRACT_DIR"
    
    # Extract to the specific directory
    tar -xf "$nested_tar" -C "$EXTRACT_DIR"
    
    # Remove the nested tar file to save space
    rm -f "$nested_tar"
done

# Now find all PNG images - show the directory structure for debugging
echo -e "${CYAN}Checking extracted structure...${RESET}"
DIRS_WITH_PNG=$(find . -name "*.png" -type f | head -20 | xargs -I {} dirname {} | sort -u)
echo "Sample directories with PNGs: $DIRS_WITH_PNG"

PNG_COUNT=$(find . -name "*.png" -type f | wc -l)
echo -e "Found ${YELLOW}${PNG_COUNT}${RESET} PNG images total"

if [ "$PNG_COUNT" -eq 0 ]; then
    echo -e "${RED}No PNG images found after extraction${RESET}"
    exit 1
fi

# Step 2: Process images with OCR using page-level parallelism
echo -e "${CYAN}Running OCR on images with optimized parallelism...${RESET}"

# Set thread limits to prevent oversubscription
export OMP_THREAD_LIMIT=1
export OMP_NUM_THREADS=1
export TESSERACT_NUM_THREADS=1

# Use all available CPU cores
PARALLEL_JOBS=$(nproc)

echo -e "Using ${YELLOW}${PARALLEL_JOBS}${RESET} parallel OCR workers"

# Use the fast OCR script if available, otherwise fall back to the original
OCR_SCRIPT="$SCRIPT_DIR/ocr_page_fast.py"
if [ ! -f "$OCR_SCRIPT" ]; then
    OCR_SCRIPT="$SCRIPT_DIR/ocr_page_python.py"
    echo -e "${YELLOW}Note: Using fallback OCR script (install tesserocr for better performance)${RESET}"
fi

# Process pages in parallel using GNU parallel or xargs
if command -v parallel &>/dev/null && parallel --version 2>/dev/null | grep -q GNU; then
    # Use GNU parallel with progress bar
    find . -name "*.png" -type f | sort | \
    parallel -j "$PARALLEL_JOBS" --bar --halt now,fail=1 \
        "PDF_DIR=\$(echo {} | cut -d'/' -f3); \
         PAGE_DIR=\$(echo {} | cut -d'/' -f4); \
         IMG_NAME=\$(basename {} .png); \
         PAGE_PATH=\"\${PDF_DIR}_\${PAGE_DIR}_\${IMG_NAME}\"; \
         PAGE_CSV=\"$WORK_DIR/\${PAGE_PATH}.csv\"; \
         python3 \"$OCR_SCRIPT\" {} \"\$PAGE_CSV\" >> \"$WORK_DIR/ocr.log\" 2>&1 && \
         echo \"\$PAGE_CSV\" >> \"$WORK_DIR/page_csvs.txt\" && \
         rm -f {} && \
         echo -e \"  ${GREEN}✓${RESET} \${PDF_DIR}/\${PAGE_DIR}\""
else
    # Fallback to xargs for parallel processing
    echo -e "${YELLOW}Using xargs for parallel processing (install GNU parallel for progress bar)${RESET}"
    
    find . -name "*.png" -type f | sort | \
    xargs -P "$PARALLEL_JOBS" -I {} bash -c \
        "PDF_DIR=\$(echo {} | cut -d'/' -f3); \
         PAGE_DIR=\$(echo {} | cut -d'/' -f4); \
         IMG_NAME=\$(basename {} .png); \
         PAGE_PATH=\"\${PDF_DIR}_\${PAGE_DIR}_\${IMG_NAME}\"; \
         PAGE_CSV=\"$WORK_DIR/\${PAGE_PATH}.csv\"; \
         echo \"Processing \${PDF_DIR}/\${PAGE_DIR}...\"; \
         python3 \"$OCR_SCRIPT\" {} \"\$PAGE_CSV\" >> \"$WORK_DIR/ocr.log\" 2>&1 && \
         echo \"\$PAGE_CSV\" >> \"$WORK_DIR/page_csvs.txt\" && \
         rm -f {} && \
         echo -e \"  ${GREEN}✓${RESET} \${PDF_DIR}/\${PAGE_DIR}\""
fi

PROCESSED=$(find . -name "*.csv" -type f | wc -l)

echo -e "${GREEN}OCR complete: ${PROCESSED} pages processed${RESET}"

# Step 3: Combine all page CSVs into final CSV
echo -e "${CYAN}Combining page CSVs into final output...${RESET}"

if [ -f "$WORK_DIR/page_csvs.txt" ]; then
    # Get the first CSV to extract headers
    FIRST_CSV=$(head -n1 "$WORK_DIR/page_csvs.txt")
    if [ -f "$FIRST_CSV" ]; then
        # Copy header from first CSV
        head -n1 "$FIRST_CSV" > "$OUTPUT_CSV"
        
        # Append data from all CSVs (skip headers)
        while read csv_file; do
            if [ -f "$csv_file" ]; then
                tail -n+2 "$csv_file" >> "$OUTPUT_CSV"
            fi
        done < "$WORK_DIR/page_csvs.txt"
        
        # Clean up individual page CSVs
        while read csv_file; do
            rm -f "$csv_file"
        done < "$WORK_DIR/page_csvs.txt"
        rm -f "$WORK_DIR/page_csvs.txt"
    else
        echo -e "${RED}No valid CSV files found${RESET}"
        exit 1
    fi
else
    echo -e "${RED}No pages were processed successfully${RESET}"
    exit 1
fi

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