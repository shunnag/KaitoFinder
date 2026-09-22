# 圧縮形式の棚卸しと追加計画（2026-09-22 更新）

KaitoFinder、KaitoKit、GyoshukuKit の現在の作業ツリーを照合した。
「形式を一覧できる」「中身を読める」「新しく作れる」は別の能力として扱う。
以下の工数区分・優先度は実装の依存関係からの判断であり、実装済みという意味ではない。

2026-09-18: 優先1・2の ZIP 20/95 を追加した。
独立 fixture の由来・検証範囲・暗号化 XZ の読み取り量改善は
[追加検証](verification/2026-09-18-zip-methods.md)を参照。

優先3の tar.xz / tar.bz2 出力も追加し、4 GiB 超の実ファイルを含むエンジン検証を通過した。
保存パネルの確定操作も解除後に検証し、保存50回・上書き確認10回が成功した。
[エンジンの検証](verification/2026-09-18-compressed-tar.md)と
[保存・UIの検証](verification/2026-09-18-native-save-panel.md)を参照。

優先4のうち Swap2/Swap4 の読み取りも追加した。独立生成のplain／AES書庫で、
solid逆順・分割・プレビュー・複数ファイル追加とundo/redoを検証した。RISC-Vは未追加。
[追加検証](verification/2026-09-18-sevenzip-swap.md)を参照。

優先5の LZ4 frame を追加した。単体・圧縮tar・連結・skippable・上限、両エンジン全件、
アプリ関連64件と240変異を検証済み。[現行frameの検証](verification/2026-09-18-lz4-frame.md)を参照。
続いてlegacy frameの8 MiB block・圧縮tar・現行形式との混在連結を追加した。
[legacy追補](verification/2026-09-18-lz4-legacy.md)に別途検証結果を記録する。
UI結合ではタブ、100ファイルのドロップ、同名置換、保存、履歴の再起動を検証した。
2026-09-22: KaitoKit 0.8.0 で lzip・Brotli・pbzx とディスクイメージ等の新形式が追加された。
KaitoFinder 0.2.0 は文書型・一覧・プレビューへ接続し、ZIP の旧方式と 7z Zstandard にも追従する。
使用 checkout は KaitoKit 0.8.1 のレビュー修正と GyoshukuKit 0.4.2 を含む。
アプリの検証状況は[追従記録](verification/2026-09-22-kaitokit-0.8.0.md)を参照。

## 今回つながりを修正した形式

- ZIP Zstandard（method 93）、ZIP PPMd（98）、CAB LZX はエンジンに実装済みだった。
  アプリの古い許可一覧を更新し、実書庫からプレビュー用ファイルまでの内容を照合した。
- `.tar.lzma` / `.tlz` / `.tbz` を圧縮 tar の入口に追加した。
  新しい codec は作らず、既存 LZMA/BZip2 と TarReader を接続した。
- 空の `.lha` / `.lzh` を名前 hint と単一終端 byte の組合せで扱い、全削除後の再編集を可能にした。
- XZ の全ブロック・連結ストリームで辞書メモリ上限を検証する。
  新しい形式を XZ decoder に接続する前提として、この抜けを先に修正した。

以前の 2026-09-09 の KaitoKit 実装キューは、ZIP 93/98、CAB LZX、StuffIt/StuffIt X の追加より前の記録。
これらを今も全面未対応と数えない。細かな未対応 profile は残る。

## 現在の範囲

| 系統 | 読み取り済みの主な範囲 | 残る主な範囲 |
|---|---|---|
| ZIP | stored、Shrink、Reduce 1〜4、Implode、Deflate、Deflate64、BZip2、LZMA、Zstandard 20/93、XZ 95、PPMd 98、ZipCrypto/AES、ZIP64・split | tokenize 7、JPEG 96、WavPack 97、Strong Encryption、spanned/split SFX |
| 7z | LZMA1/2、PPMd7、Deflate、BZip2、Zstandard、Copy、AES、Delta、Swap2/Swap4、各 BCJ/BCJ2（BCJ / ARM64 修正込み）、solid・分割 | RISC-V、その他の拡張 coder |
| RAR | RAR4 unpack 29、RAR5 compression version 0・file copy、対応済み標準 filter、暗号化・多巻 | RAR4 unpack 15/20/26・custom VM、RAR5 version 1、SFX と多巻の組合せ |
| LHA | level 0〜3、lh0/1/4〜7/lhx、lz4/lz5/lzs、pm0、SFX | lh2/lh3/pm1/pm2 の展開、resource fork の個別公開 |
| CAB | None、MSZIP、LZX。手元の cabinet に収まる file | Quantum、cabinet をまたぐ一つの file |
| tar・単一ストリーム | tar、GNU sparse pax 0.0 / 0.1 / 1.0、gzip、bzip2、XZ、Zstandard、compress、LZMA_Alone、LZ4 modern/legacy、lzip、Brotli、pbzx。tar.lz / tar.br と圧縮 cpio も読み取る | 旧 GNU `S` 型・star / Solaris sparse、LZ4 外部辞書、lzop、外部 Zstandard 辞書、未対応 XZ filter、lzip version 0、shared dictionary Brotli |
| StuffIt / StuffIt X・旧 Mac wrapper | classic/5、主要 codec・暗号・fork、X の JPEG/English/x86 等、MacBinary / AppleSingle / BinHex | classic method 4/7/9〜12、未記述の暗号 profile、X の Root recovery・一部 JPEG sampling/多層処理 |
| ISO / UDF / DMG | ISO9660/Joliet/Rock Ridge・zisofs、UDF、DMG の HFS+ / HFSX・ISO / UDF、raw / zlib / bzip2 / lzfse / lzma chunk | zisofs2 / multi-extent zisofs、UDF の ext_ad・他 volume、DMG の ADC / APFS / decmpfs |
| WIM / Compound File / CHM / ARJ | WIM stored / XPRESS / LZX、CFB の stream と MSI 名、CHM stored / LZX、ARJ stored / method 1〜3・no data | WIM solid / LZMS・他 part・EFS、CHM の未対応 section、ARJ method 4・garbled・multi-volume の続き |
| その他の容器 | ar/deb、cpio、xar/pkg、RPM | ACE、ZOO、ARC/PAK、Compact Pro/PackIt、ALZip、Amiga 系、NSIS 等。cpio/RPM の新 profile も別途 |
| GyoshukuKit 出力 | ZIP stored/Deflate、tar、tar.gz、tar.bz2、tar.xz、non-solid 7z LZMA2、LHA lh5/stored。ZIP/7z 暗号化 | tar.zst / tar.lz / tar.br、ZIP の追加 codec、7z solid、多巻出力、Mac の fork/xattr 保存 |

これは実装の差分表で、各容器に存在する全亜種の一覧ではない。
ISO/UDF や MSI は「圧縮 codec」ではなく容器・ファイルシステムの追加。
読み取り対応だけを理由に、保存ダイアログへ出力形式を表示しない。

## 実装の優先順

| 順位 | 追加内容・規模 | 実装方針 | 完了を判断する検証 |
|---|---|---|---|
| 1 | ZIP 20 の互換読み取り / 追加済み | 旧 method ID を既存 Zstandard へ接続。保存形式は従来の stored/Deflate | 独立生成93のpayloadを保ちIDのみ20へ変更。CRC、AES actual method、local/central不一致、split、プレビュー。歴史的20書庫との直接比較は未確認 |
| 2 | ZIP XZ 95 / 追加済み | `ZipReader` の範囲付き入力を XZ に接続。AESでは認証済み圧縮入力を上限付きで一時保持 | Windows 系のツールで生成した書庫との全バイト一致、0 byte、連結、ZIP64/split、CRC/辞書上限、暗号化、プレビュー・編集。新規XZ圧縮出力は追加していない |
| 3 | tar.xz / tar.bz2 出力 / 実装済み・画面検証中 | TarWriter の出力先へストリーム compressor を挟む。XZ は Apple Compression、BZip2 は system libbz2 を候補とする | BSD tar・xz/bzip2・7zz で全項目照合、空書庫、4 GiB、取消し、容量不足、元入力の変更、atomic publish、undo/redo、保存設定 |
| 4 | 7z Swap2/Swap4 / 追加済み。RISC-V / 未追加 | Swapはcoder graphのfilterとして追加し、readをまたぐ未完単位を保持。RISC-Vは変換規則の独立確定から着手する | Swapは7zz独立生成、端数・極小buffer、solid逆順、AES、truncate、split、アプリの編集を通過。両エンジン全件と160変異入力も成功。アプリ全UIは継続中。RISC-Vは公開規則と独立fixtureが未充足 |
| 5 | LZ4 modern/legacy frame、lzip / 追加済み | LZ4 blockとframe、XXH32を公開仕様から実装。lzip は KaitoKit 0.8.0 の reader を単体・圧縮 tar・プレビューへ接続 | 公式ツールの生成物、連結/skippable、checksum、辞書・出力上限、8 MiB境界、disk staging、拡張子判定 |
| 6 | CAB跨ぎ、RAR5 version 1、LHA旧方式 / 中〜大 | 実書庫を先に集め、volume identity/solid状態/展開上限を設計。新codecは個別の作業単位にする | 複数の独立fixtureとtoolの一致、欠巻・差替え・順不同read、壊れた辞書/距離、暗号化、変異入力 |
| 7 | ZIP JPEG/WavPack、旧Mac/DOS/Amiga形式等 / 大 | 公開仕様と再配布可能fixtureの入手状況から順番を決める。容器とcodecを別実装にする | 実在書庫と独立decoderによる全バイト一致。自作writerと自作readerの一致だけでは完了にしない |

ZIP の ID と旧 ID 20 の扱いは [PKWARE APPNOTE](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) を参照。
7z の候補は [7z 形式の方式一覧](https://www.7-zip.org/7z.html) と
[公式 method ID 文書](https://github.com/ip7z/7zip/blob/main/DOC/Methods.txt) に照合した。
RAR5 の version 1 は RAR 7 以降向けとされるが、
[RAR の技術文書](https://www.rarlab.com/technote.htm)は主に容器の仕様であり、それだけで codec を実装できるとは判断しない。
[XZ 形式仕様](https://tukaani.org/xz/xz-file-format.txt)と
[LZ4 frame 仕様](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md)も入口・check・連結を独立に扱う根拠にする。

## 今回の LHA の効率化

LHAWriter の全 member 保持を実測したところ、256 MiB の圧縮しにくい入力でピークRSSが約1.14 GiBだった。
このため追加形式より先に、1 MiB入力と8 KiB辞書履歴による分割処理を実装した。
LH5 の bit 出力は block 間で継続させ、圧縮結果は権限0600・作成直後unlinkのspoolへ送る。
未完成の出力には元のbytesを置き、圧縮結果が小さければ差し替えることでstored fallbackを保つ。
取消し・途中失敗・容量不足でも原本とundoを保つ回帰テストと、lhasa/7zzによる独立検証を加えた。

`Tools/benchmark_lha_memory.py --max-rss-mib 96` は製品の実writerを `swiftc -O` で測る。
16/64/256 MiBで測定し、256 MiBのrandom入力は約14 MiBのピークRSSとなった。
圧縮率と所要時間を含む数値は[横断検証](verification/2026-09-17-release-hardening.md)を参照。
作業中は未圧縮bytesと圧縮spoolのディスク空きが必要になる。入力を読み直さずfallbackも保つための交換条件である。
次の形式追加でも、機能追加だけでなくメモリ・一時領域・圧縮率・取消し応答を同じように測定する。

## 追加時に共通で通す項目

1. 公開仕様・由来の分かるfixture・独立toolを用意し、暗号鍵や第三者codec実装をfixtureへ混ぜない。
2. 内部一覧だけでなく、読み出した全byte・CRC/hash・metadataとエラーの型を比較する。
3. metadataだけで危険なサイズを割り当てず、複数ブロック・複数ストリームの後半でも上限を適用する。
4. `.001` 等の分割、unlink後のreopen、取消し、出力cleanupを既存の境界テストに接続する。
5. KaitoFinder の `EntryReadCapability`、`ArchiveCapabilities`、UTType、プレビュー、ドラッグ＆ドロップ、
   読み取り専用表示を実fixtureで照合。書き込み対応を追加した場合のみ保存形式・設定・翻訳も更新する。
6. 3リポジトリ全件、別プロセスのrecent-historyを含むUI結合、署名したReleaseの起動を通す。

新しい形式をこのリリースへ無制限に積み増さず、今回確認した入口の接続漏れ・編集不能・上限漏れを修正した状態を
基点に、上記の単位で個別に評価する。
