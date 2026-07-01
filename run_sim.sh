#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="./outputs"
OUTPUT_FILE="$OUTPUT_DIR/${1:-run_$(date +%Y%m%d_%H%M%S).txt}"

mkdir -p ./result
mkdir -p "$OUTPUT_DIR"

cmake -DDEBUG_BUILD=on
make -j 12
./simplessd-standalone ./config/sample.cfg ./simplessd/config/sample.cfg ./result >> "$OUTPUT_FILE"

echo "Simulation output appended to: $OUTPUT_FILE"
