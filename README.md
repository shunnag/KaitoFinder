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

設計と事前検証の段階。実装はこれから。

- [設計書](Documentation/design.md)
- [検証記録](Documentation/verification/)

## 開発

`~/KaitoKit` と `~/GyoshukuKit` に checkout がある前提で、`.xcodeproj` が
`../../KaitoKit` と `../../GyoshukuKit` を SwiftPM の local package として
参照する。

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
> Currently at the design and pre-verification stage — see the
> [design document](Documentation/design.md) and the
> [verification records](Documentation/verification/). Development assumes
> checkouts at `~/KaitoKit` and `~/GyoshukuKit`, referenced by the `.xcodeproj` as
> local SwiftPM packages.
