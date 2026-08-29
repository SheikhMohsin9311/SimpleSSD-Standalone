import re
with open('run.sh', 'r') as f:
    data = f.read()

# Fix calc loop
data = data.replace('  for wl in "${SWEEP_WORKLOADS[@]}"; do\n    if [[ "$wl" == "randrw" ]]',
                    '  for ios in "${SWEEP_IO_SIZES[@]}"; do\n    for wl in "${SWEEP_WORKLOADS[@]}"; do\n      if [[ "$wl" == "randrw" ]]')
# Add a `done` before `echo "  Total Jobs   : $TOTAL_JOBS"`
data = data.replace('  echo "  Total Jobs   : $TOTAL_JOBS"', '  done\n  echo "  Total Jobs   : $TOTAL_JOBS"')

# Fix exec loop (same string replacement)
data = data.replace('  for wl in "${SWEEP_WORKLOADS[@]}"; do\n    if [[ "$wl" == "randrw" ]]',
                    '  for ios in "${SWEEP_IO_SIZES[@]}"; do\n    for wl in "${SWEEP_WORKLOADS[@]}"; do\n      if [[ "$wl" == "randrw" ]]')
# Add a `done` before `wait $POLLER_PID`
data = data.replace('  wait $POLLER_PID', '  done\n  wait $POLLER_PID')

with open('run.sh', 'w') as f:
    f.write(data)
