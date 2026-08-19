#!/usr/bin/env bash
# Run one SimpleSSD simulation and save the result under outputs/.

set -u

OUTFILE="outputs/${1:-simulation.log}"
OUTDIR="$(pwd)/outputs"
STATS_FILE="$OUTDIR/sim_stats.tmp.log"
SUMMARY_FILE="$OUTDIR/run_summary.tmp.log"
CONFIG_FILE="$OUTDIR/standalone.tmp.cfg"

mkdir -p "$OUTDIR"
rm -f "$STATS_FILE" "$SUMMARY_FILE" "$CONFIG_FILE"

echo "Running SimpleSSD standalone simulation..."
echo "Output: $OUTFILE"

sed "s|^LogFile *=.*|LogFile = $STATS_FILE|" \
  config/sample.cfg > "$CONFIG_FILE"

{
  echo "=== SimpleSSD Simulation ==="
  echo "Started: $(date)"
  echo "Config : config/sample.cfg + simplessd/config/sample.cfg"
  echo ""
} > "$OUTFILE"

./simplessd-standalone \
  "$CONFIG_FILE" \
  simplessd/config/sample.cfg \
  outputs/stats > "$SUMMARY_FILE" 2>&1

{
  echo "=== SUBSYSTEM STATS ==="
  if [ -f "$STATS_FILE" ]; then
    cat "$STATS_FILE"
  else
    echo "(WARNING: stats log not found)"
  fi

  echo ""
  echo "=== RUN SUMMARY ==="
  sed -e 's/\x1b\[2K *\r//g' -e 's/\r$//' "$SUMMARY_FILE"

  echo ""
  echo "Finished: $(date)"
} >> "$OUTFILE"

rm -f "$STATS_FILE" "$SUMMARY_FILE" "$CONFIG_FILE"

echo "Done. Results in: $OUTFILE"
