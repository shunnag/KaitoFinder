# KaitoFinder の制限

KaitoFinder 0.8.0 の利用上の制限です。[対応形式](formats.md)、[利用ガイド](user-guide.md)、[README](../README.md)もご覧ください。

## 制限

- RAR / ISO 9660 / cpio / ar / xar / pkg / CAB / RPM / StuffIt / StuffIt X と、単体の gzip・bzip2・xz・Zstandard・LZ4・LZMA・lzip・Brotli・UNIX compress は読み取り専用です。
  「別名で保存…」で編集できる形式へ変換できます。その他の読み取り専用形式は[対応形式](formats.md)をご覧ください。
- 圧縮 tar（tar.gz / tar.bz2 / tar.xz / tar.zst / tar.lz4 / tar.lzma / tar.lz / tar.br / tar.Z）は、開くときに内側の tar を一時的に展開します。
  64 MiB を超える場合は、起動ディスクに展開後の tar とほぼ同じ空き容量が必要です。展開中に空き容量が 1 GiB を下回ると、開く操作を中止します。
- 一つのアーカイブは最大1,000,000項目、RAR / `.001` の分割セットは最大128巻です。
  ファイルごと・全体の展開サイズにはアプリ独自の上限はありませんが、展開先に十分な空き容量が必要です。
  圧縮方式や管理情報の大きさによる追加の上限もあります。
- ファイルのアクセス権が記録されていない場合は、標準のアクセス権を使います。
- 表示はリスト形式です。アイコン・カラム・ギャラリー形式への切り替えはできません。
- サムネイルは 8 MiB 以下の画像のみです。暗号化された項目、ソリッド形式の 7z / RAR の項目、動画・音声は対象外です。
- 自己展開形式（SFX）は作成できません。対応する SFX の読み取りはできます。

## English

- RAR / ISO 9660 / cpio / ar / xar / pkg / CAB / RPM / StuffIt / StuffIt X and standalone gzip / bzip2 / xz / Zstandard / LZ4 / LZMA / lzip / Brotli / UNIX compress streams are read-only.
  Save As… converts to an editable format; see [formats](formats.md#english) for other read-only types.
- Opening compressed tar (tar.gz / tar.bz2 / tar.xz / tar.zst / tar.lz4 / tar.lzma / tar.lz / tar.br / tar.Z) temporarily expands its inner tar.
  Above 64 MiB, the startup disk needs roughly the expanded tar size in free space. Opening stops if free space drops below 1 GiB while expanding.
- Each archive supports up to 1,000,000 items; RAR / `.001` split sets support up to 128 volumes.
  The app has no separate per-file or total extraction-size limit, but the destination needs enough free space. Compression methods and the size of archive management information impose additional limits.
- Items without stored permissions use standard permissions.
- Browsing uses a list. Icon, column, and gallery views are unavailable.
- Thumbnails cover images up to 8 MiB only; encrypted items, solid 7z / RAR items, video, and audio are excluded.
- Self-extracting archives (SFX) cannot be created; supported SFX can be read.
