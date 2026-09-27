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
| `p1d-bp1d-vs-s33-500k-r{1,2}.txt`、`p1d-bp1d-vs-s33-100k.txt` | S33（P1d-A）の受入計測。B-P1d（KaitoFinder ac5cab9）と S33 を `KAITOFINDER_PROBE_WARM_INDEX=1` で交互に採った比較（zip 500k を 2 回、zip・tar・tar.gz 100k と本文 256 MiB を 1 回） |
| `p5-bp5-vs-s25-100k-r{1,2}.txt`、`p5-bp5-vs-s25-7z-beginning.txt`、`p5-s25-password-{pw,pwbeg}.tsv`、`p5-s25-acceptance.txt` | S25（P5-A）の受入計測。B-P5 = KaitoFinder 41d48f0（S25 の直前）、S25 = 7494da5、どちらも GyoshukuKit 20d8165・KaitoKit aca39dc。100k 全形式と本文 256 MiB を交互に 2 回、7z の従来の設定を 1 回ずつ、7z のパスワードの行を S25 の既定と従来の設定で 1 回ずつ。`p5-s25-acceptance.txt` は 2 回の小さい方での判定 |
