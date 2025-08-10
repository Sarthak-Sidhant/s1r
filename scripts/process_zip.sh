#!/bin/bash

# Process a single zip file: extract, shrink PDFs, combine to tar, cleanup
# Usage: ./process_zip.sh <number>
# Example: ./process_zip.sh 1  (processes 1.zip -> 1.tar)

set -e  # Exit on error

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$BASE_DIR/data"
DOWNLOAD_DIR="$DATA_DIR/1.download"
PROCESSING_DIR="$DATA_DIR/2.processing"
COMPLETED_DIR="$DATA_DIR/3.completed"
LOCKS_DIR="$DATA_DIR/locks"
SHRINK_SCRIPT="$SCRIPT_DIR/shrink_pdf.sh"

# Check if number argument provided
if [ $# -ne 1 ]; then
    echo -e "${RED}Usage: $0 <number>${RESET}"
    echo -e "Example: $0 1  (processes 1.zip -> 1.tar)"
    exit 1
fi

FILE_NUM="$1"
ZIP_FILE="$DOWNLOAD_DIR/${FILE_NUM}.zip"
LOCK_FILE="$LOCKS_DIR/${FILE_NUM}.lock"
LOG_FILE="$LOCKS_DIR/${FILE_NUM}.log"
WORK_DIR="$PROCESSING_DIR/${FILE_NUM}"
FINAL_TAR="$COMPLETED_DIR/${FILE_NUM}.tar"

# Create necessary directories
mkdir -p "$DOWNLOAD_DIR" "$PROCESSING_DIR" "$COMPLETED_DIR" "$LOCKS_DIR"

# Function to update lock status
update_lock() {
    local status="$1"
    echo "$status" > "$LOCK_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Status: $status" >> "$LOG_FILE"
}

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Process failed for file ${FILE_NUM}${RESET}" | tee -a "$LOG_FILE"
        update_lock "failed"
    fi
    # Clean up work directory if it exists
    if [ -d "$WORK_DIR" ] && [ "$exit_code" -eq 0 ]; then
        echo -e "${CYAN}Cleaning up work directory...${RESET}" | tee -a "$LOG_FILE"
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# Check if already processed
if [ -f "$LOCK_FILE" ]; then
    STATUS=$(cat "$LOCK_FILE")
    if [ "$STATUS" = "done" ]; then
        echo -e "${GREEN}File ${FILE_NUM} already processed${RESET}"
        exit 0
    elif [ "$STATUS" = "failed" ]; then
        echo -e "${YELLOW}Previous processing failed for ${FILE_NUM}, retrying...${RESET}"
        rm -rf "$WORK_DIR"
    else
        echo -e "${YELLOW}File ${FILE_NUM} is currently being processed (status: $STATUS)${RESET}"
        exit 0
    fi
fi

# Check if zip file exists
if [ ! -f "$ZIP_FILE" ]; then
    echo -e "${RED}Error: ${ZIP_FILE} not found${RESET}"
    echo -e "Please download it first with: make download-${FILE_NUM}"
    exit 1
fi

# Start processing
echo -e "${BOLD}Processing ${FILE_NUM}.zip${RESET}" | tee "$LOG_FILE"
update_lock "starting"

# Get original zip size
ZIP_SIZE=$(du -h "$ZIP_FILE" | cut -f1)
echo -e "Input size: ${MAGENTA}${ZIP_SIZE}${RESET}" | tee -a "$LOG_FILE"

# Step 1: Extract zip file
echo -e "${CYAN}Extracting ${FILE_NUM}.zip...${RESET}" | tee -a "$LOG_FILE"
update_lock "extracting"
mkdir -p "$WORK_DIR"
unzip -q "$ZIP_FILE" -d "$WORK_DIR"

# Count PDFs
PDF_COUNT=$(find "$WORK_DIR" -name "*.pdf" -type f | wc -l)
echo -e "Found ${YELLOW}${PDF_COUNT}${RESET} PDF files" | tee -a "$LOG_FILE"

# Step 2: Process each PDF
echo -e "${CYAN}Processing PDFs...${RESET}" | tee -a "$LOG_FILE"
update_lock "processing"

PROCESSED=0
FAILED=0
TOTAL_ORIGINAL=0
TOTAL_COMPRESSED=0

# Create a subdirectory for tar files
TAR_DIR="$WORK_DIR/tars"
mkdir -p "$TAR_DIR"

# Process each PDF
find "$WORK_DIR" -name "*.pdf" -type f | sort | while read pdf_file; do
    PDF_NAME=$(basename "$pdf_file")
    PDF_BASE="${PDF_NAME%.pdf}"
    TAR_FILE="$TAR_DIR/${PDF_BASE}.tar"
    
    PROCESSED=$((PROCESSED + 1))
    echo -e "[${PROCESSED}/${PDF_COUNT}] Processing ${PDF_NAME}..." | tee -a "$LOG_FILE"
    
    # Get original size
    ORIG_SIZE=$(stat -c%s "$pdf_file")
    TOTAL_ORIGINAL=$((TOTAL_ORIGINAL + ORIG_SIZE))
    
    # Process with shrink_pdf.sh
    if "$SHRINK_SCRIPT" "$pdf_file" >> "$LOG_FILE" 2>&1; then
        # shrink_pdf.sh creates a tar file in the same directory as the PDF
        EXPECTED_TAR="${pdf_file%.pdf}.tar"
        if [ -f "$EXPECTED_TAR" ]; then
            # Move the tar to our tar directory
            mv "$EXPECTED_TAR" "$TAR_FILE"
            
            # Get compressed size
            COMP_SIZE=$(stat -c%s "$TAR_FILE")
            TOTAL_COMPRESSED=$((TOTAL_COMPRESSED + COMP_SIZE))
            
            # Calculate compression ratio for this file
            RATIO=$((100 - (COMP_SIZE * 100 / ORIG_SIZE)))
            echo -e "  ${GREEN}✓${RESET} Compressed by ${GREEN}${RATIO}%${RESET}" | tee -a "$LOG_FILE"
        else
            echo -e "  ${RED}✗${RESET} Tar file not created" | tee -a "$LOG_FILE"
            FAILED=$((FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗${RESET} Processing failed" | tee -a "$LOG_FILE"
        FAILED=$((FAILED + 1))
    fi
done

echo -e "${GREEN}Processed ${PROCESSED} PDFs (${FAILED} failed)${RESET}" | tee -a "$LOG_FILE"

# Step 3: Combine all tar files into single archive
echo -e "${CYAN}Combining tar files into ${FILE_NUM}.tar...${RESET}" | tee -a "$LOG_FILE"
update_lock "combining"

# Count tar files
TAR_COUNT=$(find "$TAR_DIR" -name "*.tar" -type f | wc -l)
if [ "$TAR_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No tar files created${RESET}" | tee -a "$LOG_FILE"
    exit 1
fi

# Create the final tar containing all individual tars
# We preserve the directory structure for easier extraction later
cd "$WORK_DIR"
tar -cf "$FINAL_TAR" tars/*.tar

# Verify the final tar
if [ ! -f "$FINAL_TAR" ]; then
    echo -e "${RED}Error: Failed to create final tar${RESET}" | tee -a "$LOG_FILE"
    exit 1
fi

# Get final size
FINAL_SIZE=$(du -h "$FINAL_TAR" | cut -f1)
FINAL_SIZE_BYTES=$(stat -c%s "$FINAL_TAR")
ZIP_SIZE_BYTES=$(stat -c%s "$ZIP_FILE")
TOTAL_RATIO=$((100 - (FINAL_SIZE_BYTES * 100 / ZIP_SIZE_BYTES)))

# Step 4: Mark as complete
update_lock "done"

# Print summary
echo -e "${BOLD}${GREEN}✓ Successfully processed ${FILE_NUM}.zip${RESET}" | tee -a "$LOG_FILE"
echo -e "Input:  ${MAGENTA}${ZIP_SIZE}${RESET}" | tee -a "$LOG_FILE"
echo -e "Output: ${MAGENTA}${FINAL_SIZE}${RESET}" | tee -a "$LOG_FILE"
echo -e "Compression: ${GREEN}${TOTAL_RATIO}%${RESET}" | tee -a "$LOG_FILE"
echo -e "Location: ${CYAN}${FINAL_TAR}${RESET}" | tee -a "$LOG_FILE"

exit 0