#!/bin/bash
P=/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad/p14
while read -r n corpus method round; do
  [[ -z ${n:-} ]] && continue
  $P/decode-cell.sh "$n" "$corpus" "$method" "$round" || echo "FAILED decode $n $corpus $method $round" | tee -a $P/results/failures.log
done < "$1"
echo PHASE-D-DONE
