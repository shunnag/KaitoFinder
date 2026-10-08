# KaitoFinder の対応形式

対象: KaitoFinder 0.6.0 / KaitoKit 0.12.1 / GyoshukuKit 0.8.0。
[README](../README.md)、[利用ガイド](user-guide.md)、[制限](limitations.md)へ戻れます。

## 開ける形式

- ZIP / ZIP64、7z、RAR4 / RAR5、LHA / LZH
- StuffIt (`.sit` / `.sea`)、StuffIt X (`.sitx`)
- tar、cpio、ar (`.deb`)、ISO 9660、xar (`.pkg`)、CAB、RPM
- Apple Disk Image (`.dmg`)、UDF (`.udf`)、WIM (`.wim` / `.swm`)、Compound File（`.msi` など）、CHM (`.chm`)、ARJ (`.arj`)
- MacBinary (`.bin`)、AppleSingle (`.as`)、BinHex (`.hqx`)
- gzip、bzip2、xz、Zstandard (`.zst`)、LZ4 (`.lz4`)、LZMA (`.lzma`)、UNIX compress (`.Z`)、lzip (`.lz`)、Brotli (`.br`)、pbzx (`.pbzx`)
- 圧縮 tar: tar.gz / tgz、tar.bz2 / tbz / tbz2、tar.xz / txz、tar.zst / tzst、tar.lz4、tar.lzma / tlz、tar.lz、tar.br / tbr、tar.Z

### 分割・自己展開・特殊な形式

`.msi` / `.arj` は、他のアプリがファイル型を登録している環境での関連付けにも対応する。

ZIP / 7z / RAR の分割巻、対応する SFX（自己展開形式）、暗号化アーカイブも読み取れる。

ZIP 内の XZ と旧 Zstandard、旧方式 Shrink / Reduce 1〜4 / Implode、
7z の Zstandard coder の展開・プレビューにも対応する。
未対応の亜種や圧縮方式もある。作成・編集できる形式は以下の一覧を参照。
Finder 製 ZIP は `__MACOSX` の付随ファイルを保った一覧で表示・編集する。
Office / Outlook の文書拡張子と拡張子のない pbzx Payload は関連付けず、「ファイル > 開く…」から開く。
対応する圧縮方式・暗号・分割方法の範囲は [KaitoKit の対応状況](https://github.com/shunnag/KaitoKit/blob/main/Documentation/formats.md#対応状況)を参照。

分割巻の開き方とパスワード入力は[利用ガイドの「開く」](user-guide.md#開く)を参照。

## 作成と編集できる形式

| 形式 | 新規作成・形式変換 | 追加・削除・改名・置換 |
| --- | --- | --- |
| ZIP / ZIP64、7z、LHA | ○ | ○（アーカイブの構造・暗号化などの対応範囲内） |
| tar、tar.gz、tar.bz2、tar.xz | ○ | ○ |
| tar.zst、tar.lz、tar.lzma、tar.lz4、tar.br、tar.Z | ○ | ○（全体を書き直す） |
| 単独 .gz / .bz2 / .xz / .zst / .lz / .lzma / .lz4 / .br / .Z | 通常ファイル1個のみ | 読み取り専用 |
| その他の読み取り対応形式 | 変換元として開ける | 読み取り専用 |

操作の入口は[作成と変換](user-guide.md#作成と変換)。ZIP 本来の分割（`.z01…/.zip`）は読み取り専用。
番号付きバイト分割（`.001…`）の編集条件は[分割アーカイブの編集と保存](user-guide.md#分割アーカイブの編集と保存)を参照。

## 圧縮方式とレベル

保存パネルと「設定…」で選択できる方式・レベルは次のとおり。

| 形式 | 圧縮方式 | レベル | 「圧縮しない」 |
| --- | --- | --- | --- |
| ZIP | Deflate（既定）、BZip2、PPMd | 1〜9（PPMd の標準は 6） | ○ |
| ZIP | LZMA、XZ | 0〜9 | ○ |
| ZIP | Zstandard | 1〜19（標準 3） | なし |
| 7z | LZMA2（既定）、LZMA | 0〜9 | ○ |
| 7z | Deflate、BZip2、PPMd | 1〜9（PPMd の標準は 6） | ○ |
| LHA | lh5（既定）、lh6、lh7 | 1〜9 | ○ |
| tar.gz / .gz、tar.bz2 / .bz2 | Deflate、BZip2 | 1〜9 | なし |
| tar.xz / .xz、tar.lz / .lz、tar.lzma / .lzma | LZMA 系 | 0〜9 | なし |
| tar.zst / .zst | Zstandard | 1〜19（標準 3） | なし |
| tar、tar.lz4 / .lz4、tar.br / .br、tar.Z / .Z | 各形式の方式 | 選択なし | レベル選択なし |

tar・tar.lz4・tar.br・tar.Z はレベルを選べない。

### 7z のソリッド圧縮とフィルタ

7z はソリッド圧縮（既定オフ）と、なし（既定）/ 自動 / x86 (BCJ) / ARM64 / Delta のフィルタを選べる。Delta は 32 bit サンプル向けの距離 4。ソリッドブロック内の項目の削除では、そのブロックを再圧縮する。

## 1ファイルの圧縮

通常ファイル 1 個を選んだときだけ「1 ファイルの圧縮」に .gz / .bz2 / .xz / .zst / .lz / .lzma / .lz4 / .br / .Z が現れる。
元の拡張子を残して report.pdf.gz のように保存する。フォルダ・symlink・パッケージ・複数項目では tar 系を使う。
単独の圧縮ファイルは新規作成だけで、開いた後の編集には対応しない。この選択は次回の既定形式として記憶しません。

## 互換性

ZIP の BZip2 / LZMA / XZ / Zstandard / PPMd は macOS のアーカイブユーティリティ・ditto・unzip で開けないため、選択時に互換性の注記を表示する。

暗号化は保存時に選択する（既定でオフ）。ZIP の暗号方式は **AES-256 が既定**。
macOS のアーカイブユーティリティでは AES-256 の ZIP を開けないため、互換性が必要なら
安全性の低い従来方式の ZipCrypto を選ぶ。
7z は AES-256 に対応し、「ファイル名も暗号化」も選べる。tar（圧縮 tar を含む）/ LHA は暗号化できない。

パスワードの設定・変更・削除と暗号化した書庫の編集は[利用ガイドの「暗号化」](user-guide.md#暗号化)を参照。

## 編集時の書き込み

単一ファイルの通常の編集では、ZIP・tar・LHA・7z は対応する書庫の変更していないデータを保ち、書き直す量を減らす。
tar.zst・tar.lz・tar.lzma・tar.lz4・tar.br・tar.Z は追加・削除・改名・置換のたびに全体を書き直す。tar.zst の別名 .tzst も保存時に受理する。

tar.gz・tar.bz2・tar.xz は対応する区切りごとに編集する。ほかのツールの圧縮 tar の初回編集や、
アーカイブの構造・設定によっては全体を書き直す。分割セットは全巻を書き直す。

書き直しにかかる時間はアーカイブの大きさ・構造・設定によって変わる。

## English

### Readable formats

- ZIP / ZIP64, 7z, RAR4 / RAR5, LHA / LZH
- StuffIt (`.sit` / `.sea`), StuffIt X (`.sitx`)
- tar, cpio, ar (`.deb`), ISO 9660, xar (`.pkg`), CAB, RPM
- Apple Disk Image (`.dmg`), UDF (`.udf`), WIM (`.wim` / `.swm`), Compound File (`.msi` and others), CHM (`.chm`), ARJ (`.arj`)
- MacBinary (`.bin`), AppleSingle (`.as`), BinHex (`.hqx`)
- gzip, bzip2, xz, Zstandard (`.zst`), LZ4 (`.lz4`), LZMA (`.lzma`), UNIX compress (`.Z`), lzip (`.lz`), Brotli (`.br`), pbzx (`.pbzx`)
- Compressed tar: tar.gz / tgz, tar.bz2 / tbz / tbz2, tar.xz / txz, tar.zst / tzst, tar.lz4, tar.lzma / tlz, tar.lz, tar.br / tbr, tar.Z

#### Split, self-extracting, and special formats

`.msi` / `.arj` associations also work when another app registers the type. Split ZIP / 7z / RAR volumes, supported SFX (self-extracting archives), and encrypted archives can be read.
ZIP XZ, legacy Zstandard, Shrink / Reduce 1–4 / Implode, and 7z Zstandard support extraction and previews.
Some variants and compression methods are unsupported. Finder-created ZIPs preserve `__MACOSX` companion files when listing and editing.
Office / Outlook document extensions and extensionless pbzx Payload files have no associations; use File > Open….
See [KaitoKit's full support matrix](https://github.com/shunnag/KaitoKit/blob/main/Documentation/formats.md#対応状況) for compression, encryption, and volume layouts.
Opening split volumes and password handling are described in the [user guide](user-guide.md#open).

### Creation, methods, and levels

ZIP / 7z / LHA, tar, and all compressed tar formats listed above support creation, conversion, addition, deletion, renaming, and replacement within their supported ranges.
Native split ZIP (`.z01…/.zip`) remains read-only. Numbered byte-split (`.001…`) editing has [separate conditions](user-guide.md#add-and-edit). Other readable formats are read-only but can be conversion sources.
ZIP offers Deflate (default), BZip2, LZMA, XZ, Zstandard, and PPMd; 7z offers LZMA2 (default), LZMA, Deflate, BZip2, and PPMd; LHA offers lh5 (default), lh6, and lh7.
Deflate, BZip2, LHA, and PPMd use levels 1–9 (PPMd default 6); LZMA-based methods use 0–9.
Zstandard in ZIP, tar.zst, and .zst uses 1–19 (default 3), with no uncompressed option. Other ZIP methods, 7z, and LHA also offer no compression.
tar, tar.lz4 / .lz4, tar.br / .br, and tar.Z / .Z have no selectable level.
7z offers solid compression (off by default) and None (default), Automatic, x86 (BCJ), ARM64, or Delta filters. Delta uses distance 4 for 32-bit samples. Deleting an item inside a solid block recompresses that block.

### Single-file compression

Selecting one regular file enables Single-file compression for .gz / .bz2 / .xz / .zst / .lz / .lzma / .lz4 / .br / .Z.
The original extension is preserved (report.pdf.gz). Folders, symbolic links, packages, and multiple selections use tar formats instead.
These streams are create-only and stay read-only after opening. This selection is not remembered as the default format for next time.

### Compatibility

ZIP BZip2 / LZMA / XZ / Zstandard / PPMd cannot be opened by macOS Archive Utility, ditto, or unzip; selecting them shows a compatibility note.
Encryption is off by default. ZIP defaults to AES-256, which macOS Archive Utility cannot open; “ZipCrypto (More Compatible, Less Secure)” offers legacy compatibility.
7z supports AES-256 and Encrypt File Names. tar (including compressed tar) and LHA cannot be encrypted.
See [password operations and encrypted editing](user-guide.md#encryption).

### Update behavior

Normal single-file ZIP edits update in place while preserving existing data. Supported tar, 7z, and LHA edits also preserve unchanged data to reduce the amount rewritten.
tar.zst / tar.lz / tar.lzma / tar.lz4 / tar.br / tar.Z rewrite the whole archive on addition, deletion, renaming, or replacement. Saving tar.zst also accepts .tzst.
tar.gz / tar.bz2 / tar.xz update supported segments; a first edit of another tool's compressed tar, or the archive's structure or settings, may require a full rewrite. Split sets rewrite every volume.
Time depends on the archive size, structure, and settings. See [creation and conversion](user-guide.md#create-and-convert).
