#!/bin/bash
# edit-cell.sh <S> <round> <threads> [ops]  — runs the harness edit set on out/S<n>/mixed.tar.xz
set -euo pipefail
P=/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad/p14
n=$1 round=$2 t=$3 ops=${4:-all}
mkdir -p $P/results/raw $P/work/S$n
raw=$P/results/raw/edit-r$round-S$n-t$t
cmd=($P/harness/.build-S$n/release/P14Harness edit $P/out/S$n/mixed.tar.xz $P/work/S$n S$n-r$round $t $ops)
printf '%q ' "${cmd[@]}" > $raw.command; echo >> $raw.command
up_before=$(uptime | sed 's/.*load averages*: //')
/usr/bin/time -l "${cmd[@]}" > $raw.stdout 2> $raw.time
up_after=$(uptime | sed 's/.*load averages*: //')
[[ -f $P/results/edit.tsv ]] || printf 'tag\tlabel\top\tthreads\tcommit_ms\tk5_ms\tfull_open_ms\tstrategy\treencoded_image_bytes\treencoded_old_image_bytes\tcarried_compressed_bytes\tcarried_chunks\treencoded_chunks\tscratch_bytes\tplan_ms\tencode_worker_ms\tcopy_ms\tselfcheck_ms\toutput_bytes\tbase_chunks\toutput_chunks\tload1\tload5\tload15\ttarget\tround\tS_MiB\tuptime_before_invocation\tuptime_after_invocation\n' > $P/results/edit.tsv
grep '^P14-EDIT' $raw.stdout | while IFS= read -r line; do printf '%s\t%s\t%s\t%s\t%s\n' "$line" "$round" "$n" "$up_before" "$up_after"; done | tee -a $P/results/edit.tsv
grep '^P14-BASE' $raw.stdout >> $P/results/edit-base.txt
awk '$2=="real"{print "harness wall " $1 " s"} /maximum resident set size/{printf "harness peak RSS %.1f MiB\n", $1/1048576}' $raw.time
