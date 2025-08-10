#!/bin/bash

# Parallel download script for voter register files
# Downloads multiple files simultaneously with controlled parallelism

set -e

# Configuration
PARALLEL_JOBS=${1:-4}  # Default to 4 parallel downloads
START=${2:-1}          # Starting file number
END=${3:-243}          # Ending file number

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_SCRIPT="$SCRIPT_DIR/download.sh"
DATA_DIR="$(dirname "$SCRIPT_DIR")/data"
DOWNLOAD_DIR="$DATA_DIR/1.download"

# Create download directory
mkdir -p "$DOWNLOAD_DIR"

echo -e "${BOLD}Parallel Download Manager${RESET}"
echo -e "Downloading files ${CYAN}${START}-${END}${RESET} with ${YELLOW}${PARALLEL_JOBS}${RESET} parallel jobs"
echo ""

# Check if GNU parallel is installed
if ! command -v parallel &> /dev/null; then
    echo -e "${YELLOW}GNU parallel not found. Installing...${RESET}"
    if command -v apt-get &> /dev/null; then
        sudo apt-get install -y parallel
    else
        echo -e "${RED}Please install GNU parallel manually${RESET}"
        exit 1
    fi
fi

# Generate list of files to download
PENDING_FILES=()
for i in $(seq $START $END); do
    if [ ! -f "$DOWNLOAD_DIR/${i}.zip" ]; then
        PENDING_FILES+=($i)
    fi
done

TOTAL_PENDING=${#PENDING_FILES[@]}

if [ $TOTAL_PENDING -eq 0 ]; then
    echo -e "${GREEN}All files already downloaded!${RESET}"
    exit 0
fi

echo -e "Files to download: ${YELLOW}${TOTAL_PENDING}${RESET}"
echo -e "Already downloaded: ${GREEN}$((END - START + 1 - TOTAL_PENDING))${RESET}"
echo ""

# Export function for parallel execution
download_with_status() {
    local num=$1
    echo -e "[${CYAN}START${RESET}] Downloading file ${num}.zip"
    if bash "$DOWNLOAD_SCRIPT" "$num" > /dev/null 2>&1; then
        echo -e "[${GREEN}DONE${RESET}] Successfully downloaded ${num}.zip"
        return 0
    else
        echo -e "[${RED}FAIL${RESET}] Failed to download ${num}.zip"
        return 1
    fi
}
export -f download_with_status
export DOWNLOAD_SCRIPT

# Run downloads in parallel
echo -e "${CYAN}Starting parallel downloads...${RESET}"
echo ""

printf "%s\n" "${PENDING_FILES[@]}" | \
    parallel -j "$PARALLEL_JOBS" --progress --eta \
    "download_with_status {}"

# Summary
echo ""
echo -e "${BOLD}Download Summary${RESET}"
echo "=================="

SUCCESS_COUNT=$(ls -1 "$DOWNLOAD_DIR"/*.zip 2>/dev/null | wc -l)
FAILED_COUNT=$((TOTAL_PENDING - (SUCCESS_COUNT - (END - START + 1 - TOTAL_PENDING))))

echo -e "Total downloaded: ${GREEN}${SUCCESS_COUNT}${RESET} / $((END - START + 1))"
if [ $FAILED_COUNT -gt 0 ]; then
    echo -e "Failed: ${RED}${FAILED_COUNT}${RESET}"
    echo -e "${YELLOW}Run the script again to retry failed downloads${RESET}"
fi

# Show disk usage
if [ $SUCCESS_COUNT -gt 0 ]; then
    TOTAL_SIZE=$(du -sh "$DOWNLOAD_DIR" | cut -f1)
    echo -e "Total size: ${MAGENTA}${TOTAL_SIZE}${RESET}"
fi