#!/bin/bash

# Parallel processing script for voter register files
# Processes multiple zip files simultaneously with controlled parallelism

set -e

# Configuration
PARALLEL_JOBS=${1:-2}  # Default to 2 parallel processes (each uses many cores internally)
START=${2:-1}          # Starting file number
END=${3:-243}          # Ending file number

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_SCRIPT="$SCRIPT_DIR/process_zip.sh"
DATA_DIR="$(dirname "$SCRIPT_DIR")/data"
DOWNLOAD_DIR="$DATA_DIR/1.download"
COMPLETED_DIR="$DATA_DIR/3.completed"
LOCKS_DIR="$DATA_DIR/locks"

echo -e "${BOLD}Parallel Process Manager${RESET}"
echo -e "Processing files ${CYAN}${START}-${END}${RESET} with ${YELLOW}${PARALLEL_JOBS}${RESET} parallel jobs"
echo -e "${YELLOW}Note: Each job uses multiple CPU cores internally for PDF processing${RESET}"
echo ""

# Generate list of files to process
PENDING_FILES=()
for i in $(seq $START $END); do
    # Check if already processed
    if [ -f "$LOCKS_DIR/${i}.lock" ]; then
        STATUS=$(cat "$LOCKS_DIR/${i}.lock")
        if [ "$STATUS" = "done" ]; then
            continue  # Skip completed files
        fi
    fi
    
    # Check if zip exists to process
    if [ -f "$DOWNLOAD_DIR/${i}.zip" ]; then
        PENDING_FILES+=($i)
    fi
done

TOTAL_PENDING=${#PENDING_FILES[@]}

if [ $TOTAL_PENDING -eq 0 ]; then
    echo -e "${GREEN}No files to process!${RESET}"
    echo "Either all files are already processed, or no zip files found to process."
    echo "Run 'make status' to see current state."
    exit 0
fi

# Calculate disk space needed and available
echo -e "${CYAN}Checking disk space...${RESET}"
AVAILABLE_SPACE=$(df "$DATA_DIR" | awk 'NR==2 {print $4}')
AVAILABLE_GB=$((AVAILABLE_SPACE / 1024 / 1024))

echo -e "Files to process: ${YELLOW}${TOTAL_PENDING}${RESET}"
echo -e "Available disk space: ${MAGENTA}${AVAILABLE_GB}GB${RESET}"
echo -e "${YELLOW}Warning: Each file needs ~4GB temporary space during processing${RESET}"
echo ""

# Function to process with status
process_with_status() {
    local num=$1
    local start_time=$(date +%s)
    
    echo -e "[${CYAN}START${RESET}] Processing file ${num}.zip"
    
    if bash "$PROCESS_SCRIPT" "$num" > "$LOCKS_DIR/${num}_process.out" 2>&1; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local minutes=$((duration / 60))
        local seconds=$((duration % 60))
        
        # Get compression ratio from log
        local ratio=$(grep "Compression:" "$LOCKS_DIR/${num}_process.out" | grep -oE '[0-9]+%' || echo "N/A")
        
        echo -e "[${GREEN}DONE${RESET}] File ${num} completed in ${minutes}m ${seconds}s (compression: ${ratio})"
        rm -f "$LOCKS_DIR/${num}_process.out"
        return 0
    else
        echo -e "[${RED}FAIL${RESET}] Failed to process ${num}.zip - check $LOCKS_DIR/${num}.log"
        return 1
    fi
}

export -f process_with_status
export PROCESS_SCRIPT LOCKS_DIR RED GREEN YELLOW CYAN RESET

# Check for GNU parallel or use xargs
if command -v parallel &> /dev/null && parallel --version 2>/dev/null | grep -q GNU; then
    echo -e "${CYAN}Using GNU parallel for processing...${RESET}"
    echo ""
    
    printf "%s\n" "${PENDING_FILES[@]}" | \
        parallel -j "$PARALLEL_JOBS" --progress --eta \
        "process_with_status {}"
else
    echo -e "${CYAN}Using xargs for parallel processing...${RESET}"
    echo ""
    
    printf "%s\n" "${PENDING_FILES[@]}" | \
        xargs -P "$PARALLEL_JOBS" -I {} bash -c 'process_with_status "$@"' _ {}
fi

# Summary
echo ""
echo -e "${BOLD}Processing Summary${RESET}"
echo "=================="

SUCCESS_COUNT=$(grep -l "done" "$LOCKS_DIR"/*.lock 2>/dev/null | wc -l)
FAILED_COUNT=$(grep -l "failed" "$LOCKS_DIR"/*.lock 2>/dev/null | wc -l)

echo -e "Total completed: ${GREEN}${SUCCESS_COUNT}${RESET} / ${END}"
if [ $FAILED_COUNT -gt 0 ]; then
    echo -e "Failed: ${RED}${FAILED_COUNT}${RESET}"
    echo -e "${YELLOW}Check logs in $LOCKS_DIR/ for details${RESET}"
    echo -e "${YELLOW}Run the script again to retry failed files${RESET}"
fi

# Show disk usage
if [ -d "$COMPLETED_DIR" ] && [ "$(ls -A $COMPLETED_DIR)" ]; then
    TOTAL_SIZE=$(du -sh "$COMPLETED_DIR" | cut -f1)
    echo -e "Total output size: ${MAGENTA}${TOTAL_SIZE}${RESET}"
    
    # Calculate space saved
    REMAINING_ZIPS=$(ls -1 "$DOWNLOAD_DIR"/*.zip 2>/dev/null | wc -l)
    echo -e "Remaining zip files: ${YELLOW}${REMAINING_ZIPS}${RESET}"
fi