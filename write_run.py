#!/usr/bin/env python3

content = r"""#!/usr/bin/env bash
# =============================================================================
# run.sh -- SimpleSSD CMT Prefetch Experiment Runner
#
# USAGE
#   bash run.sh                  # single run with settings from SECTION 1
#   TEST_MODE=true bash run.sh   # prefetch validation test (sequential read)
#   SWEEP_MODE=true bash run.sh  # sweep all combinations from SECTION 2
#
# OUTPUT
#   outputs/<label>.txt   -- full subsystem stats + run summary
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# SECTION 1: SINGLE-RUN CONFIGURATION
# -----------------------------------------------------------------------------

WORKLOAD="${WORKLOAD:-randread}"     # randread | randwrite | randrw | read | write
IO_SIZE="${IO_SIZE:-4G}"             # total I/O to issue  (e.g. 512M, 2G, 8G)
BLOCK_SIZE="${BLOCK_SIZE:-4K}"       # request size        (e.g. 4K, 16K, 64K)
IO_DEPTH="${IO_DEPTH:-32}"           # async queue depth   (1 = synchronous)
RW_MIX_READ="${RW_MIX_READ:-0.5}"    # read fraction for randrw (ignored otherwise)

CMT_POLICY="${CMT_POLICY:-0}"        # 0 = LRU  |  1 = LFU
CMT_BYTES="${CMT_BYTES:-2097152}"    # CMT size in bytes  (2097152 = 2 MiB)
FILL_RATIO="${FILL_RATIO:-1.0}"      # warm-up fill level  (0.0 to 1.0)
EVICT_POLICY="${EVICT_POLICY:-0}"    # GC victim selection: 0=greedy 1=cost-benefit 2=random 3=d-choice

PREFETCH_ENABLE="${PREFETCH_ENABLE:-false}" # CMT spatial prefetch: true | false
PREFETCH_WINDOW="${PREFETCH_WINDOW:-512}"   # LPNs per aligned window (only used if PREFETCH_ENABLE=true)

OUTPUT_DIR="${OUTPUT_DIR:-outputs}"         # directory to write .log files into
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}" # Live progress update interval in seconds

# -----------------------------------------------------------------------------
# SECTION 2: SWEEP & TEST CONFIGURATION
# -----------------------------------------------------------------------------

SWEEP_MODE="${SWEEP_MODE:-false}"
TEST_MODE="${TEST_MODE:-false}"
MAX_PARALLEL=4           # how many simulator processes to run at once in sweep mode

SWEEP_WORKLOADS=( "read" "randread" "randrw" )
SWEEP_CMT_BYTES=( 524288 2097152 8388608 16777216 )   # 512K, 2M, 8M, 16M
SWEEP_BLOCK_SIZES=( "4K" )
SWEEP_CMT_POLICIES=( 0 1 )                   # LRU + LFU
SWEEP_PREFETCH=( "false" "true" )
SWEEP_PREFETCH_WINDOWS=( 512 )                 # Fixed to 1 translation page
SWEEP_FILL_RATIO=1.0
SWEEP_IO_SIZE="4G"
SWEEP_IO_DEPTH=32
SWEEP_RW_MIX_READ=0.5
SWEEP_EVICT_POLICY=0

# -----------------------------------------------------------------------------
# SECTION 3: RUN LOGIC
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/simplessd-standalone"
BASE_CFG="$SCRIPT_DIR/config/sample.cfg"
SSD_CFG="$SCRIPT_DIR/simplessd/config/sample.cfg"

# Sanity checks
[[ -x "$BINARY"   ]] || { echo "ERROR: binary not found: $BINARY"; exit 1; }
[[ -f "$BASE_CFG" ]] || { echo "ERROR: missing: $BASE_CFG"; exit 1; }
[[ -f "$SSD_CFG"  ]] || { echo "ERROR: missing: $SSD_CFG"; exit 1; }

mkdir -p "$OUTPUT_DIR"

# Convert size string (e.g. 4K, 2G, 512M) to bytes
size_to_bytes() {
  local val=$(echo "$1" | sed -E 's/([0-9]+)([A-Za-z]+)/\1 \2/')
  local num=$(echo "$val" | awk '{print $1}')
  local unit=$(echo "$val" | awk '{print $2}' | tr '[:lower:]' '[:upper:]' | head -c 1)
  
  case "$unit" in
    K) echo $(awk "BEGIN {printf \"%.0f\", $num * 1024}") ;;
    M) echo $(awk "BEGIN {printf \"%.0f\", $num * 1024 * 1024}") ;;
    G) echo $(awk "BEGIN {printf \"%.0f\", $num * 1024 * 1024 * 1024}") ;;
    T) echo $(awk "BEGIN {printf \"%.0f\", $num * 1024 * 1024 * 1024 * 1024}") ;;
    *) echo "$num" ;;
  esac
}

make_label() {
  local wl="$1" cmt_b="$2" bs="$3" pol="$4" pref="$5" win="$6" fill="$7" evict="$8"
  local pol_str="LRU"; [[ "$pol" == "1" ]] && pol_str="LFU"
  local pref_str="PF_OFF"; [[ "$pref" == "true" ]] && pref_str="PF_ON_W${win}"
  local size_str
  if (( cmt_b < 1048576 )); then
    size_str="$(( cmt_b / 1024 ))KiB"
  else
    size_str="$(( cmt_b / 1048576 ))MiB"
  fi
  echo "${wl}_${pol_str}_${pref_str}_${size_str}_${bs}_fill${fill}_evict${evict}"
}

run_one() {
  local wl="$1" cmt_b="$2" bs="$3" pol="$4" pref="$5" win="$6" \
        fill="$7" ios="$8" iodepth="$9" rwmix="${10}" evict="${11}"

  local label
  label=$(make_label "$wl" "$cmt_b" "$bs" "$pol" "$pref" "$win" "$fill" "$evict")
  local outfile="$OUTPUT_DIR/${label}.txt"

  local tmp
  tmp=$(mktemp -d "$SCRIPT_DIR/.sim_tmp_XXXXXX")
  local statsfile="$tmp/stats.log"

  # Patch LogPeriod=5000 in standalone config so we get live stats updates
  sed \
    -e "s|^readwrite *=.*|readwrite = $wl|" \
    -e "s|^blocksize *=.*|blocksize = $bs|" \
    -e "s|^io_size *=.*|io_size = $ios|" \
    -e "s|^iodepth *=.*|iodepth = $iodepth|" \
    -e "s|^rwmixread *=.*|rwmixread = $rwmix|" \
    -e "s|^LogFile *=.*|LogFile = $statsfile|" \
    -e "s|^LogPeriod *=.*|LogPeriod = 5000|" \
    -e "s|^LatencyLogFile *=.*|LatencyLogFile =|" \
    "$BASE_CFG" > "$tmp/standalone.cfg"

  sed \
    -e "s|^CMTCapacityBytes *=.*|CMTCapacityBytes = $cmt_b|" \
    -e "s|^CMTCapacityRatio *=.*|CMTCapacityRatio = 0.0|" \
    -e "s|^CMTPolicy *=.*|CMTPolicy = $pol|" \
    -e "s|^CMTSpatialPrefetch *=.*|CMTSpatialPrefetch = $pref|" \
    -e "s|^CMTPrefetchWindow *=.*|CMTPrefetchWindow = $win|" \
    -e "s|^FillRatio *=.*|FillRatio = $fill|" \
    -e "s|^EvictPolicy *=.*|EvictPolicy = $evict|" \
    -e "s|^EnableReadCache *=.*|EnableReadCache = 0|" \
    -e "s|^EnableWriteCache *=.*|EnableWriteCache = 0|" \
    "$SSD_CFG" > "$tmp/simplessd.cfg"

  if [[ "$SWEEP_MODE" != "true" ]]; then echo "  -> $label"; fi

  local summary="$tmp/summary.log"
  # Run the simulator in the background
  "$BINARY" "$tmp/standalone.cfg" "$tmp/simplessd.cfg" "$tmp/statprefix" \
    > "$summary" 2>&1 || true &
  local sim_pid=$!

  local io_bytes=$(size_to_bytes "$ios")
  local blk_bytes=$(size_to_bytes "$bs")
  local expected_ops=$(awk "BEGIN {printf \"%.0f\", $io_bytes / $blk_bytes}")
  local start_time=$(date +%s)

  # Live progress poller (only if we're not sweeping)
  if [[ "$PROGRESS_INTERVAL" -lt 999999 ]]; then
    while kill -0 $sim_pid 2>/dev/null; do
      sleep "$PROGRESS_INTERVAL"
      
      if [[ -f "$statsfile" && -s "$statsfile" ]]; then
        local hits=$(grep "cmt.hits" "$statsfile" | tail -n1 | awk '{print $2}' | cut -d'.' -f1 || echo "0")
        local misses=$(grep "cmt.misses" "$statsfile" | tail -n1 | awk '{print $2}' | cut -d'.' -f1 || echo "0")
        local hr=$(grep "cmt.hit_rate" "$statsfile" | tail -n1 | awk '{printf "%.2f", $2}' || echo "0.00")
        local acc=$(grep "prefetch_accuracy_percent" "$statsfile" | tail -n1 | awk '{printf "%.2f", $2}' || echo "0.00")
        local ins=$(grep "prefetch_insertions" "$statsfile" | tail -n1 | awk '{print $2}' | cut -d'.' -f1 || echo "0")
        
        local total_ops=$((hits + misses))
        local pct="0.0"
        if [[ "$expected_ops" -gt 0 ]]; then
          pct=$(awk "BEGIN {printf \"%.1f\", ($total_ops / $expected_ops) * 100}")
          # Cap at 100.0%
          if awk "BEGIN {exit !($pct > 100.0)}"; then pct="100.0"; fi
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        printf "\r\033[K[ %3ds ] Progress: %5.1f%% | CMT hit rate: %s%% | PF accuracy: %s%% | PF insertions: %s" \
               "$elapsed" "$pct" "$hr" "$acc" "$ins"
      fi
    done
    
    # Clear progress line
    printf "\r\033[K"
  fi

  wait $sim_pid

  {
    echo "=== SimpleSSD Simulation ==="
    echo "Started         : $(date)"
    echo ""
    echo "--- Configuration ---"
    echo "Workload        : $wl"
    echo "IO Size         : $ios"
    echo "Block Size      : $bs"
    echo "CMT Policy      : $( [ "$pol" = "0" ] && echo "LRU" || echo "LFU" )"
    echo "CMT Capacity    : $cmt_b Bytes"
    echo "Spatial Prefetch: $( [ "$pref" = "true" ] && echo "ON" || echo "OFF" )"
    if [ "$pref" = "true" ]; then
      echo "Prefetch Window : $win"
    else
      echo "Prefetch Window : N/A"
    fi
    echo "Eviction Policy : $evict"
    echo "Fill Ratio      : $fill"
    echo "============================="
    echo ""
    echo "=== SUBSYSTEM STATS ==="
    if [[ -f "$statsfile" && -s "$statsfile" ]]; then
      # Strip out the periodic log banners to only show final stats
      awk '/Periodic log printout/{flag=1; buf=""} 
           !/Periodic log printout/ && !/End of log/{if(flag) buf = buf $0 "\n"} 
           /End of log/{flag=0} 
           END{print buf}' "$statsfile" || cat "$statsfile"
    else
      echo "(WARNING: stats file empty or missing)"
    fi
    echo ""
    echo "=== RUN SUMMARY ==="
    sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' "$summary"
    echo ""
    echo "Finished: $(date)"
  } > "$outfile"

  rm -rf "$tmp"

  local final_hit=$(grep "cmt\.hit_rate" "$outfile" | tail -n1 | awk '{printf "%.2f", $2}' || echo "N/A")
  local final_acc=$(grep "prefetch_accuracy_percent" "$outfile" | tail -n1 | awk '{printf "%.1f", $2}' || echo "N/A")
  
  if [[ "$SWEEP_MODE" != "true" ]]; then
    if [[ "$final_hit" != "N/A" ]]; then
      printf "     CMT hit rate: %s%%   prefetch accuracy: %s%%\n" "$final_hit" "$final_acc"
    fi
    echo "     Log: $outfile"
  fi
}

# ── Test mode ─────────────────────────────────────────────────────────────────
if [[ "$TEST_MODE" == "true" ]]; then
  echo "SimpleSSD -- PF validation test (Sequential Read)"
  echo ""
  
  # Run A: PF OFF
  run_one "read" "2097152" "4K" "0" "false" "512" "1.0" "2G" "32" "0.5" "0"
  
  # Run B: PF ON
  run_one "read" "2097152" "4K" "0" "true" "512" "1.0" "2G" "32" "0.5" "0"
  
  echo ""
  echo "Test done."
  exit 0
fi

# ── Sweep mode ────────────────────────────────────────────────────────────────
if [[ "$SWEEP_MODE" == "true" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR}/sweep_$(date +%b%d_%I-%M%p)"
  mkdir -p "$OUTPUT_DIR"

  echo "SimpleSSD -- sweep mode"
  echo "  Output dir   : $OUTPUT_DIR"
  echo "  Max parallel : $MAX_PARALLEL"
  echo ""

  # Calculate total jobs
  TOTAL_JOBS=0
  for wl in "${SWEEP_WORKLOADS[@]}"; do
    for cmt_b in "${SWEEP_CMT_BYTES[@]}"; do
      for bs in "${SWEEP_BLOCK_SIZES[@]}"; do
        for pol in "${SWEEP_CMT_POLICIES[@]}"; do
          for pref in "${SWEEP_PREFETCH[@]}"; do
            if [[ "$pref" == "false" ]]; then windows=( "${SWEEP_PREFETCH_WINDOWS[0]}" ); else windows=( "${SWEEP_PREFETCH_WINDOWS[@]}" ); fi
            for win in "${windows[@]}"; do
              TOTAL_JOBS=$((TOTAL_JOBS + 1))
            done
          done
        done
      done
    done
  done

  echo "  Total Jobs   : $TOTAL_JOBS"
  echo ""

  # Start the progress poller in the background
  (
    start_time=$(date +%s)
    completed=0
    while [[ $completed -lt $TOTAL_JOBS ]]; do
      sleep 5
      completed=$(ls -1q "$OUTPUT_DIR"/*.txt 2>/dev/null | wc -l || echo 0)
      pct=$(awk "BEGIN {printf \"%.1f\", ($completed / $TOTAL_JOBS) * 100}")
      elapsed=$(($(date +%s) - start_time))
      
      eta_str="--:--"
      if [[ $completed -gt 0 && $completed -lt $TOTAL_JOBS ]]; then
          eta=$(( (elapsed / completed) * (TOTAL_JOBS - completed) ))
          eta_str=$(printf "%02dm %02ds" $((eta/60)) $((eta%60)))
      fi
      
      latest_hr="N/A"
      latest_file=$(ls -1tr "$OUTPUT_DIR"/*.txt 2>/dev/null | tail -n1)
      if [[ -n "$latest_file" && -f "$latest_file" ]]; then
          latest_hr=$(grep "cmt\.hit_rate" "$latest_file" | tail -n1 | awk '{printf \"%.2f\", $2}' || echo "N/A")
      fi

      printf "\r\033[K[ %3ds ] Sweep Progress: %3d / %3d ( %5.1f%% ) | ETA: %-7s | Last Hit Rate: %s%%" \
             "$elapsed" "$completed" "$TOTAL_JOBS" "$pct" "$eta_str" "$latest_hr"
      
      if [[ $completed -eq $TOTAL_JOBS ]]; then break; fi
    done
    printf "\n"
  ) &
  POLLER_PID=$!

  launched=0
  for wl in "${SWEEP_WORKLOADS[@]}"; do
    for cmt_b in "${SWEEP_CMT_BYTES[@]}"; do
      for bs in "${SWEEP_BLOCK_SIZES[@]}"; do
        for pol in "${SWEEP_CMT_POLICIES[@]}"; do
          for pref in "${SWEEP_PREFETCH[@]}"; do
            if [[ "$pref" == "false" ]]; then
              windows=( "${SWEEP_PREFETCH_WINDOWS[0]}" )
            else
              windows=( "${SWEEP_PREFETCH_WINDOWS[@]}" )
            fi
            for win in "${windows[@]}"; do
              while (( $(jobs -r | wc -l) >= MAX_PARALLEL + 1 )); do sleep 0.5; done
              # For sweep mode, disable live progress to prevent terminal garbling
              PROGRESS_INTERVAL=999999 run_one "$wl" "$cmt_b" "$bs" "$pol" "$pref" "$win" \
                      "$SWEEP_FILL_RATIO" "$SWEEP_IO_SIZE" "$SWEEP_IO_DEPTH" \
                      "$SWEEP_RW_MIX_READ" "$SWEEP_EVICT_POLICY" &
              launched=$((launched + 1))
            done
          done
        done
      done
    done
  done

  wait $POLLER_PID
  wait
  echo ""
  echo "All done. Logs in: $OUTPUT_DIR/"
  exit 0
fi

# ── Single-run mode ───────────────────────────────────────────────────────────
echo "SimpleSSD -- single run"
echo ""
run_one "$WORKLOAD" "$CMT_BYTES" "$BLOCK_SIZE" "$CMT_POLICY" \
        "$PREFETCH_ENABLE" "$PREFETCH_WINDOW" "$FILL_RATIO" \
        "$IO_SIZE" "$IO_DEPTH" "$RW_MIX_READ" "$EVICT_POLICY"
echo ""
echo "Done."
"""

with open('run.sh', 'w') as f:
    f.write(content)
