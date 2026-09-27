# 残りの段の仕様（2026-09-26 時点の凍結）

作業中の scratchpad（`/private/tmp/...`）はセッションの外に残らないので、Codex の利用上限で止まった段を再開するための仕様と指示文をここに写した。
文中の `SP` / `scratchpad` / `$SCR` のパスは当時の scratchpad を指す。fixture・計測の書庫などの参照先は、再開時に作り直すか、このディレクトリと
`../../verification/` の記録から読み替える（Step 0-P4 / Step 0-P5 の fixture は、KaitoKit の `Tests/Fixtures/lha-raw-layout/` と
`Tests/Fixtures/sevenzip-edit/` に取り込み済み。GyoshukuKit 側の 7z の fixture は `git stash` の中にある）。

- 実装順と接点: `ORDER-P2-P3.md`（S10–S17）、`ORDER-P4-P5.md`（S18–S26）、`ORDER-P6-P13.md`（S27–S44。§6 が利用者に諮る点）
- 残りの段の仕様: `P4.md`（P4-A = S21）、`P5.md`（P5-G = S24、P5-A = S25）、`P12-P13-P1d.md`（P1d-A = S33）、`P8-P9-P10.md`（P8 = S34、
  P10 = S35・S36）、`P6-P7.md`（S38–S41）、`P11.md`（S37。Codex にはこのファイルだけを渡す）。`P3-A.md` は P4-A・P5-A が参照する
- `prompts/`: 止まった段の Codex への指示文（S21、S24 とその改訂 S24-c1、S37 の各回）
- 状態と再開の順は `../2026-09-24-large-archive-edit-plan.md` の「状態（2026-09-26 10:00）」
