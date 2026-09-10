# KaitoFinder

macOS 26 以降向けの書庫ブラウザ。Finder と同じ見た目で書庫の中身を開き、
Finder や他のアプリとの間で **drag & drop** と **copy & paste** によって
ファイルやフォルダをやり取りする。

KaitoFinder は「一覧のできる圧縮ソフト」ではなく、**名前空間が書庫の中身である
ファイルマネージャ**として作る。Finder と同じ外観・操作感が第一の要件であり、
他のすべてはそれに従属する。

読み取りは [KaitoKit](https://github.com/shunnag/KaitoKit)(解凍Kit)、
書き込みは [GyoshukuKit](https://github.com/shunnag/GyoshukuKit)(凝縮Kit)。
解凍と凝縮を対にした、独立した二つの framework を使う。

- 対象: macOS 26 以上、Apple Silicon
- 読める形式: tar、ZIP / ZIP64、7z、RAR4 / RAR5、LHA / LZH、ISO 9660、cpio、
  ar (.deb)、xar (.pkg)、CAB、RPM、gzip、bzip2、xz、UNIX compress、圧縮 tar
- 書ける形式: ZIP → tar → 7z → LHA/LZH の順に対応予定
- ライセンス: MIT

## 状態

M0〜M2 を実装。

- 書庫を Finder のような一覧で開く。書庫が directory entry を持たなくても
  階層を合成して表示する
- **取り出し**: file promise による drag out、明示展開による copy out、
  Quick Look、「開く」「このアプリケーションで開く」。**読める 15 形式すべて**
- **取り込み**: ZIP への drag in / paste in。書けない書庫は理由を示して拒否する
- 未実装: 書庫内の削除・改名、tar / 7z / LHA の書き込み

- [設計書](Documentation/design.md)
- [検証記録](Documentation/verification/)

## 開発

関係する checkout は `~/Github/` に並べる。

```
~/Github/KaitoKit     解凍。読み取り
~/Github/GyoshukuKit  凝縮。書き込み
~/Github/KaitoFinder  本 repo
```

`.xcodeproj` はこの二つを `../KaitoKit` と `../GyoshukuKit` の local SwiftPM
package として静的リンクする。Xcode 26 以降、Swift 6、arm64 専用。

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' build
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' test
```

アプリの「ファイル > 開く…」、または実行ファイルへの書庫パス引数で開く。
テストは書庫を実際に生成し、参照実装(`unzip`、`7zz`、`ditto`、`bsdtar`)と
KaitoKit の往復で検証する。

各段階の実測と、この環境で自動検証できなかった範囲は
[検証記録](Documentation/verification/)に残している。

> **KaitoFinder** is an archive browser for macOS 26 and later. It opens the
> inside of an archive with Finder's own look, and moves files and folders to and
> from Finder and other apps by drag & drop and copy & paste.
>
> It is not "a compressor that can show a list" — it is a file manager whose
> namespace happens to be the inside of an archive. Looking and behaving like
> Finder is the first requirement, and everything else is subordinate to it.
>
> Reading is [KaitoKit](https://github.com/shunnag/KaitoKit) (解凍Kit, the
> extraction kit) and writing is
> [GyoshukuKit](https://github.com/shunnag/GyoshukuKit) (凝縮Kit, the compression
> kit) — two independent frameworks that pair extraction with compression. Requires
> macOS 26 or later on Apple Silicon. It reads tar, ZIP/ZIP64, 7z, RAR4/RAR5,
> LHA/LZH, ISO 9660, cpio, ar (.deb), xar (.pkg), CAB, RPM, gzip, bzip2, xz, UNIX
> compress and compressed tar; write support is planned in the order ZIP, tar, 7z,
> LHA/LZH. MIT licensed.
>
> Milestones M0 through M2 are implemented: browsing an archive with a
> Finder-shaped list, synthesizing the folder hierarchy even for archives that
> record no directory entries; taking items **out** by file-promise drag, by
> explicit copy, and through Quick Look and Open With, for all fifteen readable
> formats; and putting items **in** to a ZIP by drag or paste, with unwritable
> archives refused up front with a stated reason. Deleting and renaming inside an
> archive, and writing tar, 7z or LHA, are not implemented yet.
>
> Development expects the KaitoKit and GyoshukuKit checkouts to sit beside this
> one under `~/Github/`, linked as local SwiftPM packages via `../KaitoKit` and
> `../GyoshukuKit`. Tests build real archives and verify them against reference
> implementations (`unzip`, `7zz`, `ditto`, `bsdtar`) and a KaitoKit round trip.
> See the [design document](Documentation/design.md) and the
> [verification records](Documentation/verification/).
