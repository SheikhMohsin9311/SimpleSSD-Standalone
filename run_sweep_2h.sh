#!/usr/bin/env bash
# =============================================================
# run_sweep_2h.sh — 2-hour CMT parameter sweep for SimpleSSD
# =============================================================
#
# Designed to complete in ~2 hours on a 12-core machine.
# Sweeps: Workload × CMT Size × IO Size × IO Depth
#
# HOW TO RUN
#   bash run_sweep_2h.sh            # run with auto-detected parallelism
#   bash run_sweep_2h.sh -j 4      # force 4 parallel jobs
#   bash run_sweep_2h.sh -d        # dry-run: print jobs, don't launch
#   bash run_sweep_2h.sh -p 0,1    # sweep both CMT policies (doubles runtime)
#
# TIMING ESTIMATES (wall time, assuming 12 cores → 6 parallel):
#   randwrite jobs :  1–5 min each
#   randrw jobs    :  5–15 min each
#   randread jobs  : 10–35 min each
#   Total ~72 jobs in 12 waves of 6 → ~2 hrs
# =============================================================

# ─────────────────────────────────────────────────────────────
#  SWEEP PARAMETERS — edit these to change the experiment
# ─────────────────────────────────────────────────────────────

WORKLOADS=(  randread  randwrite  randrw  )

# CMT replacement policies to sweep: 0 = LRU, 1 = LFU.
# Default is LRU only so the sweep still fits in ~2 hours.
# Override on the command line with -p 0,1 to compare both.
POLICIES=(  0  )

# CMT sizes in bytes.
# NOTE: these are real cache bytes. One CMT entry holds a whole superpage,
# which is 8 sub-page mappings of 8 B each = 64 B per entry on this config,
# so 2 MB is 32,768 entries. (Before the capacity fix the same value produced
# 262,144 entries, i.e. an actual 16 MB cache mislabelled as 2 MB.)
CMT_BYTES=(  524288   2097152   6291456   12582912   16777216  )   # 512KB / 2MB / 6MB / 12MB / 16MB

# Total IO issued by the trace generator (per job)
# 4G = fast,  8G = medium,  16G = slow but realistic
IO_SIZES=(   4G   8G   16G  )

# Queue depths — controls how many IOs are in flight simultaneously
IO_DEPTHS=(  32   64  )

# SSD physical block count (Block = N in [pal] section)
# 512 blocks = ~52 TiB SSD. Keep fixed to avoid runtime blowup.
SSD_BLOCKS=512

# NAND fill before the trace starts (fraction of total capacity)
FILL_RATIO=0.75

# ─────────────────────────────────────────────────────────────
#  SCRIPT INTERNALS — don't need to edit below this line
# ─────────────────────────────────────────────────────────────

# Default: leave 1 core free for the OS, use the rest
MAX_JOBS=$(( $(nproc) - 2 ))
(( MAX_JOBS < 1 )) && MAX_JOBS=1
DRY_RUN=0

while getopts "j:dp:" opt; do
  case $opt in
    j) MAX_JOBS="$OPTARG" ;;
    d) DRY_RUN=1 ;;
    p) IFS=',' read -r -a POLICIES <<< "$OPTARG" ;;
    *) echo "Usage: $0 [-j <jobs>] [-d] [-p <policies>]"; exit 1 ;;
  esac
done

policy_name() { [[ "$1" == "1" ]] && echo "LFU" || echo "LRU"; }

# Human-readable cache size. Uses KB below 1 MB so sub-megabyte sizes do not
# all collapse to "0MB" in labels and filenames.
size_label() {
  if (( $1 >= 1048576 )); then echo "$(( $1 / 1048576 ))MB"; else echo "$(( $1 / 1024 ))KB"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OUTDIR="outputs/sweep_2h_$(date +%Y%m%d_%H%M%S)"
LOGFILE="$OUTDIR/sweep.log"

# ─── Print the plan ───────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          SimpleSSD 2-Hour CMT Sweep                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Output dir  : $OUTDIR"
echo "  Max parallel: $MAX_JOBS"
echo "  SSD blocks  : $SSD_BLOCKS  (~$(( SSD_BLOCKS * 100 / 1024 )) TiB)"
echo "  Fill ratio  : $FILL_RATIO"
echo ""
echo "  Sweep grid:"
echo "    Workloads  : ${WORKLOADS[*]}"
echo "    CMT policy : $(for p in "${POLICIES[@]}"; do printf "%s " "$(policy_name "$p")"; done)"
echo "    CMT sizes  : $(for c in "${CMT_BYTES[@]}"; do printf "%s " "$(size_label "$c")"; done)"
echo "    IO sizes   : ${IO_SIZES[*]}"
echo "    IO depths  : ${IO_DEPTHS[*]}"
echo ""

# Count and list all jobs
n=0
for wl in "${WORKLOADS[@]}"; do
  for pol in "${POLICIES[@]}"; do
    for cmt in "${CMT_BYTES[@]}"; do
      for io in "${IO_SIZES[@]}"; do
        for depth in "${IO_DEPTHS[@]}"; do
          (( n++ )) || true
          printf "  %3d) %-10s  %s  cmt=%-6s  io=%-4s  depth=%s\n" \
            "$n" "$wl" "$(policy_name "$pol")" "$(size_label "$cmt")" "$io" "$depth"
        done
      done
    done
  done
done

echo ""
echo "  Total: $n jobs"
echo "  Estimated wall time: ~2 hours"
echo ""

if (( DRY_RUN )); then
  echo "  Dry-run — nothing launched."
  exit 0
fi

# ─── Sanity checks ───────────────────────────────────────────
[[ -x "./simplessd-standalone" ]]      || { echo "ERROR: binary ./simplessd-standalone not found"; exit 1; }
[[ -f "config/sample.cfg" ]]           || { echo "ERROR: config/sample.cfg missing"; exit 1; }
[[ -f "simplessd/config/sample.cfg" ]] || { echo "ERROR: simplessd/config/sample.cfg missing"; exit 1; }

mkdir -p "$OUTDIR"
START_TIME=$(date +%s)

echo "Sweep started at: $(date)" | tee "$LOGFILE"
echo "Parameters: workloads=${WORKLOADS[*]} cmt=${CMT_BYTES[*]} io=${IO_SIZES[*]} depth=${IO_DEPTHS[*]}" >> "$LOGFILE"
echo "" | tee -a "$LOGFILE"

# ─── Job launcher ────────────────────────────────────────────
launch_job() {
  local wl="$1" cmt="$2" io="$3" depth="$4" pol="$5"
  local cmt_size pol_name
  cmt_size="$(size_label "$cmt")"
  pol_name="$(policy_name "$pol")"
  local label="${wl}_${pol_name}_io${io}_cmt${cmt_size}_d${depth}"
  local outfile="$OUTDIR/$label.txt"
  local tmp
  tmp=$(mktemp -d "$SCRIPT_DIR/.sim_tmp_XXXXXX")

  # Patch standalone config
  # Point LogFile to a file inside the tmp dir so each job has its own stats
  sed \
    -e "s|^readwrite *=.*|readwrite = $wl|" \
    -e "s|^io_size *=.*|io_size = $io|" \
    -e "s|^iodepth *=.*|iodepth = $depth|" \
    -e "s|^LogFile *=.*|LogFile = $tmp/sim_stats.log|" \
    "config/sample.cfg" > "$tmp/standalone.cfg"

  # Patch simplessd config
  sed \
    -e "s|^Block *=.*|Block = $SSD_BLOCKS|" \
    -e "s|^CMTPolicy *=.*|CMTPolicy = $pol|" \
    -e "s|^CMTCapacityBytes *=.*|CMTCapacityBytes = $cmt|" \
    -e "s|^CMTCapacityRatio *=.*|CMTCapacityRatio = 0.0|" \
    -e "s|^FillRatio *=.*|FillRatio = $FILL_RATIO|" \
    -e "s|^EnableReadCache *=.*|EnableReadCache = 0|" \
    -e "s|^EnableWriteCache *=.*|EnableWriteCache = 0|" \
    "simplessd/config/sample.cfg" > "$tmp/simplessd.cfg"

  # Launch in background subshell
  (
    # Write header
    {
      echo "=== $label ==="
      echo "Workload : $wl  |  CMT : $cmt_size ($pol_name)  |  IO : $io  |  Depth : $depth"
      echo "SSD Blocks: $SSD_BLOCKS  |  Fill: $FILL_RATIO"
      echo "Started  : $(date)"
      echo ""
    } > "$outfile"

    # Run sim — stdout is already clean (ProgressPeriod=0 in config kills spam).
    # CMT/FTL/PAL metrics go to sim_stats.log via LogFile config.
    # The host-side summary (latency, IOPS, tick) goes to stdout and is
    # buffered here so it can be placed after the subsystem stats.
    ./simplessd-standalone \
      "$tmp/standalone.cfg" \
      "$tmp/simplessd.cfg" \
      "$tmp/stats" > "$tmp/run_summary.log" 2>&1

    # CMT/FTL/PAL/CPU metrics from LogFile
    echo "=== SUBSYSTEM STATS ===" >> "$outfile"
    if [ -f "$tmp/sim_stats.log" ]; then
      cat "$tmp/sim_stats.log" >> "$outfile"
    else
      echo "(WARNING: sim_stats.log not found)" >> "$outfile"
    fi

    # Host-side summary. The \33[2K...\r escape erases the progress line on a
    # TTY and is only noise in a file, so drop it.
    echo "" >> "$outfile"
    echo "=== RUN SUMMARY ===" >> "$outfile"
    sed -e 's/\x1b\[2K *\r//g' -e 's/\r$//' "$tmp/run_summary.log" >> "$outfile"

    echo "" >> "$outfile"
    echo "Finished : $(date)" >> "$outfile"

    rm -rf "$tmp"
    echo "[DONE] $label" | tee -a "$LOGFILE"
  ) &

  echo "[START] $label  (PID $!)" | tee -a "$LOGFILE"
}

# ─── Job pool ────────────────────────────────────────────────
echo "Launching jobs (max $MAX_JOBS in parallel)..."
echo ""

pids=()

for wl in "${WORKLOADS[@]}"; do
  for pol in "${POLICIES[@]}"; do
    for cmt in "${CMT_BYTES[@]}"; do
      for io in "${IO_SIZES[@]}"; do
        for depth in "${IO_DEPTHS[@]}"; do

          # Wait for a slot — as soon as ANY job finishes, launch a new one
          while (( ${#pids[@]} >= MAX_JOBS )); do
            wait -n "${pids[@]}"   # blocks until any one child exits
            # Prune all finished PIDs from the array
            live=()
            for pid in "${pids[@]}"; do
              kill -0 "$pid" 2>/dev/null && live+=("$pid")
            done
            pids=("${live[@]}")
          done

          launch_job "$wl" "$cmt" "$io" "$depth" "$pol"
          pids+=($!)

        done
      done
    done
  done
done

# Drain remaining jobs
echo ""
echo "Waiting for final ${#pids[@]} job(s) to finish..."
for pid in "${pids[@]}"; do
  wait "$pid"
done

# ─── Final summary ───────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  All $n jobs complete!  Elapsed: ~${ELAPSED} minutes"
echo "  Results → $OUTDIR/"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Print a summary table of CMT hit rates
echo "CMT Hit Rate Summary:"
printf "  %-50s  %s\n" "Run" "Hit Rate"
printf "  %-50s  %s\n" "$(printf '%0.s-' {1..50})" "--------"
for f in "$OUTDIR"/*.txt; do
  [ -f "$f" ] || continue
  rate=$(grep "cmt\.hit_rate" "$f" 2>/dev/null | awk '{print $2}' | tail -1)
  [ -n "$rate" ] && printf "  %-50s  %s%%\n" "$(basename "$f" .txt)" "$rate"
done

echo ""
echo "Sweep ended at: $(date)" | tee -a "$LOGFILE"
echo "Total elapsed: ~${ELAPSED} minutes" | tee -a "$LOGFILE"
