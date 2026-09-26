#!/bin/bash
# One measurement: bench-cell.sh <S> <corpus> <threads> <round> <phase>
# Appends one row to results/bench.tsv; raw stdout/time/uptime go to results/raw/.
set -euo pipefail
export LC_ALL=C
SP=/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad
P=$SP/p14; B=$SP/bcorp; V=$SP/p3val
n=$1 corpus=$2 t=$3 round=$4 phase=$5
bench=$P/S$n/GyoshukuKit/Benchmarks/.build/release/gyoshuku-bench
case $corpus in
  small) sources=("$B/small") ;;
  headers) sources=("$B/headers") ;;
  text) sources=("$B/text256.txt") ;;
  random) sources=("$B/random256.bin") ;;
  mixed) sources=("$B/headers" "$V/corp/rand20.bin" "$B/text256.txt" "$B/small") ;;
  payload) sources=("$P/payload/payload") ;;
  *) echo "unknown corpus $corpus" >&2; exit 2 ;;
esac
mkdir -p $P/out/S$n $P/results/raw
canon=$P/out/S$n/$corpus.tar.xz
out=$P/out/S$n/$corpus-t$t-r$round.tar.xz
rm -f "$out"
tag=$phase-r$round-S$n-$corpus-t$t
raw=$P/results/raw/$tag
printf '%q ' /usr/bin/time -l "$bench" txz "$out" "${sources[@]}" --threads "$t" > $raw.command; echo >> $raw.command
up_before=$(uptime | sed 's/.*load averages*: //')
/usr/bin/time -l "$bench" txz "$out" "${sources[@]}" --threads "$t" > $raw.stdout 2> $raw.time
up_after=$(uptime | sed 's/.*load averages*: //')
elapsed=$(sed -n 's/.*elapsed_s=\([0-9.]*\).*/\1/p' $raw.stdout)
bytes=$(stat -f %z "$out")
metrics=$(awk '$2=="real"{w=$1;u=$3;s=$5} /maximum resident set size/{r=$1} END{printf "%.3f\t%.3f\t%.3f\t%.1f", w,u,s,r/1048576}' $raw.time)
if [[ ! -e $canon ]]; then mv "$out" "$canon"; same=first
elif cmp -s "$out" "$canon"; then same=identical; rm -f "$out"
else same=DIFFERENT; mv "$out" "$P/out/S$n/$corpus-t$t-r$round.DIFF.tar.xz"; fi
[[ -f $P/results/bench.tsv ]] || printf 'phase\tround\tS_MiB\tcorpus\tthreads\tbench_elapsed_s\twall_s\tuser_s\tsys_s\tpeak_rss_mib\toutput_bytes\tvs_first_output\tload_before\tload_after\tdate\n' > $P/results/bench.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$phase" "$round" "$n" "$corpus" "$t" "$elapsed" "$metrics" "$bytes" "$same" "$up_before" "$up_after" "$(date +%H:%M:%S)" | tee -a $P/results/bench.tsv
