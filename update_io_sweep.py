import re

with open('run.sh', 'r') as f:
    data = f.read()

# 1. Update variables
data = re.sub(r'SWEEP_IO_SIZE="16G".*\n', 'SWEEP_IO_SIZES=( "4G" "16G" )\n', data)

# 2. Update make_label function arguments and echo
data = data.replace('fill="$7" evict="$8" rwmix="$9"', 'fill="$7" evict="$8" rwmix="$9" ios="${10}"')
data = data.replace('echo "${wl}_${pol_str}_${pref_str}_${size_str}_${bs}_fill${fill}_evict${evict}"',
                    'echo "${wl}_${pol_str}_${pref_str}_${size_str}_${bs}_ios${ios}_fill${fill}_evict${evict}"')

# 3. Update make_label call inside run_one
data = data.replace('"$fill" "$evict" "$rwmix"', '"$fill" "$evict" "$rwmix" "$ios"')

# 4. Replace the entire calc loop block safely
old_calc_loop = """  for wl in "${SWEEP_WORKLOADS[@]}"; do
    if [[ "$wl" == "randrw" ]]; then mixes=( "${SWEEP_RW_MIX_READ[@]}" ); else mixes=( "0.5" ); fi
    for rwmix in "${mixes[@]}"; do
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
  done"""

new_calc_loop = """  for ios in "${SWEEP_IO_SIZES[@]}"; do
    for wl in "${SWEEP_WORKLOADS[@]}"; do
      if [[ "$wl" == "randrw" ]]; then mixes=( "${SWEEP_RW_MIX_READ[@]}" ); else mixes=( "0.5" ); fi
      for rwmix in "${mixes[@]}"; do
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
    done
  done"""
data = data.replace(old_calc_loop, new_calc_loop)

# 5. Replace the entire exec loop block safely
old_exec_loop = """  for wl in "${SWEEP_WORKLOADS[@]}"; do
    if [[ "$wl" == "randrw" ]]; then mixes=( "${SWEEP_RW_MIX_READ[@]}" ); else mixes=( "0.5" ); fi
    for rwmix in "${mixes[@]}"; do
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
                      "$rwmix" "$SWEEP_EVICT_POLICY" &
                launched=$((launched + 1))
              done
            done
          done
        done
      done
    done
  done"""

new_exec_loop = """  for ios in "${SWEEP_IO_SIZES[@]}"; do
    for wl in "${SWEEP_WORKLOADS[@]}"; do
      if [[ "$wl" == "randrw" ]]; then mixes=( "${SWEEP_RW_MIX_READ[@]}" ); else mixes=( "0.5" ); fi
      for rwmix in "${mixes[@]}"; do
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
                        "$SWEEP_FILL_RATIO" "$ios" "$SWEEP_IO_DEPTH" \
                        "$rwmix" "$SWEEP_EVICT_POLICY" &
                  launched=$((launched + 1))
                done
              done
            done
          done
        done
      done
    done
  done"""
data = data.replace(old_exec_loop, new_exec_loop)

with open('run.sh', 'w') as f:
    f.write(data)
