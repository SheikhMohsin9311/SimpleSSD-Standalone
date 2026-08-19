#!/usr/bin/env python3
import sys
import re

def parse_log(filepath):
    stats = {}
    try:
        with open(filepath, 'r') as f:
            lines = f.readlines()
            
            for line in lines:
                if 'cmt.policy' in line:
                    stats['CMT Policy'] = 'LFU' if float(line.split()[1]) else 'LRU'
                elif 'cmt.capacity_bytes' in line:
                    stats['CMT Size (B)'] = float(line.split()[1])
                elif 'cmt.hit_rate' in line:
                    stats['CMT Hit Rate'] = float(line.split()[1])
                elif 'cmt.evictions' in line:
                    stats['CMT Evictions'] = float(line.split()[1])
                elif 'cmt.dirty_evictions' in line:
                    stats['CMT Dirty Evictions'] = float(line.split()[1])
                elif 'gc.count' in line:
                    stats['GC Count'] = float(line.split()[1])
                elif 'pal.read.count' in line:
                    stats['NAND Read Count'] = float(line.split()[1])
                elif 'pal.program.count' in line:
                    stats['NAND Program Count'] = float(line.split()[1])
                elif 'write.bytes' in line:
                    stats['Host Writes (B)'] = float(line.split()[1])
                elif 'pal.program.bytes' in line:
                    stats['NAND Writes (B)'] = float(line.split()[1])
                elif 'Elapsed Time' in line:
                    stats['Time'] = line.split('Elapsed Time: ')[1].strip()
                    
            if 'Host Writes (B)' in stats and 'NAND Writes (B)' in stats and stats['Host Writes (B)'] > 0:
                stats['WAF'] = stats['NAND Writes (B)'] / stats['Host Writes (B)']
            else:
                stats['WAF'] = 0.0
                
    except FileNotFoundError:
        print(f"Error: File '{filepath}' not found.")
        sys.exit(1)
        
    return stats

def format_num(num):
    if isinstance(num, float):
        if num > 1000:
            return f"{num:,.0f}"
        return f"{num:.4f}"
    return str(num)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 compare_stats.py <log1> [log2]")
        sys.exit(1)
        
    file1 = sys.argv[1]
    stats1 = parse_log(file1)
    
    if len(sys.argv) == 3:
        file2 = sys.argv[2]
        stats2 = parse_log(file2)
        
        print(f"{'Metric':<25} | {file1:<20} | {file2:<20}")
        print("-" * 72)
        
        keys = ['CMT Policy', 'CMT Size (B)', 'CMT Hit Rate', 'CMT Evictions',
                'CMT Dirty Evictions', 'GC Count', 'NAND Read Count',
                'NAND Program Count', 'WAF', 'Time']
        
        for key in keys:
            val1 = format_num(stats1.get(key, 'N/A'))
            val2 = format_num(stats2.get(key, 'N/A'))
            print(f"{key:<25} | {val1:<20} | {val2:<20}")
            
    else:
        print(f"--- Stats for {file1} ---")
        for key, val in stats1.items():
            print(f"{key:<25} : {format_num(val)}")

if __name__ == "__main__":
    main()
