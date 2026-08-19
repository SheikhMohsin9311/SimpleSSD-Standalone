#!/usr/bin/env bash
# =============================================================
# run_eviction_policies_long.sh
#
# Decently long SimpleSSD CMT eviction-policy experiment.
# Compares:
#   CMTPolicy = 0  LRU
#   CMTPolicy = 1  LFU
#
# Run:
#   bash run_eviction_policies_long.sh
#   bash run_eviction_policies_long.sh -j 4
#   bash run_eviction_policies_long.sh -d
#
# Results:
#   outputs/eviction_policies_long_<timestamp>/
#     *.txt         per-run logs
#     summary.csv   one row per run
#     sweep.log     start/finish log
# =============================================================

set -u

# ── Experiment grid ────────────────────────────────────────────────────────────
# These defaults are intentionally longer than run_sweep_2h.sh, but still
# bounded enough to run overnight or during a long work session on a laptop.
WORKLOADS=( randread randwrite randrw )
POLICIES=( 0 1 )
CMT_BYTES=( 524288 2097152 8388608 16777216 33554432 ) # 512KB / 2MB / 8MB / 16MB / 32MB
IO_SIZES=( 16G 32G )
IO_DEPTHS=( 64 128 )

# Keep the device shape fixed so the policy comparison is apples-to-apples.
SSD_BLOCKS=512
FILL_RATIO=0.85
RWMIXREAD=0.5

# Leave a little CPU headroom by default.
MAX_JOBS=$(( $(nproc) - 2 ))
(( MAX_JOBS < 1 )) && MAX_JOBS=1
DRY_RUN=0

while getopts "j:d" opt; do
  case "$opt" in
    j) MAX_JOBS="$OPTARG" ;;
    d) DRY_RUN=1 ;;
    *) echo "Usage: $0 [-j <parallel_jobs>] [-d]"; exit 1 ;;
  esac
done

policy_name() {
  case "$1" in
    0) echo "LRU" ;;
    1) echo "LFU" ;;
    *) echo "POLICY_$1" ;;
  esac
}

size_label() {
  if (( $1 >= 1048576 )); then
    echo "$(( $1 / 1048576 ))MB"
  else
    echo "$(( $1 / 1024 ))KB"
  fi
}

extract_stat() {
  local key="$1" file="$2"
  grep -E "(^|[[:space:]])${key}[[:space:]]" "$file" 2>/dev/null | awk '{print $2}' | tail -1
}

extract_summary_value() {
  local key="$1" file="$2"
  grep -E "$key" "$file" 2>/dev/null | tail -1 | awk '{print $NF}'
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

OUTDIR="outputs/eviction_policies_long_$(date +%Y%m%d_%H%M%S)"
LOGFILE="$OUTDIR/sweep.log"
SUMMARY="$OUTDIR/summary.csv"

total=0
for wl in "${WORKLOADS[@]}"; do
  for pol in "${POLICIES[@]}"; do
    for cmt in "${CMT_BYTES[@]}"; do
      for io in "${IO_SIZES[@]}"; do
        for depth in "${IO_DEPTHS[@]}"; do
          (( total++ )) || true
        done
      done
    done
  done
done

echo ""
echo "SimpleSSD CMT Eviction Policy Long Sweep"
echo "  Output dir  : $OUTDIR"
echo "  Max parallel: $MAX_JOBS"
echo "  Total jobs  : $total"
echo "  Policies    : LRU LFU"
echo "  Workloads   : ${WORKLOADS[*]}"
echo "  CMT sizes   : $(for c in "${CMT_BYTES[@]}"; do printf "%s " "$(size_label "$c")"; done)"
echo "  IO sizes    : ${IO_SIZES[*]}"
echo "  IO depths   : ${IO_DEPTHS[*]}"
echo "  SSD blocks  : $SSD_BLOCKS"
echo "  Fill ratio  : $FILL_RATIO"
echo ""

if (( DRY_RUN )); then
  idx=0
  for wl in "${WORKLOADS[@]}"; do
    for pol in "${POLICIES[@]}"; do
      for cmt in "${CMT_BYTES[@]}"; do
        for io in "${IO_SIZES[@]}"; do
          for depth in "${IO_DEPTHS[@]}"; do
            (( idx++ )) || true
            printf "  %3d) %-9s %-3s cmt=%-5s io=%-4s depth=%s\n" \
              "$idx" "$wl" "$(policy_name "$pol")" "$(size_label "$cmt")" "$io" "$depth"
          done
        done
      done
    done
  done
  echo ""
  echo "Dry-run only; no simulations launched."
  exit 0
fi

[[ -x "./simplessd-standalone" ]] || { echo "ERROR: ./simplessd-standalone not found or not executable"; exit 1; }
[[ -f "config/sample.cfg" ]] || { echo "ERROR: config/sample.cfg missing"; exit 1; }
[[ -f "simplessd/config/sample.cfg" ]] || { echo "ERROR: simplessd/config/sample.cfg missing"; exit 1; }

mkdir -p "$OUTDIR"
echo "started_at,$(date --iso-8601=seconds)" > "$LOGFILE"
echo "workload,policy,cmt_bytes,cmt_label,io_size,io_depth,ssd_blocks,fill_ratio,cmt_hit_rate,cmt_evictions,cmt_dirty_evictions,gc_count,nand_reads,nand_programs,host_write_bytes,nand_write_bytes,waf,run_seconds,outfile" > "$SUMMARY"

START_TIME=$(date +%s)

append_summary() {
  local outfile="$1" wl="$2" pol="$3" cmt="$4" cmt_label="$5" io="$6" depth="$7" run_seconds="$8"
  local hit evict dirty gc reads programs host_writes nand_writes waf

  hit=$(extract_stat "page_mapping\\.cmt\\.hit_rate" "$outfile")
  evict=$(extract_stat "page_mapping\\.cmt\\.evictions" "$outfile")
  dirty=$(extract_stat "page_mapping\\.cmt\\.dirty_evictions" "$outfile")
  gc=$(extract_stat "page_mapping\\.gc\\.count" "$outfile")
  reads=$(extract_stat "pal\\.read\\.count" "$outfile")
  programs=$(extract_stat "pal\\.program\\.count" "$outfile")
  host_writes=$(extract_stat "write\\.bytes" "$outfile")
  nand_writes=$(extract_stat "pal\\.program\\.bytes" "$outfile")

  if [[ -n "${host_writes:-}" && -n "${nand_writes:-}" ]] && awk "BEGIN { exit !($host_writes > 0) }"; then
    waf=$(awk "BEGIN { printf \"%.6f\", $nand_writes / $host_writes }")
  else
    waf=""
  fi

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$wl" "$(policy_name "$pol")" "$cmt" "$cmt_label" "$io" "$depth" "$SSD_BLOCKS" "$FILL_RATIO" \
    "${hit:-}" "${evict:-}" "${dirty:-}" "${gc:-}" "${reads:-}" "${programs:-}" \
    "${host_writes:-}" "${nand_writes:-}" "$waf" "$run_seconds" "$outfile" >> "$SUMMARY"
}

launch_job() {
  local wl="$1" pol="$2" cmt="$3" io="$4" depth="$5"
  local pol_name cmt_label label outfile tmp job_start job_end run_seconds

  pol_name="$(policy_name "$pol")"
  cmt_label="$(size_label "$cmt")"
  label="${wl}_${pol_name}_cmt${cmt_label}_io${io}_d${depth}"
  outfile="$OUTDIR/$label.txt"
  tmp=$(mktemp -d "$SCRIPT_DIR/.sim_tmp_XXXXXX")

  sed \
    -e "s|^readwrite *=.*|readwrite = $wl|" \
    -e "s|^rwmixread *=.*|rwmixread = $RWMIXREAD|" \
    -e "s|^io_size *=.*|io_size = $io|" \
    -e "s|^iodepth *=.*|iodepth = $depth|" \
    -e "s|^LogFile *=.*|LogFile = $tmp/sim_stats.log|" \
    -e "s|^LatencyLogFile *=.*|LatencyLogFile =|" \
    "config/sample.cfg" > "$tmp/standalone.cfg"

  sed \
    -e "s|^Block *=.*|Block = $SSD_BLOCKS|" \
    -e "s|^CMTPolicy *=.*|CMTPolicy = $pol|" \
    -e "s|^CMTCapacityBytes *=.*|CMTCapacityBytes = $cmt|" \
    -e "s|^CMTCapacityRatio *=.*|CMTCapacityRatio = 0.0|" \
    -e "s|^FillRatio *=.*|FillRatio = $FILL_RATIO|" \
    -e "s|^EnableReadCache *=.*|EnableReadCache = 0|" \
    -e "s|^EnableWriteCache *=.*|EnableWriteCache = 0|" \
    "simplessd/config/sample.cfg" > "$tmp/simplessd.cfg"

  (
    job_start=$(date +%s)
    {
      echo "=== $label ==="
      echo "Workload  : $wl"
      echo "Policy    : $pol_name ($pol)"
      echo "CMT       : $cmt_label ($cmt bytes)"
      echo "IO        : $io at depth $depth"
      echo "SSD       : Block=$SSD_BLOCKS, FillRatio=$FILL_RATIO"
      echo "Started   : $(date)"
      echo ""
    } > "$outfile"

    ./simplessd-standalone \
      "$tmp/standalone.cfg" \
      "$tmp/simplessd.cfg" \
      "$tmp/stats" > "$tmp/run_summary.log" 2>&1

    echo "=== SUBSYSTEM STATS ===" >> "$outfile"
    if [[ -f "$tmp/sim_stats.log" ]]; then
      cat "$tmp/sim_stats.log" >> "$outfile"
    else
      echo "(WARNING: sim_stats.log not found)" >> "$outfile"
    fi

    echo "" >> "$outfile"
    echo "=== RUN SUMMARY ===" >> "$outfile"
    sed -e 's/\x1b\[2K *\r//g' -e 's/\r$//' "$tmp/run_summary.log" >> "$outfile"

    job_end=$(date +%s)
    run_seconds=$(( job_end - job_start ))
    echo "" >> "$outfile"
    echo "Finished  : $(date)" >> "$outfile"
    echo "RunSeconds: $run_seconds" >> "$outfile"

    append_summary "$outfile" "$wl" "$pol" "$cmt" "$cmt_label" "$io" "$depth" "$run_seconds"
    rm -rf "$tmp"
    echo "[DONE] $label" | tee -a "$LOGFILE"
  ) &

  echo "[START] $label (PID $!)" | tee -a "$LOGFILE"
}

pids=()
for wl in "${WORKLOADS[@]}"; do
  for cmt in "${CMT_BYTES[@]}"; do
    for io in "${IO_SIZES[@]}"; do
      for depth in "${IO_DEPTHS[@]}"; do
        for pol in "${POLICIES[@]}"; do
          while (( ${#pids[@]} >= MAX_JOBS )); do
            wait -n "${pids[@]}"
            live=()
            for pid in "${pids[@]}"; do
              kill -0 "$pid" 2>/dev/null && live+=("$pid")
            done
            pids=("${live[@]}")
          done

          launch_job "$wl" "$pol" "$cmt" "$io" "$depth"
          pids+=($!)
        done
      done
    done
  done
done

echo ""
echo "Waiting for final ${#pids[@]} job(s)..."
for pid in "${pids[@]}"; do
  wait "$pid"
done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo "finished_at,$(date --iso-8601=seconds)" >> "$LOGFILE"
echo "elapsed_seconds,$ELAPSED" >> "$LOGFILE"

echo ""
echo "All $total jobs complete."
echo "Elapsed: $(( ELAPSED / 3600 ))h $(( (ELAPSED % 3600) / 60 ))m $(( ELAPSED % 60 ))s"
echo "Results: $OUTDIR"
echo ""
echo "Top summary by CMT hit rate:"
awk -F, 'NR > 1 && $9 != "" { print $9 "%  " $1 "  " $2 "  cmt=" $4 "  io=" $5 "  depth=" $6 "  waf=" $17 }' "$SUMMARY" \
  | sort -nr \
  | head -20
echo ""
echo "CSV summary: $SUMMARY"
