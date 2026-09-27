# S37 = P11-K, round 1 of 3 (KaitoKit worktree)

Repository: ~/GitHub/KaitoKit-p11 (git worktree of KaitoKit, branch feature/2026-09-26-p11-zstd from 6a51d7a; the start
gate holds: clean tree, `Codecs/Zstd` and the zstd tests identical to 73c1b9f, inbox/zstd SHA-256 verified). Work only in this worktree.
Do not commit.

Your specification is exactly one file:
$SP/specs/final-p613/P11.md
Follow its CONSTRAINTS (including the provenance rules: use only this spec, the RFC/xxHash texts in inbox/zstd, and the KaitoKit
sources; do not read other files under the scratchpad) and its process rule 7: in this round implement ONLY Stage 1 (D0 and the
Stage 1 section), first building the `before` binary `.build/p11/kaito-before` from the base commit, then run V1 and V2 (and V5 once if
the sandbox allows), report, and stop. The orchestrator runs the G1 gate (V5, V6) on a quiet machine and resumes this thread for Stage 2.
Report exactly what ran.
