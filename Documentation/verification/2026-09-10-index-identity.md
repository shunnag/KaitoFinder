# 二つの open が同じ index を返すか(2026-09-10)

書庫内の削除・改名で最初に潰しておくべき、データ消失に直結する問い。

## 問題

`GyoshukuKit.ArchiveUpdater.remove(entriesAt:)` と `rename(entryAt:to:)` は
**その updater 自身の open 時 index** を取る。一方、呼び出す KaitoFinder が
持っているのは `ArchiveSession` の**別の open** から来た `ArchiveEntry.index`。
同じファイルに対する独立した二つの open であり、一致する保証は自明ではない。
ずれれば、利用者が指した項目とは別の項目が消える。

さらに悪いことに、二つの open は**オプションが違う**。

| | オプション |
|---|---|
| `GyoshukuKit.ArchiveUpdater.open` | `ReadLimits(maxEntrySize: .max, maxTotalUncompressedSize: .max)` |
| `KaitoFinder.ArchiveSession.init` | `ArchiveReader.open(url:)` — 既定値 |

## 測定

同じ ZIP を両方の設定で開き、`index` / `name` / `kind` を突き合わせた。
書庫にはディレクトリ entry、入れ子、CP932 圏の日本語名、空ファイルを入れてある。

```
既定 open:  8 entries
制限緩和:   8 entries
→ index・名前・種別すべて一致
→ index は配列位置と一致(0..<n)
--- 一覧 ---
  0	directory	日本語/
  1	directory	日本語/深い/
  2	directory	日本語/深い/階層/
  3	file	日本語/深い/階層/奥.txt
  4	file	日本語/ガラス.txt
  5	directory	plain/
  6	file	plain/empty.bin
  7	file	plain/a.txt
```

## なぜ一致するのか

`ReadLimits` の各項目は `Checked.size` / `guard` で**超過時に throw する**だけで、
entry を黙って落としたり一覧を切り詰めたりしない。ZIP の一覧構築で
`maxEntryCount` を見る三箇所(`ZipReader.swift` の 615 / 1396 / 1527 行)は
いずれも `throw KaitoError.limitExceeded` である。

したがって「KaitoFinder が既定値で開けた書庫」は、その時点で既定の制限を
満たしており、制限を緩めても一覧は変わらない。制限緩和は
「既定では開けない書庫も開ける」ためのものであって、一覧の内容を変えない。

また `index` が配列位置 `0..<n` と一致することも確認した。GyoshukuKit は
`reader.entries[index]` と添字で引くので、この性質に依存している。

## それでも照合する

一致は現時点の実測であって、不変条件として保証されたものではない。
形式が増えれば(tar / 7z / LHA)開き方も増える。よって:

- `ArchiveUpdater` に `entryNames`(open 時の名前を index 順に返す読み取り専用の
  アクセサ)を追加し、
- KaitoFinder は破壊的操作の**前に**、各 index の名前が呼出側の期待と一致するかを
  照合し、一つでも違えば操作全体を拒否する。

照合では NFC 正規化を**しない**。正規化は衝突判定にだけ使う。ここで正規化すると、
検出したい二つの open の食い違いそのものを覆い隠しかねない。

open 時の名前を返す、という点が肝である。予約済みの改名を反映した名前を返せば、
呼出側の index が指す open 時の状態と比較できなくなり、照合の意味が消える。
