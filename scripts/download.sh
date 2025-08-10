#!/bin/bash

# Download a specific numbered zip file from the Indian government website
# Usage: ./download.sh <number>

if [ $# -ne 1 ]; then
    echo "Usage: $0 <file_number>"
    echo "Example: $0 1  (downloads 1.zip)"
    exit 1
fi

FILE_NUM="$1"
URL="https://www.eci.gov.in/eci-backend/public/ER/s04/SIR/${FILE_NUM}.zip"
OUTPUT_PATH="./data/1.download/${FILE_NUM}.zip"

# Create download directory if it doesn't exist
mkdir -p "$(dirname "$OUTPUT_PATH")"

# Download with progress bar and resume capability
echo "Downloading ${FILE_NUM}.zip..."
curl -L -C - --progress-bar "$URL" -o "${OUTPUT_PATH}.tmp" && \
    mv "${OUTPUT_PATH}.tmp" "$OUTPUT_PATH" && \
    echo "Successfully downloaded ${FILE_NUM}.zip" || \
    echo "Failed to download ${FILE_NUM}.zip"
