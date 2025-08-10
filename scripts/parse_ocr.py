#!/usr/bin/env python3
"""
Parse OCR results from tiled voter register images into structured CSV.
Handles validation and skips incomplete records.
"""

import csv
import re
import glob
import os
import sys
import json
from pathlib import Path
from typing import Dict, List, Optional
import argparse


class VoterParser:
    """Parser for Hindi/English voter registration OCR text."""
    
    # Field patterns - adjusted for OCR noise and variations
    PATTERNS = {
        "serial": r"\b([0-9]{1,4})\b",  # Serial numbers can be 1-4 digits
        "name": r"निर्वाचक\s*का\s*नाम[\s:]*([^\n]+)",
        "relation": r"(?:पति|पिता|माता)\s*का\s*नाम[\s:]*([^\n]+)",
        "house_no": r"मकान\s*संख्या[\s:]*([^\n]+)",
        "age": r"उम्र[\s:]*([0-9]{1,3})",
        "gender": r"लिंग[\s:]*([^\n]+)",
        "epic": r"\b([A-Z]{3}[0-9]{6,7})\b",  # EPIC format: 3 letters + 6-7 digits
    }
    
    # Required fields for a valid record
    REQUIRED_FIELDS = ["name", "age", "epic"]
    
    def __init__(self, strict_mode: bool = False):
        """
        Initialize parser.
        
        Args:
            strict_mode: If True, require all fields. If False, only require REQUIRED_FIELDS.
        """
        self.strict_mode = strict_mode
        self.stats = {
            "total_tiles": 0,
            "valid_records": 0,
            "invalid_records": 0,
            "skipped_tiles": 0,
        }
    
    def extract_field(self, pattern: str, text: str) -> str:
        """Extract a field using regex pattern."""
        match = re.search(pattern, text, re.UNICODE | re.IGNORECASE)
        return match.group(1).strip() if match else ""
    
    def clean_text(self, text: str) -> str:
        """Clean OCR text for better parsing."""
        # Normalize whitespace
        text = re.sub(r"[ \t]+", " ", text)
        # Remove excessive newlines
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()
    
    def parse_tile(self, ocr_text: str, tile_id: str) -> Optional[Dict]:
        """
        Parse a single tile's OCR text.
        
        Returns:
            Dictionary of extracted fields, or None if invalid.
        """
        # Clean the text
        text = self.clean_text(ocr_text)
        
        # Skip if too short
        if len(text) < 20:
            return None
        
        # Extract all fields
        record = {
            "tile_id": tile_id,
            "serial": self.extract_field(self.PATTERNS["serial"], text),
            "epic": self.extract_field(self.PATTERNS["epic"], text),
            "name": self.extract_field(self.PATTERNS["name"], text),
            "relation": self.extract_field(self.PATTERNS["relation"], text),
            "house_no": self.extract_field(self.PATTERNS["house_no"], text),
            "age": self.extract_field(self.PATTERNS["age"], text),
            "gender": self.extract_field(self.PATTERNS["gender"], text),
            "raw_text_length": len(text),
        }
        
        # Validation
        if self.strict_mode:
            # All fields must be present
            required = self.PATTERNS.keys()
        else:
            # Only essential fields required
            required = self.REQUIRED_FIELDS
        
        # Check required fields
        missing = [field for field in required if not record.get(field)]
        
        if missing:
            print(f"  Tile {tile_id}: Missing fields: {missing}")
            return None
        
        # Additional validation
        if record.get("age"):
            try:
                age = int(record["age"])
                if age < 18 or age > 120:
                    print(f"  Tile {tile_id}: Invalid age: {age}")
                    return None
            except ValueError:
                print(f"  Tile {tile_id}: Non-numeric age: {record['age']}")
                return None
        
        # EPIC validation
        if record.get("epic") and not re.match(r"^[A-Z]{3}[0-9]{6,7}$", record["epic"]):
            print(f"  Tile {tile_id}: Invalid EPIC format: {record['epic']}")
            if self.strict_mode:
                return None
        
        return record
    
    def parse_record(self, record_id: str, ocr_dir: str) -> Optional[Dict]:
        """Parse a structured voter record from separate OCR files."""
        base_path = os.path.join(ocr_dir, record_id)
        
        # Read separate OCR results
        try:
            with open(f"{base_path}_serial.txt", "r", encoding="utf-8", errors="ignore") as f:
                serial_text = f.read().strip()
        except:
            serial_text = ""
            
        try:
            with open(f"{base_path}_epic.txt", "r", encoding="utf-8", errors="ignore") as f:
                epic_text = f.read().strip()
        except:
            epic_text = ""
            
        try:
            with open(f"{base_path}_text.txt", "r", encoding="utf-8", errors="ignore") as f:
                hindi_text = f.read()
        except:
            hindi_text = ""
        
        # Extract fields
        record = {
            "record_id": record_id,
            "serial": self.extract_field(r"\b([0-9]{1,4})\b", serial_text),
            "epic": self.extract_field(r"\b([A-Z0-9]{6,12})\b", epic_text),
            "name": self.extract_field(self.PATTERNS["name"], hindi_text),
            "relation": self.extract_field(self.PATTERNS["relation"], hindi_text),
            "house_no": self.extract_field(self.PATTERNS["house_no"], hindi_text),
            "age": self.extract_field(self.PATTERNS["age"], hindi_text),
            "gender": self.extract_field(self.PATTERNS["gender"], hindi_text),
            "raw_text_length": len(hindi_text),
        }
        
        # Validation - require name, age, serial
        required_fields = ["name", "age", "serial"]
        missing = [field for field in required_fields if not record.get(field)]
        
        if missing:
            print(f"  Record {record_id}: Missing fields: {missing}")
            return None
        
        # Age validation
        if record.get("age"):
            try:
                age = int(record["age"])
                if age < 18 or age > 120:
                    print(f"  Record {record_id}: Invalid age: {age}")
                    return None
            except ValueError:
                print(f"  Record {record_id}: Non-numeric age: {record['age']}")
                return None
        
        return record
    
    def process_page(self, ocr_dir: str, page_id: str) -> List[Dict]:
        """
        Process all records from a page.
        
        Args:
            ocr_dir: Directory containing OCR text files
            page_id: Page identifier
            
        Returns:
            List of valid voter records
        """
        records = []
        
        # Find all record status files
        status_files = sorted(glob.glob(os.path.join(ocr_dir, "record_*.status")))
        
        print(f"Processing page {page_id}: {len(status_files)} records")
        
        for status_file in status_files:
            self.stats["total_tiles"] += 1
            
            # Get record ID
            record_id = os.path.basename(status_file).replace(".status", "")
            
            # Check if record was marked as valid
            try:
                with open(status_file, "r") as f:
                    status = f.read().strip()
            except:
                status = "UNKNOWN"
            
            if status != "VALID":
                self.stats["skipped_tiles"] += 1
                continue
            
            # Parse the record
            record = self.parse_record(record_id, ocr_dir)
            
            if record:
                record["page_id"] = page_id
                records.append(record)
                self.stats["valid_records"] += 1
            else:
                self.stats["invalid_records"] += 1
        
        return records
    
    def process_directory(self, input_dir: str, output_csv: str):
        """
        Process all OCR results in a directory structure.
        
        Args:
            input_dir: Root directory containing ocr/<page>/ subdirectories
            output_csv: Output CSV file path
        """
        all_records = []
        
        # Find all page directories
        ocr_base = os.path.join(input_dir, "ocr")
        if not os.path.exists(ocr_base):
            print(f"Error: OCR directory not found: {ocr_base}")
            return
        
        page_dirs = sorted([d for d in os.listdir(ocr_base) 
                          if os.path.isdir(os.path.join(ocr_base, d))])
        
        print(f"Found {len(page_dirs)} pages to process")
        
        for page_id in page_dirs:
            page_ocr_dir = os.path.join(ocr_base, page_id)
            page_records = self.process_page(page_ocr_dir, page_id)
            all_records.extend(page_records)
            
            # Show progress
            if len(all_records) % 100 == 0:
                print(f"  Processed {len(all_records)} records so far...")
        
        # Write to CSV
        if all_records:
            fieldnames = ["page_id", "record_id", "serial", "epic", "name", 
                         "relation", "house_no", "age", "gender", "raw_text_length"]
            
            with open(output_csv, "w", newline="", encoding="utf-8") as f:
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(all_records)
            
            print(f"\nWrote {len(all_records)} records to {output_csv}")
        else:
            print("\nNo valid records found!")
        
        # Print statistics
        print("\nProcessing Statistics:")
        print(f"  Total tiles: {self.stats['total_tiles']}")
        print(f"  Valid records: {self.stats['valid_records']}")
        print(f"  Invalid records: {self.stats['invalid_records']}")
        print(f"  Skipped tiles: {self.stats['skipped_tiles']}")
        
        if self.stats['total_tiles'] > 0:
            success_rate = (self.stats['valid_records'] / self.stats['total_tiles']) * 100
            print(f"  Success rate: {success_rate:.1f}%")


def main():
    parser = argparse.ArgumentParser(
        description="Parse OCR results from voter register tiles into CSV"
    )
    parser.add_argument(
        "input_dir",
        help="Input directory containing OCR results"
    )
    parser.add_argument(
        "output_csv",
        help="Output CSV file path"
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Strict mode: require all fields to be present"
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Test mode: process only first 10 pages"
    )
    
    args = parser.parse_args()
    
    # Initialize parser
    voter_parser = VoterParser(strict_mode=args.strict)
    
    # Process the directory
    voter_parser.process_directory(args.input_dir, args.output_csv)


if __name__ == "__main__":
    main()