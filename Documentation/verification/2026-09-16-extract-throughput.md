# 直列展開のファイルごとの固定費 — 2026-09-16

## 発端

[フォルダ選択の解決の記録](2026-09-16-subtree-resolution.md)の「残る伸びしろ」。Release の
50 万件(1 byte × 50 万、深さ 3)の一括展開は `unzip -q` の 38 s に対して 3〜5 倍遅く、
プロセスの CPU 時間は user 92 s + **sys 235 s**(変更前の実測)で、ファイルごとに約 20 回の
システムコール(root からの親ディレクトリの歩き直し `mkdirat`/`openat`/`close` × 深さ、
`validate` の成分ごとの `lstat`、ファイルの `openat`/`fremovexattr`/`write`/`fchmod`/`futimens`/
`fstat`/`close`、I-2c の `lstat`)が支配的だった。

## 変更

`ExtractionDestination` が直前の親ディレクトリの descriptor をキャッシュし、連続する兄弟の間で
使い回す(親が変わるときだけ従来どおり `O_NOFOLLOW|O_DIRECTORY` で歩き直す)。`validate` は親の
実体検査(`isInside`)を親ごとに 1 回にし、葉は名前の制約と `PATH_MAX` を毎回、既存の葉がある
場合だけ従来どおり葉まで解決して同じ理由で拒否する。`consume` のバッファは展開ごとに 1 回確保、
`written` の URL は成分を結合して 1 回で作る。

**安全性**: 拒否の理由文字列は全て変えていない(既存の traversal / symlink / hard link /
NFC-NFD / 重複名のテスト 34 件がそのまま通る)。キャッシュは「1 インスタンス = 1 つの同期
worker」の既存契約に依存する(§12-4 の並列展開では worker ごとに destination を作る)。TOCTOU の
窓は「ファイルごと」から「連続する兄弟の間」に広がるが、脅威モデル(敵対的アーカイブ。展開先へ
書ける並行プロセスは対象外)は変わらない: アーカイブは既存ディレクトリを移動・置換できず、
親が変わる entry は歩き直しで `O_NOFOLLOW` により拒否される。追加テスト 6 件
(キャッシュの切替、キャッシュ後の symlink 親の拒否と回復、既存の外向き symlink の葉・中間の
拒否理由、root へ戻る symlink 親の `NOFOLLOW` 理由、URL の同一性、ファイルを親にした場合の理由)。

## 実測(Release、同じ Mac、`KAITO_PROBE_BATCH` で一括展開、最後のファイルまで)

| | 壁時計 | CPU(user + sys) |
|---|---|---|
| 変更前 run 1 | 268 s | — |
| 変更前 run 2 | 344 s | — |
| 変更前 run 3 | 371 s | 92 s + 235 s = **327 s** |
| 変更後 run 1 | 180 s | 33 s + 119 s = **151 s** |
| 変更後 run 2 | 168 s | 29 s + 108 s = **137 s** |

壁時計は他の作業(音楽再生・VM)で揺れるため CPU 時間を主指標にした: **327 s → 137〜151 s
(54〜58% 短縮)**。参考: `unzip -q` 38 s、`ditto -x -k` 73 s。Debug の 10k 件シナリオ
(`testTenThousandEntries…`)は 6.1 s → 5.1 s。

## 残る伸びしろ

`fremovexattr`(隔離属性なしでも外しに行く)、`fchmod` + `futimens`、`fstat`、I-2c の `lstat` は
ファイルごとに残る。並列展開(§12-4)は独立 entry で 6.76 倍の余地がある。
