#!/bin/bash
# Reads "S corpus threads round phase" lines from a plan file and runs them in order.
set -uo pipefail
P=/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad/p14
while read -r n corpus t round phase; do
  [[ -z ${n:-} || $n == \#* ]] && continue
  $P/bench-cell.sh "$n" "$corpus" "$t" "$round" "$phase" || echo "FAILED $n $corpus $t $round $phase" | tee -a $P/results/failures.log
done < "$1"
