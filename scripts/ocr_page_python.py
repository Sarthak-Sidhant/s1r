#!/usr/bin/env python3
"""
Fast OCR processing for Indian voter registration pages using Python.
Processes one page at a time and outputs CSV directly.
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from PIL import Image, ImageFilter, ImageEnhance
import tempfile


# Precise measurements for Indian voter register
GRID_COLS = 3
GRID_ROWS = 10
RECORD_WIDTH = 298
RECORD_HEIGHT = 121
START_X = 22
START_Y = 42
GAP_X = 5
GAP_Y = 5


def extract_record_regions(image_path, output_dir):
    """Extract all 30 voter records and their regions from a page."""
    
    with Image.open(image_path) as img:
        image_name = Path(image_path).stem
        boxes_dir = Path(output_dir) / "boxes" / image_name
        boxes_dir.mkdir(parents=True, exist_ok=True)
        
        records = []
        
        for row in range(GRID_ROWS):
            for col in range(GRID_COLS):
                record_num = row * GRID_COLS + col
                record_id = f"{record_num:02d}"
                
                # Calculate record position
                x = START_X + col * (RECORD_WIDTH + GAP_X)
                y = START_Y + row * (RECORD_HEIGHT + GAP_Y)
                
                # Check if coordinates are within image bounds
                if x + RECORD_WIDTH > img.width or y + RECORD_HEIGHT > img.height:
                    print(f"Warning: Record {record_id} extends beyond image bounds, skipping")
                    continue
                
                # Extract full record
                record_box = (x, y, x + RECORD_WIDTH, y + RECORD_HEIGHT)
                record_img = img.crop(record_box)
                
                # Save regions for this record
                record_data = {
                    'record_id': record_id,
                    'row': row,
                    'col': col,
                    'x': x,
                    'y': y
                }
                
                # Extract and save regions
                try:
                    # Serial number region (top-left)
                    serial_box = (0, 0, 150, 25)
                    serial_img = record_img.crop(serial_box)
                    serial_path = boxes_dir / f"record_{record_id}_serial.png"
                    serial_img.save(serial_path)
                    record_data['serial_path'] = str(serial_path)
                    
                    # EPIC ID region (top-right)
                    epic_box = (200, 0, 298, 25)
                    epic_img = record_img.crop(epic_box)
                    epic_path = boxes_dir / f"record_{record_id}_epic.png"
                    epic_img.save(epic_path)
                    record_data['epic_path'] = str(epic_path)
                    
                    # Text region (bottom area)
                    text_box = (0, 25, 220, 115)
                    text_img = record_img.crop(text_box)
                    
                    # Enhance text region for better OCR
                    text_img = text_img.convert('L')  # Convert to grayscale
                    text_img = ImageEnhance.Contrast(text_img).enhance(1.2)
                    text_img = text_img.filter(ImageFilter.SHARPEN)
                    
                    text_path = boxes_dir / f"record_{record_id}_text.png"
                    text_img.save(text_path)
                    record_data['text_path'] = str(text_path)
                    
                    # Save full record for debugging
                    full_path = boxes_dir / f"record_{record_id}.png"
                    record_img.save(full_path)
                    record_data['full_path'] = str(full_path)
                    
                    records.append(record_data)
                    
                except Exception as e:
                    print(f"Error processing record {record_id}: {e}")
                    continue
        
        return records


def ocr_region(region_data):
    """OCR a single region (serial, epic, or text)."""
    region_type = region_data['type']
    image_path = region_data['path']
    record_id = region_data['record_id']
    
    try:
        with tempfile.NamedTemporaryFile(suffix='.txt', delete=False) as tmp_file:
            tmp_output = tmp_file.name.replace('.txt', '')
        
        if region_type == 'serial':
            # Serial numbers - digits only
            cmd = [
                'tesseract', image_path, tmp_output,
                '-l', 'eng',
                '--oem', '1',
                '--psm', '8',
                '-c', 'tessedit_char_whitelist=0123456789',
                'quiet'
            ]
        elif region_type == 'epic':
            # EPIC IDs - alphanumeric
            cmd = [
                'tesseract', image_path, tmp_output,
                '-l', 'eng', 
                '--oem', '1',
                '--psm', '8',
                '-c', 'tessedit_char_whitelist=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
                'quiet'
            ]
        else:  # text
            # Hindi + English text
            cmd = [
                'tesseract', image_path, tmp_output,
                '-l', 'hin+eng',
                '--oem', '1', 
                '--psm', '6',
                'quiet'
            ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        
        # Read OCR result
        try:
            with open(tmp_output + '.txt', 'r', encoding='utf-8') as f:
                text = f.read().strip()
        except:
            text = ""
        
        # Clean up temp file
        try:
            os.unlink(tmp_output + '.txt')
        except:
            pass
            
        return {
            'record_id': record_id,
            'type': region_type,
            'text': text,
            'success': result.returncode == 0
        }
        
    except Exception as e:
        return {
            'record_id': record_id,
            'type': region_type,
            'text': "",
            'success': False,
            'error': str(e)
        }


def parse_hindi_text(text):
    """Extract name, father name, age from Hindi OCR text."""
    # Field patterns for Hindi voter data
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


def process_page(image_path, output_csv):
    """Process a single page and output CSV."""
    
    print(f"Processing page: {image_path}")
    
    # Extract all record regions
    temp_dir = tempfile.mkdtemp()
    records = extract_record_regions(image_path, temp_dir)
    
    if not records:
        print("No records extracted from page")
        return
    
    print(f"Extracted {len(records)} records, running OCR...")
    
    # Prepare OCR tasks
    ocr_tasks = []
    for record in records:
        ocr_tasks.extend([
            {
                'type': 'serial',
                'path': record['serial_path'],
                'record_id': record['record_id']
            },
            {
                'type': 'epic', 
                'path': record['epic_path'],
                'record_id': record['record_id']
            },
            {
                'type': 'text',
                'path': record['text_path'], 
                'record_id': record['record_id']
            }
        ])
    
    # Run OCR in parallel
    ocr_results = {}
    with ProcessPoolExecutor(max_workers=os.cpu_count()) as executor:
        future_to_task = {executor.submit(ocr_region, task): task for task in ocr_tasks}
        
        for future in as_completed(future_to_task):
            result = future.result()
            record_id = result['record_id']
            region_type = result['type']
            
            if record_id not in ocr_results:
                ocr_results[record_id] = {}
            
            ocr_results[record_id][region_type] = result['text']
    
    # Process results and write CSV
    csv_records = []
    valid_count = 0
    
    for record in records:
        record_id = record['record_id']
        
        # Get OCR results
        serial = ocr_results.get(record_id, {}).get('serial', '').strip()
        epic = ocr_results.get(record_id, {}).get('epic', '').strip()
        text = ocr_results.get(record_id, {}).get('text', '').strip()
        
        # Parse Hindi text
        parsed = parse_hindi_text(text)
        
        # Basic validation
        is_valid = len(serial) >= 1 and len(epic) >= 6 and len(text) >= 20
        if is_valid:
            valid_count += 1
        
        csv_record = {
            'page': Path(image_path).stem,
            'record_id': record_id,
            'row': record['row'],
            'col': record['col'],
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
    
    # Write CSV
    os.makedirs(os.path.dirname(output_csv), exist_ok=True)
    with open(output_csv, 'w', newline='', encoding='utf-8') as f:
        if csv_records:
            writer = csv.DictWriter(f, fieldnames=csv_records[0].keys())
            writer.writeheader()
            writer.writerows(csv_records)
    
    # Clean up temp directory
    import shutil
    shutil.rmtree(temp_dir, ignore_errors=True)
    
    print(f"Completed: {valid_count}/{len(records)} valid records -> {output_csv}")
    
    return {
        'page': Path(image_path).stem,
        'total_records': len(records),
        'valid_records': valid_count,
        'csv_file': output_csv
    }


def main():
    parser = argparse.ArgumentParser(description='OCR process a voter registration page')
    parser.add_argument('image_path', help='Path to the page image')
    parser.add_argument('output_csv', help='Output CSV file path')
    parser.add_argument('--debug', action='store_true', help='Keep intermediate files for debugging')
    
    args = parser.parse_args()
    
    if not os.path.exists(args.image_path):
        print(f"Error: Image file not found: {args.image_path}")
        sys.exit(1)
    
    try:
        result = process_page(args.image_path, args.output_csv)
        
        # Output summary as JSON for easy parsing
        print(json.dumps(result, indent=2))
        
    except Exception as e:
        print(f"Error processing page: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()