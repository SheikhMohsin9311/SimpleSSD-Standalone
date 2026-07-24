#!/usr/bin/env bash
# =============================================================
# run_parallel.sh — Simple parallel SimpleSSD runner
# =============================================================
#
# HOW TO CHANGE THE SWEEP
#   Edit the four lines under "SWEEP PARAMETERS" below.
#
# HOW TO RUN
#   bash run_parallel.sh            # use defaults
#   bash run_parallel.sh -j 4      # limit to 4 parallel jobs
#   bash run_parallel.sh -d        # dry-run: just print the job list
# =============================================================

# ── SWEEP PARAMETERS ── edit these ─────────────────────────────────────────────
WORKLOADS=(  randread  randwrite  randrw  )
CMT_BYTES=(  16777216  67108864   268435456  )   # 16 MB / 64 MB / 256 MB
IO_SIZES=(   16G       64G                   )
IO_DEPTHS=(  64        128                   )
SSD_BLOCKS=( 1024      2048                  )   # 1024 = 102.4 TiB, 2048 = 204.8 TiB
FILL_RATIO=0.95
# ───────────────────────────────────────────────────────────────────────────────

MAX_JOBS=$(( $(nproc) / 2 )); (( MAX_JOBS < 1 )) && MAX_JOBS=1
DRY_RUN=0

while getopts "j:d" opt; do
  case $opt in
    j) MAX_JOBS="$OPTARG" ;;
    d) DRY_RUN=1 ;;
  esac
done

OUTDIR="outputs/parallel_$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Print plan ─────────────────────────────────────────────────────────────────
echo "SimpleSSD Parallel Runner"
echo "  Output dir  : $OUTDIR"
echo "  Max parallel: $MAX_JOBS"
echo ""

n=0
for wl in "${WORKLOADS[@]}"; do
  for cmt in "${CMT_BYTES[@]}"; do
    for io in "${IO_SIZES[@]}"; do
      for depth in "${IO_DEPTHS[@]}"; do
        for blocks in "${SSD_BLOCKS[@]}"; do
          (( n++ )) || true
          printf "  %3d) %-12s  cmt=%-8s  io=%-4s  depth=%-4s  ssd_blocks=%s\n" "$n" "$wl" "$(( cmt/1048576 ))MB" "$io" "$depth" "$blocks"
        done
      done
    done
  done
done
echo "  Total: $n jobs"
echo ""

if (( DRY_RUN )); then
  echo "  Dry-run — nothing launched."
  exit 0
fi

# ── Sanity checks ──────────────────────────────────────────────────────────────
[[ -x "./simplessd-standalone" ]]        || { echo "ERROR: binary not found"; exit 1; }
[[ -f "config/sample.cfg" ]]             || { echo "ERROR: config/sample.cfg missing"; exit 1; }
[[ -f "simplessd/config/sample.cfg" ]]   || { echo "ERROR: simplessd/config/sample.cfg missing"; exit 1; }

mkdir -p "$OUTDIR"

# ── Job function ───────────────────────────────────────────────────────────────
launch_job() {
  local wl="$1" cmt="$2" io="$3" depth="$4" blocks="$5"
  local cmt_mb=$(( cmt / 1048576 ))
  local label="${wl}_io${io}_cmt${cmt_mb}MB_d${depth}_b${blocks}"
  local outfile="$OUTDIR/$label.txt"
  local tmp
  tmp=$(mktemp -d "$SCRIPT_DIR/.sim_tmp_XXXXXX")

  # Patch the two config files into the private temp dir
  sed \
    -e "s|^readwrite *=.*|readwrite = $wl|" \
    -e "s|^io_size *=.*|io_size = $io|" \
    -e "s|^iodepth *=.*|iodepth = $depth|" \
    -e "s|^LogFile *=.*|LogFile =|" \
    -e "s|^LatencyLogFile *=.*|LatencyLogFile =|" \
    "config/sample.cfg" > "$tmp/standalone.cfg"

  sed \
    -e "s|^Block *=.*|Block = $blocks|" \
    -e "s|^CMTCapacityBytes *=.*|CMTCapacityBytes = $cmt|" \
    -e "s|^CMTCapacityRatio *=.*|CMTCapacityRatio = 0.0|" \
    -e "s|^FillRatio *=.*|FillRatio = $FILL_RATIO|" \
    -e "s|^EnableReadCache *=.*|EnableReadCache = 0|" \
    -e "s|^EnableWriteCache *=.*|EnableWriteCache = 0|" \
    "simplessd/config/sample.cfg" > "$tmp/simplessd.cfg"

  # Run in a background subshell
  # All output goes straight to $outfile — no pipes, no grep, no tricks
  (
    echo "=== $label ===" > "$outfile"
    echo "Workload : $wl  |  CMT : ${cmt_mb} MB  |  IO : $io" >> "$outfile"
    echo "Started  : $(date)" >> "$outfile"
    echo "" >> "$outfile"

    ./simplessd-standalone \
      "$tmp/standalone.cfg" \
      "$tmp/simplessd.cfg" \
      "$tmp/stats" >> "$outfile" 2>&1

    # Append per-subsystem stat files
    echo "" >> "$outfile"
    echo "=== SUBSYSTEM STATS ===" >> "$outfile"
    for f in "$tmp"/stats_*.txt; do
      [ -f "$f" ] && cat "$f" >> "$outfile"
    done

    echo "" >> "$outfile"
    echo "Finished : $(date)" >> "$outfile"

    rm -rf "$tmp"

    # This prints to the terminal (outside the >> redirect above)
    echo "[DONE] $label"
  ) &

  echo "[START] $label  (PID $!)"
}

# ── Job pool ───────────────────────────────────────────────────────────────────
pids=()
done_count=0
total=$n

for wl in "${WORKLOADS[@]}"; do
  for cmt in "${CMT_BYTES[@]}"; do
    for io in "${IO_SIZES[@]}"; do
      for depth in "${IO_DEPTHS[@]}"; do
        for blocks in "${SSD_BLOCKS[@]}"; do

          # If the pool is full, wait for the oldest job to finish
          if (( ${#pids[@]} >= MAX_JOBS )); then
            wait "${pids[0]}"
            pids=("${pids[@]:1}")
          fi

          launch_job "$wl" "$cmt" "$io" "$depth" "$blocks"
          pids+=($!)

        done
      done
    done
  done
done

# Wait for any jobs still running
echo ""
echo "Waiting for last ${#pids[@]} job(s)..."
for pid in "${pids[@]}"; do
  wait "$pid"
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "All $total jobs finished.  Results → $OUTDIR/"
echo ""
echo "CMT Hit Rates:"
printf "  %-45s  %s\n" "Run" "Hit Rate"
printf "  %-45s  %s\n" "---" "--------"
for f in "$OUTDIR"/*.txt; do
  rate=$(grep "cmt\.hit_rate" "$f" 2>/dev/null | awk '{print $2}' | tail -1)
  [ -n "$rate" ] && printf "  %-45s  %s%%\n" "$(basename "$f" .txt)" "$rate"
done
