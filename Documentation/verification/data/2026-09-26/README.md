# 2026-09-26 の受入計測のデータ

scratchpad はセッションの外に残らないので、検証記録が参照する計測をここに残す。列は `PROBE-TSV` と同じ。

| ファイル | 中身 |
|---|---|
| `p2-bp2-vs-s13-{100k,500k}.txt` | P2 の受入計測。B-P2 を採り直した値と S13（f47d361）の値を行ごとに並べ、比を付けたもの（`format fixture mode operation stage 基準 新 比`） |
| `p3-bp3-vs-s16-{100k,500k}.txt` | P3 の受入計測。B-P3（2 回目）と S16（d6bcfb4）の比較。同じ形式 |
| `p12-ac10-summary.txt`、`p12-{base,after}-r{1..4}.tsv` | P12 の AC10。B-P12（71549c2）と P12-1（e48d8ad）を交互に 4 回ずつ採った生の行と、中央値の判定 |
| `bp4-baseline-100k.tsv` | S21（P4-A）の比較に使う基準 B-P4（KaitoKit d35f2da、GyoshukuKit a03833e、KaitoFinder 7b623b4、100k 全形式と本文 256 MiB）。先頭と末尾の行は `uptime`。負荷の平均 7.6〜13.3 の中で採ったので、S21 の計測では同じ三つ組を交互に採り直して比べる |
| `p4-bp4-vs-s21-100k.txt` | S21（P4-A）の受入計測の回 1。B-P4 と S21（ac5cab9）の 100k 全形式と本文 256 MiB（追加は末尾）。上と同じ形式 |
| `p4-bp4-vs-s21-lha-beginning.txt` | 回 2。LHA だけ、`KAITOFINDER_PROBE_ADDITION_PLACEMENT=beginning` |
| `p4-bp4-vs-s21-recheck.txt` | 回 3。7z・tar・tar.xz の測り直し |
