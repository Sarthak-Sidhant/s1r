#!/bin/bash

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Configurable settings
COLORS=16         # Number of colors for PNG quantization
PARALLEL_JOBS=$(nproc)  # Use all available CPUs by default

# Check dependencies
check_dependencies() {
    for cmd in pdfseparate tar file numfmt du pdftocairo pdfimages convert pngquant; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}Error: $cmd is not installed. Please install it first.${RESET}"
            exit 1
        fi
    done
    # Check for parallel or xargs (we can use either)
    if ! command -v parallel &> /dev/null && ! command -v xargs &> /dev/null; then
        echo -e "${RED}Error: neither parallel nor xargs is installed. Please install one.${RESET}"
        exit 1
    fi
}

# Help message
show_help() {
    echo "Usage: $0 [OPTIONS] input.pdf"
    echo ""
    echo "Options:"
    echo "  -c, --colors COLORS   Number of colors for PNG (default: 16)"
    echo "  -j, --jobs JOBS       Number of parallel jobs (default: all CPUs)"
    echo "  -h, --help            Show this help message"
    exit 0
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--colors)
                COLORS="$2"
                shift 2
                ;;
            -j|--jobs)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                ;;
            -*)
                echo -e "${RED}Error: Unknown option $1${RESET}"
                show_help
                ;;
            *)
                INPUT_PDF="$1"
                shift
                ;;
        esac
    done
}

# Function to process a single PDF page
process_page() {
    local page_file="$1"
    local output_dir="$2"
    local colors="$3"
    local page_num=$(basename "$page_file" | sed 's/page-\([0-9]*\).pdf/\1/')
    local page_dir="$output_dir/page-$page_num"
    
    mkdir -p "$page_dir"
    
    # Check if page contains mask layers - FAIL FAST IF THIS ERRORS
    if ! pdfimages -list "$page_file" > "$page_dir/image_list.txt" 2>&1; then
        echo "Error examining PDF page: $page_file" >&2
        return 1
    fi
    
    
    if grep -q "mask" "$page_dir/image_list.txt"; then
        # Extract using pdftocairo - FAIL FAST IF THIS ERRORS
        if ! pdftocairo -png -r 150 "$page_file" "$page_dir/img" 2>&1; then
            echo "Error extracting images with pdftocairo: $page_file" >&2
            return 1
        fi
    else
        # Extract using pdfimages - FAIL FAST IF THIS ERRORS
        if ! pdfimages -j -png "$page_file" "$page_dir/img" 2>&1; then
            echo "Error extracting images with pdfimages: $page_file" >&2
            return 1
        fi
    fi
    
    # Check if any images were extracted
    if [ ! "$(find "$page_dir" -type f \( -name "*.png" -o -name "*.jpg" \))" ]; then
        echo "No images extracted from page: $page_file" >&2
        return 1
    fi
    
    # Convert images to reduced color PNGs with maximum compression
    find "$page_dir" -type f \( -name "*.png" -o -name "*.jpg" \) | while read img; do
        local base_name=$(basename "$img")
        local name_without_ext="${base_name%.*}"
        local temp_png="$page_dir/${name_without_ext}_temp.png"
        local final_png="$page_dir/${name_without_ext}.png"
        
        # Convert to PNG if JPG, or copy if already PNG
        if [[ "$img" == *.jpg ]]; then
            convert "$img" "$temp_png" 2>/dev/null || {
                echo "Error converting JPG to PNG: $img" >&2
                return 1
            }
        else
            cp "$img" "$temp_png"
        fi
        
        # Reduce colors using pngquant with maximum compression
        # --force overwrites existing file, --speed 1 = slowest/best compression
        pngquant --force --speed 1 --quality=60-90 "$colors" "$temp_png" --output "$final_png" 2>/dev/null || {
            echo "Error reducing colors: $temp_png" >&2
            rm -f "$temp_png"
            return 1
        }
        
        # Further optimize with optipng if available (silent fail if not)
        if command -v optipng &> /dev/null; then
            optipng -o7 -quiet "$final_png" 2>/dev/null || true
        fi
        
        # Remove original and temp files
        if [ "$img" != "$final_png" ]; then
            rm -f "$img" "$temp_png"
        else
            rm -f "$temp_png"
        fi
    done
    
    # Remove the original page PDF to save space
    rm "$page_file"
    return 0
}

# Main function
main() {
    # Check dependencies
    check_dependencies
    
    # Parse command-line arguments
    parse_args "$@"
    
    # Ensure a PDF file is provided as argument
    if [ -z "$INPUT_PDF" ]; then
        echo -e "${RED}Error: No input PDF file provided${RESET}"
        show_help
    fi

    # Check if input file exists and is a PDF
    if [ ! -f "$INPUT_PDF" ]; then
        echo -e "${RED}Error: $INPUT_PDF is not a file${RESET}"
        exit 1
    fi
    
    # FAIL FAST: Check if file is a PDF
    local mime_type
    mime_type=$(file -b --mime-type "$INPUT_PDF")
    if [[ "$mime_type" != "application/pdf" ]]; then
        echo -e "${RED}Error: $INPUT_PDF is not a PDF file (detected as $mime_type)${RESET}"
        exit 1
    fi
    
    # FAIL FAST: Check if we can read the PDF info
    if ! pdfinfo "$INPUT_PDF" &>/dev/null; then
        echo -e "${RED}Error: Failed to read PDF info for $INPUT_PDF. File may be corrupt.${RESET}"
        exit 1
    fi

    # Set up variables
    PDF_DIR=$(dirname "$INPUT_PDF")
    BASE_NAME=$(basename "$INPUT_PDF")
    TEMP_DIR="$(mktemp -d)"
    ARCHIVE="${PDF_DIR}/${BASE_NAME%.pdf}.tar"
    
    # FAIL FAST: Check if we can get the file size
    ORIGINAL_SIZE=$(du -bs "$INPUT_PDF" 2>/dev/null | cut -f1)
    if [[ ! "$ORIGINAL_SIZE" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Failed to determine size of $INPUT_PDF${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    ORIGINAL_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $ORIGINAL_SIZE)

    echo -e "Settings: COLORS=${CYAN}$COLORS${RESET}, PARALLEL_JOBS=${CYAN}$PARALLEL_JOBS${RESET}"
    echo -e "File: ${BOLD}$BASE_NAME${RESET} (${MAGENTA}$ORIGINAL_SIZE_HUMAN${RESET})"
    echo -e " - Extracting to \"$TEMP_DIR\""

    # Split PDF into individual pages
    echo -e " - Splitting PDF into individual pages"
    mkdir -p "$TEMP_DIR/pages"
    
    # FAIL FAST: Check if PDF can be split
    if ! pdfseparate "$INPUT_PDF" "$TEMP_DIR/pages/page-%d.pdf" 2>/dev/null; then
        echo -e "${RED}Error: Failed to split PDF into pages. File may be corrupt.${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    PAGE_COUNT=$(find "$TEMP_DIR/pages" -name "page-*.pdf" | wc -l)
    if [ $PAGE_COUNT -eq 0 ]; then
        echo -e "${RED}Error: No pages extracted from PDF. File may be corrupt.${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    echo -e " - PDF split into ${YELLOW}$PAGE_COUNT${RESET} pages"

    # Export the function for parallel
    export -f process_page

    # Process all pages in parallel
    echo -e " - Processing ${YELLOW}$PAGE_COUNT${RESET} pages in parallel (using ${YELLOW}$PARALLEL_JOBS${RESET} jobs)..."
    
    # Use a temp file to collect any errors
    ERROR_LOG="$TEMP_DIR/errors.log"
    touch "$ERROR_LOG"
    
    # Process pages and check for errors
    # Check if we have GNU parallel or busybox parallel
    if parallel --version 2>/dev/null | grep -q GNU; then
        # GNU parallel
        find "$TEMP_DIR/pages" -name "page-*.pdf" | \
        parallel -j "$PARALLEL_JOBS" --halt now,fail=1 \
            "process_page {} $TEMP_DIR $COLORS || echo 'Failed to process: {}' >> $ERROR_LOG"
    else
        # Fallback to xargs for parallel processing
        find "$TEMP_DIR/pages" -name "page-*.pdf" | \
        xargs -P "$PARALLEL_JOBS" -I {} bash -c \
            "process_page '{}' '$TEMP_DIR' '$COLORS' || echo 'Failed to process: {}' >> '$ERROR_LOG'"
    fi
    
    # Check if any errors occurred
    if [ -s "$ERROR_LOG" ]; then
        echo -e "${RED}Error: Some pages failed to process:${RESET}"
        cat "$ERROR_LOG"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Count successful conversions
    IMAGE_COUNT=$(find "$TEMP_DIR" -type f -name "*.png" | wc -l)
    
    # Check if any images were converted
    if [ $IMAGE_COUNT -eq 0 ]; then
        echo -e " - ${RED}No images could be processed. Keeping original PDF.${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    echo -e " - Successfully processed ${YELLOW}$IMAGE_COUNT${RESET} images with ${CYAN}$COLORS${RESET} colors"

    # Calculate new size - using -bs to get a single summarized value
    NEW_SIZE=$(du -bs "$TEMP_DIR" 2>/dev/null | cut -f1)
    if [[ ! "$NEW_SIZE" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Failed to determine size of processed files${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    NEW_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $NEW_SIZE)
    
    # Make sure we have valid numbers before calculation
    SAVED_BYTES=$((ORIGINAL_SIZE - NEW_SIZE))
    if [ $ORIGINAL_SIZE -gt 0 ]; then
        SAVED_PERCENT=$((SAVED_BYTES * 100 / ORIGINAL_SIZE))
    else
        echo -e "${RED}Error: Original file size is zero${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    SAVED_BYTES_HUMAN=$(numfmt --to=iec-i --suffix=B $SAVED_BYTES)

    echo -e " - Compression results:"
    echo -e "   - Original size: ${MAGENTA}$ORIGINAL_SIZE_HUMAN${RESET}, new size: ${MAGENTA}$NEW_SIZE_HUMAN${RESET}, saved: ${GREEN}$SAVED_BYTES_HUMAN${RESET} (${GREEN}$SAVED_PERCENT%${RESET})"

    # Note: No compression checks needed since we're only extracting images

    # Create archive
    echo -e " - Archiving all compressed PNG images"
    if ! tar -cf "$ARCHIVE" -C "$TEMP_DIR" .; then
        echo -e " - ${RED}Failed to create archive. Keeping original PDF.${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Check if archive was created successfully
    if [ ! -f "$ARCHIVE" ] || [ ! -s "$ARCHIVE" ]; then
        echo -e " - ${RED}Failed to create archive or archive is empty. Keeping original PDF.${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Clean up
    rm -rf "$TEMP_DIR"
    rm "$INPUT_PDF"

    echo -e " - Replaced \"$BASE_NAME\" with ${GREEN}\"${BASE_NAME%.pdf}.tar\"${RESET}"
    echo ""
    exit 0
}

# Call the main function
main "$@"