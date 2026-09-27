#!/bin/bash
# edit-cell2.sh <S> <round> <threads> <base-name> <ops> — like edit-cell.sh for an arbitrary base in out/S<n>/<base-name>.tar.xz
set -euo pipefail
: "${SP:?Set SP to the scratchpad directory}"
P="$SP/p14"
n=$1 round=$2 t=$3 base=$4 ops=$5
mkdir -p $P/results/raw $P/work/S$n
raw=$P/results/raw/edit2-$base-r$round-S$n-t$t
cmd=($P/harness/.build-S$n/release/P14Harness edit $P/out/S$n/$base.tar.xz $P/work/S$n S$n-$base-r$round $t $ops)
printf '%q ' "${cmd[@]}" > $raw.command; echo >> $raw.command
up_before=$(uptime | sed 's/.*load averages*: //')
/usr/bin/time -l "${cmd[@]}" > $raw.stdout 2> $raw.time
up_after=$(uptime | sed 's/.*load averages*: //')
grep '^P14-EDIT' $raw.stdout | while IFS= read -r line; do printf '%s\t%s\t%s\t%s\t%s\n' "$line" "$round" "$n" "$up_before" "$up_after"; done | tee -a $P/results/edit.tsv
grep '^P14-BASE' $raw.stdout >> $P/results/edit-base.txt
