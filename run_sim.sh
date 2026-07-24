#!/bin/bash
# Simple script to run SimpleSSD simulation and save clean results under the outputs folder

# Create outputs folder if it doesn't exist
mkdir -p outputs

OUTFILE="outputs/${1:-simulation.log}"
PREFIX="temp_stats_$$"

echo "Running SimpleSSD standalone simulation..."
echo "All clean outputs (subsystem metrics and stats) will be stored in: $OUTFILE"

# 1. Run simulation, filtering out the verbose [BIL] submitIO spam
./simplessd-standalone config/sample.cfg simplessd/config/sample.cfg "$PREFIX" 2>&1 | grep -v "submitIO" > "$OUTFILE"

# 2. Append all generated subsystem metric files to the single log file
echo "" >> "$OUTFILE"
echo "==========================================================" >> "$OUTFILE"
echo "                DETAILED SUBSYSTEM METRICS" >> "$OUTFILE"
echo "==========================================================" >> "$OUTFILE"

for f in ${PREFIX}_*.txt; do
    if [ -f "$f" ]; then
        component=$(basename "$f" | sed "s/${PREFIX}_//; s/\.txt//; tr '[a-z]' '[A-Z]'")
        echo "" >> "$OUTFILE"
        echo "--- $component STATS ---" >> "$OUTFILE"
        cat "$f" >> "$OUTFILE"
        rm -f "$f"
    fi
done

echo "Simulation complete!"
