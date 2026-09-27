#!/bin/bash
# Reads "S corpus threads round phase" lines from a plan file and runs them in order.
set -uo pipefail
: "${SP:?Set SP to the scratchpad directory}"
P="$SP/p14"
while read -r n corpus t round phase; do
  [[ -z ${n:-} || $n == \#* ]] && continue
  $P/bench-cell.sh "$n" "$corpus" "$t" "$round" "$phase" || echo "FAILED $n $corpus $t $round $phase" | tee -a $P/results/failures.log
done < "$1"
