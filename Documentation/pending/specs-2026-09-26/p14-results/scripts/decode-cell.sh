#!/bin/bash
# decode-cell.sh <S> <corpus> <method: xz1|xzT0|kk-plain|kk-layout> <round>
set -euo pipefail
export LC_ALL=C
: "${SP:?Set SP to the scratchpad directory}"
P="$SP/p14"
n=$1 corpus=$2 method=$3 round=$4
f=$P/out/S$n/$corpus.tar.xz
raw=$P/results/raw/decode-r$round-S$n-$corpus-$method
case $method in
  xz1) cmd=(/bin/sh -c 'xz -T1 -dc "$1" > /dev/null' _ "$f") ;;
  xzT0) cmd=(/bin/sh -c 'xz -T0 -dc "$1" > /dev/null' _ "$f") ;;
  kk-plain) cmd=($P/harness/.build-S$n/release/P14Harness open "$f" S$n plain) ;;
  kk-layout) cmd=($P/harness/.build-S$n/release/P14Harness open "$f" S$n layout) ;;
esac
printf '%q ' /usr/bin/time -l "${cmd[@]}" > $raw.command; echo >> $raw.command
up_before=$(uptime | sed 's/.*load averages*: //')
/usr/bin/time -l "${cmd[@]}" > $raw.stdout 2> $raw.time
up_after=$(uptime | sed 's/.*load averages*: //')
metrics=$(awk '$2=="real"{w=$1;u=$3;s=$5} /maximum resident set size/{r=$1} END{printf "%.3f\t%.3f\t%.3f\t%.1f", w,u,s,r/1048576}' $raw.time)
inner=$(awk -F'\t' '$1=="P14-OPEN"{print $5"\t"$6"\t"$7}' $raw.stdout); [[ -n $inner ]] || inner=$'-\t-\t-'
[[ -f $P/results/decode.tsv ]] || printf 'round\tS_MiB\tcorpus\tmethod\twall_s\tuser_s\tsys_s\tpeak_rss_mib\topen_ms_inprocess\tentries\tchunks\tload_before\tload_after\tdate\n' > $P/results/decode.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$round" "$n" "$corpus" "$method" "$metrics" "$inner" "$up_before" "$up_after" "$(date +%H:%M:%S)" | tee -a $P/results/decode.tsv
