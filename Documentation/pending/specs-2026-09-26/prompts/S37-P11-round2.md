# S37 = P11-K, round 2 of 3 (same thread, same worktree)

G1 passed. The orchestrator re-ran the gate (alternating before/after, 7 rounds, medians; 1-minute load 5.1–6.1 because the machine is
shared, so under the spec's rule every run must pass — both your run and this one do):
text.tar.zst open 0.673, r0text.tar.zst open 0.605, text1.tar.zst open 0.702, headers.tar.zst 0.782, small.tar.zst 0.791,
small-zstd.zip extract 0.905, headers-zstd.zip extract 0.770, random 0.979, text19 0.973, textlong 1.003.
Proceed with ONLY Stage 2 (Huffman) of the spec, keeping Stage 1 as is, then run V1 and V2 (and V5 once if the sandbox allows),
report, and stop. The orchestrator then runs G2. Keep the provenance rules of the spec. Do not commit.
