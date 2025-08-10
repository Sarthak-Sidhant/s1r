# Makefile for processing Indian voter register PDFs
# Downloads, extracts, compresses, and prepares for archive.org

.PHONY: all clean status help test process-1 download-% process-% clean-%

# Configuration
TOTAL_FILES := 243
DATA_DIR := data
DOWNLOAD_DIR := $(DATA_DIR)/1.download
PROCESSING_DIR := $(DATA_DIR)/2.processing
COMPLETED_DIR := $(DATA_DIR)/3.completed
LOCKS_DIR := $(DATA_DIR)/locks
SCRIPTS_DIR := scripts

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
CYAN := \033[0;36m
BOLD := \033[1m
RESET := \033[0m

# Default target
all: help

# Check dependencies
deps:
	@./configure

# Help message
help:
	@echo "$(BOLD)Voter Register PDF Processing Pipeline$(RESET)"
	@echo ""
	@echo "$(CYAN)Usage:$(RESET)"
	@echo "  make deps          Check dependencies (run this first!)"
	@echo "  make download-N     Download file N.zip (e.g., make download-1)"
	@echo "  make process-N      Process file N.zip to N.tar (e.g., make process-1)"
	@echo "  make test          Test with file 1.zip"
	@echo "  make status        Show processing status"
	@echo "  make clean-N       Clean up file N's processing data"
	@echo "  make clean         Clean all temporary files (keeps downloads)"
	@echo "  make help          Show this help message"
	@echo ""
	@echo "$(CYAN)Batch operations:$(RESET)"
	@echo "  make download-all   Download all $(TOTAL_FILES) files (sequential)"
	@echo "  make download-parallel  Download with parallel jobs (default: 4)"
	@echo "  make download-parallel JOBS=8  Download with 8 parallel jobs"
	@echo "  make process-all    Process all downloaded files (sequential)"
	@echo "  make process-parallel   Process with parallel jobs (default: 4)"
	@echo "  make process-parallel JOBS=2  Process 2 files at once (each uses many CPUs)"
	@echo "  make ocr-N          Extract OCR from N.tar to CSV (e.g., make ocr-1)"
	@echo "  make ocr-all        Run OCR on all completed files (sequential)"
	@echo ""
	@echo "$(CYAN)Directories:$(RESET)"
	@echo "  $(DOWNLOAD_DIR)/     Downloaded zip files"
	@echo "  $(PROCESSING_DIR)/   Temporary processing files"
	@echo "  $(COMPLETED_DIR)/    Final tar archives"
	@echo "  $(LOCKS_DIR)/        Lock files and logs"
	@echo "  $(DATA_DIR)/4.ocr/   OCR working directories"
	@echo "  $(DATA_DIR)/5.csv/   Final CSV files"

# Create directory structure
dirs:
	@mkdir -p $(DOWNLOAD_DIR) $(PROCESSING_DIR) $(COMPLETED_DIR) $(LOCKS_DIR)

# Test with file 1
test: process-1
	@echo "$(GREEN)Test completed. Check $(COMPLETED_DIR)/1.tar$(RESET)"

# Download a specific file
download-%: dirs
	@FILE_NUM=$*; \
	if [ -f "$(DOWNLOAD_DIR)/$$FILE_NUM.zip" ]; then \
		echo "$(YELLOW)File $$FILE_NUM.zip already downloaded$(RESET)"; \
	else \
		echo "$(CYAN)Downloading $$FILE_NUM.zip...$(RESET)"; \
		bash $(SCRIPTS_DIR)/download.sh $$FILE_NUM; \
	fi

# Process a specific file
process-%: dirs download-%
	@FILE_NUM=$*; \
	echo "$(CYAN)Processing $$FILE_NUM.zip...$(RESET)"; \
	bash $(SCRIPTS_DIR)/process_zip.sh $$FILE_NUM

# Clean up processing data for a specific file
clean-%:
	@FILE_NUM=$*; \
	echo "$(YELLOW)Cleaning up file $$FILE_NUM...$(RESET)"; \
	rm -rf $(PROCESSING_DIR)/$$FILE_NUM; \
	rm -f $(LOCKS_DIR)/$$FILE_NUM.lock $(LOCKS_DIR)/$$FILE_NUM.log

# Show status of all files
status: dirs
	@echo "$(BOLD)Processing Status$(RESET)"
	@echo "=================="
	@DOWNLOADED=$$(ls -1 $(DOWNLOAD_DIR)/*.zip 2>/dev/null | wc -l); \
	COMPLETED=$$(ls -1 $(COMPLETED_DIR)/*.tar 2>/dev/null | wc -l); \
	IN_PROGRESS=$$(grep -l "processing\|extracting\|combining" $(LOCKS_DIR)/*.lock 2>/dev/null | wc -l); \
	FAILED=$$(grep -l "failed" $(LOCKS_DIR)/*.lock 2>/dev/null | wc -l); \
	echo "Downloaded:  $(GREEN)$$DOWNLOADED$(RESET) / $(TOTAL_FILES)"; \
	echo "Completed:   $(GREEN)$$COMPLETED$(RESET) / $(TOTAL_FILES)"; \
	echo "In Progress: $(YELLOW)$$IN_PROGRESS$(RESET)"; \
	echo "Failed:      $(RED)$$FAILED$(RESET)"; \
	echo ""; \
	if [ $$COMPLETED -gt 0 ]; then \
		echo "$(CYAN)Completed files:$(RESET)"; \
		for tar in $(COMPLETED_DIR)/*.tar; do \
			if [ -f "$$tar" ]; then \
				SIZE=$$(du -h "$$tar" | cut -f1); \
				echo "  $$(basename $$tar): $$SIZE"; \
			fi; \
		done; \
	fi; \
	if [ $$FAILED -gt 0 ]; then \
		echo ""; \
		echo "$(RED)Failed files:$(RESET)"; \
		grep -l "failed" $(LOCKS_DIR)/*.lock 2>/dev/null | while read lock; do \
			FILE=$$(basename $$lock .lock); \
			echo "  $$FILE - check $(LOCKS_DIR)/$$FILE.log for details"; \
		done; \
	fi

# Process file 1 specifically (for testing)
process-1: dirs download-1
	@bash $(SCRIPTS_DIR)/process_zip.sh 1

# Download all files (be careful with bandwidth!)
download-all: dirs
	@echo "$(BOLD)Downloading all $(TOTAL_FILES) files...$(RESET)"
	@for i in $$(seq 1 $(TOTAL_FILES)); do \
		$(MAKE) download-$$i; \
	done

# Parallel download with configurable number of jobs
download-parallel: dirs
	@bash $(SCRIPTS_DIR)/parallel_download.sh $(JOBS) $(START) $(END)

# Default parallel download values
JOBS ?= 4
START ?= 1
END ?= 243

# OCR extraction for a specific file
ocr-%: dirs
	@FILE_NUM=$*; \
	echo "$(CYAN)Running OCR extraction on $$FILE_NUM.tar...$(RESET)"; \
	bash $(SCRIPTS_DIR)/extract_ocr.sh $$FILE_NUM

# OCR all processed files (sequential)
ocr-all: dirs
	@echo "$(BOLD)Running OCR on all completed files...$(RESET)"
	@for tar in $(COMPLETED_DIR)/*.tar; do \
		if [ -f "$$tar" ]; then \
			FILE_NUM=$$(basename $$tar .tar); \
			echo "$(CYAN)Processing OCR for file $$FILE_NUM...$(RESET)"; \
			$(MAKE) ocr-$$FILE_NUM; \
		fi; \
	done

# Process all downloaded files (sequential)
process-all: dirs
	@echo "$(BOLD)Processing all downloaded files...$(RESET)"
	@for zip in $(DOWNLOAD_DIR)/*.zip; do \
		if [ -f "$$zip" ]; then \
			FILE_NUM=$$(basename $$zip .zip); \
			$(MAKE) process-$$FILE_NUM; \
		fi; \
	done

# Parallel processing with configurable number of jobs
process-parallel: dirs
	@bash $(SCRIPTS_DIR)/parallel_process.sh $(JOBS) $(START) $(END)

# Note: JOBS for process-parallel should be small (1-4) since each job uses many CPU cores

# Calculate total size saved
stats:
	@if [ -d $(COMPLETED_DIR) ] && [ "$$(ls -A $(COMPLETED_DIR))" ]; then \
		echo "$(BOLD)Compression Statistics$(RESET)"; \
		echo "======================"; \
		TOTAL_ORIG=0; \
		TOTAL_COMP=0; \
		for tar in $(COMPLETED_DIR)/*.tar; do \
			if [ -f "$$tar" ]; then \
				FILE_NUM=$$(basename $$tar .tar); \
				ZIP_FILE="$(DOWNLOAD_DIR)/$$FILE_NUM.zip"; \
				if [ -f "$$ZIP_FILE" ]; then \
					ORIG=$$(stat -c%s "$$ZIP_FILE"); \
					COMP=$$(stat -c%s "$$tar"); \
					TOTAL_ORIG=$$((TOTAL_ORIG + ORIG)); \
					TOTAL_COMP=$$((TOTAL_COMP + COMP)); \
				fi; \
			fi; \
		done; \
		if [ $$TOTAL_ORIG -gt 0 ]; then \
			RATIO=$$((100 - (TOTAL_COMP * 100 / TOTAL_ORIG))); \
			echo "Original size: $$(numfmt --to=iec-i --suffix=B $$TOTAL_ORIG)"; \
			echo "Compressed:    $$(numfmt --to=iec-i --suffix=B $$TOTAL_COMP)"; \
			echo "Space saved:   $(GREEN)$$RATIO%$(RESET)"; \
		fi; \
	else \
		echo "$(YELLOW)No completed files yet$(RESET)"; \
	fi

# Clean all temporary files (keeps downloads and completed files)
clean:
	@echo "$(YELLOW)Cleaning temporary files...$(RESET)"
	@rm -rf $(PROCESSING_DIR)/*
	@rm -f $(LOCKS_DIR)/*.lock
	@echo "$(GREEN)Cleaned$(RESET)"

# Clean everything except downloads
clean-all: clean
	@echo "$(YELLOW)Removing completed files...$(RESET)"
	@rm -rf $(COMPLETED_DIR)/*
	@rm -f $(LOCKS_DIR)/*.log
	@echo "$(GREEN)All cleaned$(RESET)"

# Full reset (removes everything including downloads)
reset:
	@echo "$(RED)$(BOLD)WARNING: This will delete all downloaded and processed files!$(RESET)"
	@echo "Press Ctrl+C to cancel, or Enter to continue..."
	@read dummy
	@rm -rf $(DATA_DIR)
	@echo "$(GREEN)Reset complete$(RESET)"