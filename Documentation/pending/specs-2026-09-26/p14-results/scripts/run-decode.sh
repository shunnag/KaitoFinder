#!/bin/bash
: "${SP:?Set SP to the scratchpad directory}"
P="$SP/p14"
while read -r n corpus method round; do
  [[ -z ${n:-} ]] && continue
  $P/decode-cell.sh "$n" "$corpus" "$method" "$round" || echo "FAILED decode $n $corpus $method $round" | tee -a $P/results/failures.log
done < "$1"
echo PHASE-D-DONE
