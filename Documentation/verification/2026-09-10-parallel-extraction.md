# 検証: reopen() による並列展開は本当に速いか(2026-09-10)

設計書 §12 の未解決事項「`reopen()` の並列展開は本当に速いか。同じ
`ByteSource` の fd を全 reader が共有する。`pread` なので直列化しないはずだが
未計測」に答える。

## 方法

半分圧縮可能な 256 KiB の file を 400 本、合計 104,857,600 bytes 用意し、
`zip -r`(全 entry 独立)と `7zz a -t7z -mx1`(solid)の二つに詰めた。
`ArchiveReader.open` で 1 本開き、`reopen()` で worker 分の独立 reader を作って
`DispatchQueue.concurrentPerform` で全 file を `read(_:)` する。各条件 3 回の
最小値。macOS 27.0 / Apple Silicon、release ビルド。

## 結果 1: 独立 entry はほぼ線形に伸びる

`corpus.zip`(400 entry、`solidGroup` はすべて `-1`)

| worker | 時間 | 速度比 |
|---|---|---|
| 1(直列) | 0.115 s | 1.00x |
| 2 | 0.059 s | **1.93x** |
| 4 | 0.031 s | **3.67x** |
| 8 | 0.017 s | **6.76x** |

**`pread` は直列化しない。** 一つの fd を 8 reader で共有しても素直に伸びる。
並列 reader 方式は妥当だった。

## 結果 2: solid 書庫は「分けると遅くなる」

`corpus.7z`(400 entry、`solidGroup` は `0` と `1` の二つ、内訳 256 / 144)

| 割り当て | 時間 | 速度比 |
|---|---|---|
| 直列(1 worker) | 1.408 s | 1.00x |
| **round-robin で 4 worker**(solid group を分断) | 1.476 s | **0.95x** |
| **solidGroup ごとに 2 worker**(群内は書庫順) | 0.915 s | **1.54x** |

round-robin は直列より**遅い**。同じ solid 群を複数の worker が奪い合い、
それぞれが群を再展開するため。一方 solidGroup 単位に束ねると 1.54x 出る。
理論上限は大きい方の群が占める割合で決まり、256/400 = 64% なので約 1.56x。
実測 1.54x はほぼ上限で、設計の割り当て規則が正しいことを裏づける。

## 結果 3: 「solidGroup で束ねる」だけでは ZIP が直列に落ちる

同じ実験を `corpus.zip` に対して行うと、罠が出る。

| 割り当て | 時間 | 速度比 |
|---|---|---|
| round-robin で 4 worker | 0.032 s | 3.74x |
| **solidGroup ごと**(= 1 束) | 0.120 s | **0.99x** |

独立 entry は**全部 `solidGroup == -1` を共有する**。素直に「solidGroup を
キーにして束ねる」実装をすると束が一つになり、ZIP・tar・LHA のような
非 solid 書庫が丸ごと直列に落ちる。これは黙って 6.76x を失う。

**正しい規則**: `solidGroup >= 0` は群ごとに一つの worker へ書庫順で束ね、
`solidGroup == -1` は**束ねずに** entry 単位で自由に分配する。`-1` を
「一つの群」として扱ってはならない。

## 現状の実装と、残っている伸びしろ

`ExtractionService` は現在、一つの要求につき reader を一本だけ使い、
`ExtractionSelection` が `index` 昇順に並べて**直列**に展開する。これは
安全側として正しい —— 書庫順が保たれるので solid 群の再展開も hard link の
provenance も自動的に満たされる。並列なのは「同時に走る別々の要求」だけで、
一つの要求の中は直列である。

つまり結果 1 の 6.76x は**まだ取っていない**。取りに行く場合は上の規則を
そのまま実装すればよく、`reopen()` が `sending` を返すこと(KaitoKit 0.3.0)は
そのために入れてある。ただし drag 一回の選択は小さいことが多く、効くのは
「すべて展開」や大量選択のときなので、UI が固まらないことの方が先である。

> **Verification: does parallel extraction through `reopen()` actually scale? (2026-09-10)**
>
> This answers the open question left in design §12. A 100 MiB corpus of 400
> semi-compressible 256 KiB files was packed both as a `zip` (every entry
> independent) and as a solid `7z`, then read through readers created by
> `reopen()` on `DispatchQueue.concurrentPerform`, best of three, release build.
>
> **Independent entries scale almost linearly**: 1.93x at 2 workers, 3.67x at 4,
> and 6.76x at 8. `pread` on one shared descriptor does not serialize, so the
> parallel-readers design is sound.
>
> **A solid archive gets slower when its groups are split.** Round-robin over 4
> workers measured 0.95x — worse than serial — because several workers fight over
> the same solid group and each re-expands it. Bucketing by `solidGroup` instead,
> archive-ordered within each bucket, gives 1.54x; with groups of 256 and 144
> entries the ceiling is 256/400 = 1.56x, so 1.54x is essentially optimal and
> confirms the assignment rule.
>
> **The trap**: bucketing *only* by `solidGroup` collapses a ZIP to a single
> bucket, because every independent entry shares `solidGroup == -1` — measured
> 0.99x against 3.74x for round-robin on the same archive. The correct rule is to
> bucket `solidGroup >= 0` per group in archive order, and to distribute
> `solidGroup == -1` entries freely, never treating `-1` as one group.
>
> **Current state**: `ExtractionService` uses one reader per request and extracts
> serially in archive order. That is correct — archive order satisfies both solid
> re-expansion and hard-link provenance for free — and only separate concurrent
> requests run in parallel. The 6.76x above is therefore still unclaimed; the
> `sending` return on `reopen()` added in KaitoKit 0.3.0 is what a future
> implementation needs. It matters for Extract All and large selections rather
> than for a typical drag.
