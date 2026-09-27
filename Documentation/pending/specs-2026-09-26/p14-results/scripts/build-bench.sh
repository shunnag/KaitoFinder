#!/bin/bash
# Build release gyoshuku-bench for each S variant (sequential).
set -euo pipefail
: "${SP:?Set SP to the scratchpad directory}"
P="$SP/p14"
export CLANG_MODULE_CACHE_PATH=$P/cache/clang
for n in "$@"; do
  start=$(date +%s)
  swift build -c release --build-system native --disable-sandbox --cache-path $P/cache \
    --package-path $P/S$n/GyoshukuKit/Benchmarks > $P/results/build/bench-S$n.log 2>&1
  echo "S$n bench built in $(( $(date +%s) - start )) s: $(swift build -c release --build-system native --disable-sandbox --cache-path $P/cache --package-path $P/S$n/GyoshukuKit/Benchmarks --show-bin-path)"
done
