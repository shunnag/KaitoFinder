# S37 = P11-K, round 3 of 3 (same thread, same worktree)

G2 passed. The orchestrator ran the gate twice more (alternating before/after, 7 rounds, medians). The second of them qualifies
(1-minute load 3.39 → 3.18): text 0.568, r0text 0.570, text1 ≈0.56, headers ≈0.73, small ≈0.78, small-zstd.zip 0.393,
headers-zstd.zip ≈0.45, random 1.003 (G1 0.979: +2.5 %), text19 0.970, textlong 0.987. Your random 1.034 was a loaded run.
Proceed with ONLY Stage 3 (zero-copy block output) of the spec, keeping Stages 1–2, then run the final acceptance items you can in the
sandbox (V1, V2, V4 mutants if feasible, V7, V8, the documents of acceptance item 7), report, and stop. The orchestrator runs the final
performance gate and RSS on the host. Keep the provenance rules of the spec. Do not commit.
