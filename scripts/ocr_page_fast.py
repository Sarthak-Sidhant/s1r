#!/usr/bin/env python3
"""
Fast OCR processing using tesserocr with persistent API.
Processes one page at a time with no subprocess spawning.
"""

import argparse
import csv
import json
import os
import re
import sys
from pathlib import Path
from PIL import Image
import numpy as np

try:
    import tesserocr
    HAS_TESSEROCR = True
except ImportError:
    HAS_TESSEROCR = False
    # Fallback to pytesseract if tesserocr not available
    import pytesseract

# Precise measurements for Indian voter register
GRID_COLS = 3
GRID_ROWS = 10
RECORD_WIDTH = 298
RECORD_HEIGHT = 121
START_X = 22
START_Y = 42
GAP_X = 5
GAP_Y = 5


class FastOCR:
    """Persistent OCR engine using tesserocr."""
    
    def __init__(self):
        if HAS_TESSEROCR:
            # Initialize three API instances for different region types
            # This avoids constantly switching configs
            # Find tessdata path dynamically
            import subprocess
            import os
            
            # Try to find tessdata path from tesseract
            tessdata_path = None
            try:
                result = subprocess.run(['tesseract', '--list-langs'], 
                                      capture_output=True, text=True, stderr=subprocess.STDOUT)
                output = result.stdout
                if 'tessdata' in output:
                    # Extract path from output like "List of available languages in "/path/to/tessdata/"
                    import re
                    match = re.search(r'"([^"]*tessdata[^"]*)"', output)
                    if match:
                        tessdata_path = match.group(1)
                        if not tessdata_path.endswith('/'):
                            tessdata_path += '/'
            except:
                pass
            
            # Fallback to common locations
            if not tessdata_path or not os.path.exists(tessdata_path):
                possible_paths = [
                    '/usr/share/tesseract-ocr/5/tessdata/',
                    '/usr/share/tesseract-ocr/4.00/tessdata/',
                    '/usr/share/tesseract-ocr/tessdata/',
                    '/usr/share/tessdata/',
                    '/usr/local/share/tessdata/',
                    os.path.expanduser('~/.local/share/tessdata/'),
                ]
                for path in possible_paths:
                    if os.path.exists(path):
                        tessdata_path = path
                        break
            
            if not tessdata_path:
                raise RuntimeError("Could not find tessdata directory. Please install tesseract-ocr.")
            
            print(f"Using tessdata path: {tessdata_path}", file=sys.stderr)
            
            self.serial_api = tesserocr.PyTessBaseAPI(path=tessdata_path, lang='eng', psm=tesserocr.PSM.SINGLE_LINE)
            self.serial_api.SetVariable("tessedit_char_whitelist", "0123456789")
            
            self.epic_api = tesserocr.PyTessBaseAPI(path=tessdata_path, lang='eng', psm=tesserocr.PSM.SINGLE_LINE)
            self.epic_api.SetVariable("tessedit_char_whitelist", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            
            self.text_api = tesserocr.PyTessBaseAPI(path=tessdata_path, lang='hin+eng', psm=tesserocr.PSM.SINGLE_BLOCK)
        else:
            print("Warning: tesserocr not available, using slower pytesseract fallback")
            self.serial_api = None
            self.epic_api = None
            self.text_api = None
    
    def ocr_serial(self, image):
        """OCR a serial number region."""
        if HAS_TESSEROCR:
            self.serial_api.SetImage(image)
            return self.serial_api.GetUTF8Text().strip()
        else:
            # Fallback to pytesseract
            return pytesseract.image_to_string(
                image,
                lang='eng',
                config='--psm 7 -c tessedit_char_whitelist=0123456789'
            ).strip()
    
    def ocr_epic(self, image):
        """OCR an EPIC ID region."""
        if HAS_TESSEROCR:
            self.epic_api.SetImage(image)
            return self.epic_api.GetUTF8Text().strip()
        else:
            return pytesseract.image_to_string(
                image,
                lang='eng',
                config='--psm 7 -c tessedit_char_whitelist=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
            ).strip()
    
    def ocr_text(self, image):
        """OCR Hindi/English text region."""
        if HAS_TESSEROCR:
            self.text_api.SetImage(image)
            return self.text_api.GetUTF8Text().strip()
        else:
            return pytesseract.image_to_string(
                image,
                lang='hin+eng',
                config='--psm 6'
            ).strip()
    
    def __del__(self):
        """Clean up API instances."""
        if HAS_TESSEROCR:
            if hasattr(self, 'serial_api') and self.serial_api:
                self.serial_api.End()
            if hasattr(self, 'epic_api') and self.epic_api:
                self.epic_api.End()
            if hasattr(self, 'text_api') and self.text_api:
                self.text_api.End()


def parse_hindi_text(text):
    """Extract name, father name, age from Hindi OCR text."""
    patterns = {
        'name': r'(?:निर्वाचक|नाम).*?[:：]\s*([^\n]+)',
        'father': r'(?:पिता|पति).*?[:：]\s*([^\n]+)', 
        'age': r'(?:उम्र|आयु).*?[:：]\s*(\d+)',
        'address': r'(?:पता|ग्राम).*?[:：]\s*([^\n]+)'
    }
    
    result = {}
    for field, pattern in patterns.items():
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            result[field] = match.group(1).strip()
    
    return result


def process_page(image_path, output_csv, debug=False):
    """Process a single page with persistent OCR engine."""
    
    print(f"Processing page: {image_path}")
    
    # Initialize OCR engine once for the entire page
    ocr_engine = FastOCR()
    
    # Open the image once
    with Image.open(image_path) as img:
        # Convert to grayscale for better OCR
        if img.mode != 'L':
            img = img.convert('L')
        
        # Optional: enhance contrast for the whole page once
        # instead of per-region enhancement
        img_array = np.array(img)
        
        csv_records = []
        valid_count = 0
        
        for row in range(GRID_ROWS):
            for col in range(GRID_COLS):
                record_num = row * GRID_COLS + col
                record_id = f"{record_num:02d}"
                
                # Calculate record position
                x = START_X + col * (RECORD_WIDTH + GAP_X)
                y = START_Y + row * (RECORD_HEIGHT + GAP_Y)
                
                # Check bounds
                if x + RECORD_WIDTH > img.width or y + RECORD_HEIGHT > img.height:
                    continue
                
                # Extract record region (in memory, no disk I/O)
                record_box = (x, y, x + RECORD_WIDTH, y + RECORD_HEIGHT)
                record_img = img.crop(record_box)
                
                # Extract and OCR regions directly from memory
                try:
                    # Serial number region
                    serial_box = (0, 0, 150, 25)
                    serial_img = record_img.crop(serial_box)
                    serial = ocr_engine.ocr_serial(serial_img)
                    
                    # EPIC ID region
                    epic_box = (200, 0, 298, 25)
                    epic_img = record_img.crop(epic_box)
                    epic = ocr_engine.ocr_epic(epic_img)
                    
                    # Text region
                    text_box = (0, 25, 220, 115)
                    text_img = record_img.crop(text_box)
                    text = ocr_engine.ocr_text(text_img)
                    
                except Exception as e:
                    print(f"Error processing record {record_id}: {e}")
                    serial = epic = text = ""
                
                # Parse Hindi text
                parsed = parse_hindi_text(text)
                
                # Validation - relaxed to accept records with just EPIC or good text
                is_valid = (len(epic) >= 6) or (len(text) >= 20)
                if is_valid:
                    valid_count += 1
                
                csv_record = {
                    'page': Path(image_path).stem,
                    'record_id': record_id,
                    'row': row,
                    'col': col,
                    'serial': serial,
                    'epic': epic,
                    'name': parsed.get('name', ''),
                    'father': parsed.get('father', ''),
                    'age': parsed.get('age', ''),
                    'address': parsed.get('address', ''),
                    'raw_text': text,  # DictWriter handles newlines properly
                    'valid': is_valid
                }
                
                csv_records.append(csv_record)
                
                if debug and record_num < 3:  # Debug first 3 records
                    print(f"  Record {record_id}: S={len(serial)}, E={len(epic)}, T={len(text)}")
    
    # Write CSV
    os.makedirs(os.path.dirname(output_csv) if os.path.dirname(output_csv) else '.', exist_ok=True)
    with open(output_csv, 'w', newline='', encoding='utf-8') as f:
        if csv_records:
            writer = csv.DictWriter(f, fieldnames=csv_records[0].keys())
            writer.writeheader()
            writer.writerows(csv_records)
    
    print(f"Completed: {valid_count}/{len(csv_records)} valid records -> {output_csv}")
    
    return {
        'page': Path(image_path).stem,
        'total_records': len(csv_records),
        'valid_records': valid_count,
        'csv_file': output_csv
    }


def main():
    parser = argparse.ArgumentParser(description='Fast OCR processing with tesserocr')
    parser.add_argument('image_path', help='Path to the page image')
    parser.add_argument('output_csv', help='Output CSV file path')
    parser.add_argument('--debug', action='store_true', help='Show debug output')
    
    args = parser.parse_args()
    
    if not os.path.exists(args.image_path):
        print(f"Error: Image file not found: {args.image_path}")
        sys.exit(1)
    
    # Set thread limits to prevent oversubscription
    os.environ['OMP_THREAD_LIMIT'] = '1'
    os.environ['OMP_NUM_THREADS'] = '1'
    
    try:
        result = process_page(args.image_path, args.output_csv, args.debug)
        
        # Output summary as JSON for parsing
        print(json.dumps(result, indent=2))
        
    except Exception as e:
        print(f"Error processing page: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()