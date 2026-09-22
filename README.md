# KaitoFinder

macOS 26 以降向けのアーカイブブラウザ。Finder と同じ見た目でアーカイブの中身を開き、
Finder や他のアプリとの間で **drag & drop** と **copy & paste** によって
ファイルやフォルダをやり取りする。

KaitoFinder は「一覧のできる圧縮ソフト」ではなく、**名前空間が書庫の中身である
ファイルマネージャ**として作る。Finder と同じ外観・操作感が第一の要件であり、
他のすべてはそれに従属する。

読み取りは [KaitoKit](https://github.com/shunnag/KaitoKit)(解凍Kit)、
書き込みは [GyoshukuKit](https://github.com/shunnag/GyoshukuKit)(凝縮Kit)。
解凍と凝縮を対にした、独立した二つの framework を使う。

- 対象: macOS 26 以上、Apple Silicon
- ライセンス: MIT

## 開く

「ファイル > 開く…」や Finder から、次の形式の中身を一覧できる。
アーカイブにフォルダの項目が記録されていなくても、パスから階層を組み立てて表示する。

- ZIP / ZIP64、7z、RAR4 / RAR5、LHA / LZH
- StuffIt (`.sit` / `.sea`)、StuffIt X (`.sitx`)
- tar、cpio、ar (`.deb`)、ISO 9660、xar (`.pkg`)、CAB、RPM
- Apple Disk Image (`.dmg`)、UDF (`.udf`)、WIM (`.wim` / `.swm`)、Compound File（`.msi` など）、CHM (`.chm`)、ARJ (`.arj`)
- MacBinary (`.bin`)、AppleSingle (`.as`)、BinHex (`.hqx`)
- gzip、bzip2、xz、Zstandard (`.zst`)、LZ4 (`.lz4`)、LZMA (`.lzma`)、UNIX compress (`.Z`)、lzip (`.lz`)、Brotli (`.br`)、pbzx (`.pbzx`)
- 圧縮 tar: tar.gz / tgz、tar.bz2 / tbz / tbz2、tar.xz / txz、tar.zst / tzst、tar.lz4、tar.lzma / tlz、tar.lz、tar.br / tbr、tar.Z

`.msi` / `.arj` は、他のアプリがファイル型を登録している環境での関連付けにも対応する。

ZIP / 7z / RAR の分割巻、対応する SFX（自己展開形式）、暗号化アーカイブも読み取れる。
LZ4 は現行 frame の独立／連続ブロック・チェックサムと、8 MiBブロックのlegacy frame・連結に対応する。外部辞書とLZ4の新規作成は未対応。

ZIP 内の XZ（method 95）と旧 Zstandard（method 20）、旧方式 Shrink / Reduce 1〜4 / Implode、
7z の Zstandard coder の展開・プレビューにも対応する。
KaitoKit 0.8.0 で追加された形式と tar.lz / tar.br は読み取り専用。未対応の亜種や圧縮方式もある。
Finder 製 ZIP は 0.1.0 と同じく `__MACOSX` の付随ファイルを保った一覧で表示・編集する。
Office / Outlook の文書拡張子と拡張子のない pbzx Payload は関連付けず、「ファイル > 開く…」から開く。
対応する圧縮方式・暗号・分割方法の範囲は [KaitoKit の対応状況](https://github.com/shunnag/KaitoKit#対応状況)を参照。
パスワードは必要なときに入力し、「このパスワードを記憶」で次回から自動使用できる（記憶は既定でオフ）。

## 取り出す

- ファイルやフォルダを Finder や他のアプリへドラッグして取り出す。file promise により、
  ドロップ先が受け取るときに展開する。
- ⌘C は一時領域へ明示的に展開してからコピーし、Finder などへペーストできる。
  「展開」「すべて展開…」では展開先を指定できる。
- Space で「クイックルック」。「開く」や「このアプリケーションで開く」でも中身を確認できる。
  他のアプリで開くのは読み取り専用の一時コピーで、変更は元のアーカイブには保存されない。
- 「表示 > プレビューを表示」（⇧⌘P）またはツールバー右端のボタンで、右側に選択ファイルのプレビューを表示できる。
  新しい書庫ではオフ。境界をドラッグして幅を調整でき、書庫・タブごとに表示を切り替えられる。
  64 MiB を超えるファイル、サイズ不明のファイル、solid 7z / RAR のメンバーは「プレビューを表示」を押して読み込む。
- 「ファイル > アーカイブを展開…」で複数をまとめて展開できる。
  Finder のサービス「KaitoFinderで展開」も、文書ウインドウを開かずに同じ一括展開を行う。
- 元のアーカイブの quarantine（隔離属性）を展開物へ引き継ぐ。
  path traversal（`..` で展開先の外へ出るパス）や、展開先の外を指すシンボリックリンクなどを拒否し、
  安全な展開先の内側へだけ書き込む。

## 取り込む・編集する

書き込み可能なアーカイブには、Finder や他のアプリから drag in / paste in で追加できる。
削除・改名・新規フォルダの作成と、同じウインドウ内でのドラッグによるフォルダ間の移動に対応する。
⌥ を押しながらドラッグするとコピーになる。

編集は ⌘Z で取り消し、⇧⌘Z でやり直せる。
編集前の原本を同じボリュームの一時領域へ `clonefile` で退避し、取り消し時に戻す。
開いた後に原本が外部で変更されていた場合は、編集も取り消しも拒否する。
変更の検出はファイルの実体(デバイス・inode)・サイズ・更新日時に基づく。同じ inode を
同じサイズのまま上書きし更新日時も戻すような変更は検出できない。

## 作成と変換

「新規アーカイブ…」（⌘N）や Finder のサービス「KaitoFinderで圧縮」から、
ファイル・フォルダを **ZIP / tar / tar.gz / tar.bz2 / tar.xz / 7z / LHA** にまとめられる。
「別名で保存…」（⇧⌘S）は中身を別の形式へ変換し、元ファイルを残して新しい保存先を同じ文書で開く。
読み取り専用アーカイブへの追加・ペーストでも、新しいアーカイブへの変換を案内する。

ZIP・tar.gz・tar.bz2 は保存パネルで圧縮レベルを選べる。ZIP は「圧縮しない」も選択できる。
tar.xz・7z・LHA は固定の圧縮レベル、tar は非圧縮。
通常の編集では ZIP はその場更新で既存のデータを保ち、tar / tar.gz / tar.bz2 / tar.xz / 7z / LHA は全体を書き直すため、
アーカイブの大きさに応じて時間がかかる。

## 暗号化

暗号化は保存時に選択する（既定でオフ）。ZIP の暗号方式は **AES-256 が既定**。
macOS のアーカイブユーティリティでは AES-256 の ZIP を開けないため、互換性が必要なら
安全性の低い従来方式の ZipCrypto を選ぶ。
7z は AES-256 に対応し、「ファイル名も暗号化」も選べる。tar（圧縮 tar を含む）/ LHA は暗号化できない。

開いている ZIP / 7z には「パスワードを設定…」「パスワードを変更…」「パスワードを削除」が使える。
これらの操作は全体を書き直し、取り消し・やり直しにも対応する。
正しいパスワードが分かれば、暗号化された ZIP / 7z も追加・削除・改名でき、
通常の編集では暗号化方式と 7z のファイル名の保護を引き継ぐ。

## 表示

Finder 風のリスト表示に、パスバー、タブ、ツールバーの検索、ステータスバーを備える。
ツールバーには「展開」「追加…」「新規フォルダ」「削除」「クイックルック」があり、配置をカスタマイズできる。
画像にはサムネイルを表示する（暗号化された画像や 8 MiB を超える画像は通常のアイコン）。
「隠しファイルを表示」（⇧⌘.）で表示を切り替えられ、検索やステータスバーの件数にも反映する。
表示で隠した項目も、フォルダ全体の展開・編集からは除かれない。

選択済みのファイル名を、ダブルクリックにならない間隔でもう一度クリックすると名称変更できる。
最初のクリックは選択だけを行い、アイコン・名前のない余白・複数選択・ドラッグでは名称変更を始めない。
ファイルは拡張子を除く部分、フォルダは名前全体が選択される。Returnで確定、Escapeで取消し。
設定 › 一般の「選択した名前をクリックして名称変更（Finderと同じ）」は標準でオン。
オフにすると従来のクリック操作へ戻り、Returnと「名称変更」メニューは引き続き利用できる。
設定の変更は、開いているすべての書庫にすぐ反映される。
⌘↓（または⌘O）で選択したファイルを開き、フォルダなら階層一覧を広げる。⌘↑で親フォルダを選択する。
Spaceでクイックルックを開く。⌘Spaceなど修飾キー付きのSpaceをクイックルックとして扱わない。

書庫を開く方法は、設定 › 一般の「アーカイブを開くとき:」で
**macOSの設定に従う（既定）／新しいタブ／新しいウインドウ**から選べる。
Finder の関連付け、「開く…」、最近使った項目に共通で、変更は次に開く書庫から反映する。
既に開いている書庫をもう一度開くと、その書庫のタブまたはウインドウを表示する。
タブの切り替え・分離・ウインドウの結合は、macOS 標準のウインドウメニューから行える。
ファイルをドラッグしたまま別のタブの上で約0.6秒待つと、そのタブへ切り替わる。
そのまま一覧へドロップでき、タブ上を短く通過しただけでは切り替わらない。

同じ書庫内のドラッグは移動、⌥ を押したドラッグはコピー。
**別の書庫へのドラッグは、同じウインドウの別タブも含めてコピー**になり、元の書庫は変わらない。
フォルダとその中身を一緒に選んでも、中身を重複して追加しない。
フォルダ上へのドロップはそのフォルダへ、ファイル上ならその親へ、一覧の空白部分なら書庫の最上位へ追加する。
同名の項目があるときは、既存・追加元のサイズ、変更日、種類、場所を比較して「置き換える」「スキップ」「キャンセル」を選べる。
「内容を比較…」では、双方のファイルをQuick Lookで左右に表示できる。
複数ファイルでは「残りのファイルにも適用」を使える。フォルダや種類の異なる項目は別に確認し、フォルダは内容全体を置き換える。
追加、貼り付け、別の書庫・タブからのコピー、同じ書庫内の移動で共通の確認を使う。
すべての回答が揃ってからまとめて反映し、一回の「取り消す」で戻せる。キャンセルや受信・書き込みの失敗では全体の変更を中止する。

## ようこそウインドウ

「ようこそKaitoFinderへ」には二つのドロップ領域がある。
「アーカイブを開く」へアーカイブをドロップすると開き、
「アーカイブを作成」へファイルやフォルダをドロップすると作成に進む。クリックでも選択できる。
設定の「起動時にようこそウインドウを表示」をオフにすると、起動時の表示を省ける。
ウインドウメニューの「ようこそKaitoFinderへ」（⇧⌘1）で再表示できる。

## 設定

「設定…」（⌘,）は **一般 / 圧縮 / 展開 / アップデート** の四つのタブ。
書庫の開き方、既定の作成形式、隠しファイルやようこその表示、圧縮方式・レベル、展開先・フォルダ作成方針、
展開成功後に元のアーカイブをゴミ箱へ移すかどうかを設定できる。
追加・新規作成時の **`.DS_Store` の除外は既定でオン、隠しファイル全体の除外は既定でオフ**。
これらの除外設定は、既存の項目の展開や形式変換には適用しない。

## 終了と後始末

展開・追加・作成などが進行中に終了(⌘Q)すると確認を求め、「終了」を選ぶと操作を取り消し、
途中まで書き出した項目・作業コピー・取り消し用の退避を片付けてから終了する。強制終了や
クラッシュで残った作業ディレクトリ(`.KaitoFinder-add-*` / `.KaitoFinder-new-*`)は
`~/Library/Application Support/KaitoFinder/pending-work.json` の台帳に基づいて次回起動時に回収する。

## 言語

次の 26 言語に対応し、未対応言語では英語を表示する。

日本語、英語、ドイツ語、フランス語、スペイン語、イタリア語、
ポルトガル語（ブラジル）、ポルトガル語（ポルトガル）、中国語（簡体字）、中国語（繁体字）、韓国語、
タイ語、ベトナム語、インドネシア語、マレー語、ヒンディー語、ロシア語、オランダ語、ポーランド語、
トルコ語、スウェーデン語、デンマーク語、ノルウェー語（ブークモール）、フィンランド語、ウクライナ語、チェコ語。

## 制限

- tar.zst / tar.lz4 / tar.lzma / tar.lz / tar.br / tar.Z と、RAR / ISO 9660 / cpio / ar / xar / pkg /
  CAB / RPM / StuffIt / StuffIt X / 単体の gzip・bzip2・xz・Zstandard・LZ4・LZMA・UNIX compress は
  読み取り専用。「別名で保存…」で書き込み可能な形式へ変換できる。
- 圧縮 tar（tar.gz / tar.bz2 / tar.xz / tar.zst / tar.lz4 / tar.lzma / tar.lz / tar.br / tar.Z）は、開くときに内側の tar を一時展開する。
  64 MiB を超えると一時ファイルへ保存するため、起動ボリュームに展開後の tar とほぼ同じ空き容量が必要。
  一時ファイルの書き込み中に空き容量が 1 GiB を下回ると、開く操作を中止する（KaitoKit の `stagingFreeSpaceReserve`）。
- KaitoKit 既定の reader 制限は、1,000,000 項目 / 保持するメタデータ 256 MiB、
  RAR / .001 セットの 128 巻、コーデック辞書 1 GiB。項目ごと・全体の展開サイズはアプリで制限せず、展開先の空き容量に従う。
- パーミッションが格納されていない項目には、プラットフォーム既定の mode（ファイル 0666 / フォルダ 0777 に umask を適用）を使う。
- アイコン / カラム / ギャラリー表示は未対応。リスト表示を使う。
- サムネイルは 8 MiB 以下の画像のみ。暗号化された項目と solid 7z / RAR のメンバー、動画・音声は対象外。
- SFX の作成は行わない。SFX の読み取りは対応範囲で利用できる。

## 配布

Sparkleによる自動更新に対応する。「設定」›「アップデート」で自動確認と自動ダウンロード・インストールを選び、
最終確認日時を確認できる。アプリメニューの「アップデートを確認…」から手動でも確認できる。
自動確認は既定で有効、自動ダウンロード・インストールは選択式。
更新フィードの公開・署名と初回配布の手順は[自動更新と配布](Documentation/software-updates.md)を参照。

sandbox なしで配布する。Developer ID による署名と notarize の手順・実施状況は
[設計書 §11.5](Documentation/design.md#115-配布sandbox-なしnotarize-済み-2026-09-15)を参照。
リリースビルドは、下記の build コマンドに `-configuration Release` と Developer ID の
`CODE_SIGN_IDENTITY`・`DEVELOPMENT_TEAM` を指定して作成する。開発時は Debug を使う。

## 開発

関係する checkout は `~/Github/` に並べる。

```text
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

メニュー・操作経路の変更では `python3 Tools/verify_ui_integration.py` も実行する。
実メニューの操作と、最近使った項目の保存・再起動・消去を専用アプリで検証する。
確認範囲とテストの書き方は [UI の回帰テスト](Documentation/ui-integration-testing.md)を参照。
ファイル一覧のクリック・キー操作の変更では `python3 Tools/verify_finder_interactions.py` も実行する。
実マウス入力での名称変更と既存の書庫間ドラッグを専用アプリで確認する。

リリース前は両ライブラリの `swift test` も実行し、選択した UI テストだけで全体の成功を判断しない。
[横断検証の記録](Documentation/verification/2026-09-17-release-hardening.md)に
全件・スキップ・実書庫・性能の結果をまとめ、[圧縮形式の追加計画](Documentation/compression-roadmap.md)に
読み取り・書き込みの不足と追加時の検証条件を記す。
ZIP 20/95 の追加と暗号化入力の効率化は [追加検証](Documentation/verification/2026-09-18-zip-methods.md)を参照。

アプリの「ファイル > 開く…」、または実行ファイルへのアーカイブのパス引数で開く。
テストはアーカイブを実際に生成し、参照実装（`unzip`、`7zz`、`ditto`、`bsdtar`）と
KaitoKit の往復で検証する。

設計上の判断は [設計書](Documentation/design.md)、各段階の実測と自動検証できなかった範囲は
[検証記録](Documentation/verification/)に残している。
Finder や実際のウインドウで確認する操作は [手動検証手順](Documentation/manual-verification.md)を参照。

> **KaitoFinder** is an archive browser for macOS 26 and later on Apple Silicon.
> It opens the contents of archives with Finder's look and moves files and folders
> to and from Finder and other apps by drag & drop and copy & paste.
>
> It is not "a compressor that can show a list" — it is a file manager whose
> namespace happens to be the inside of an archive. Looking and behaving like
> Finder is the first requirement, and everything else is subordinate to it.
>
> Reading uses [KaitoKit](https://github.com/shunnag/KaitoKit) (解凍Kit, the extraction kit);
> writing uses [GyoshukuKit](https://github.com/shunnag/GyoshukuKit) (凝縮Kit, the compression kit).
> These two independent frameworks pair extraction with compression. MIT licensed.
>
> ## Open
>
> Open archives from File > Open… or Finder. Folder hierarchies are synthesized
> from paths even when the archive contains no directory entries.
>
> Readable formats are ZIP / ZIP64, 7z, RAR4 / RAR5, LHA / LZH, StuffIt (.sit / .sea),
> StuffIt X (.sitx), tar, cpio, ar (.deb), ISO 9660, xar (.pkg), CAB, RPM, gzip, bzip2,
> xz, Zstandard (.zst), LZ4 (.lz4), LZMA (.lzma), and UNIX compress (.Z). Compressed tar includes
> tar.gz / tgz, tar.bz2 / tbz / tbz2, tar.xz / txz, tar.zst / tzst, tar.lz4, tar.lzma / tlz, and tar.Z.
> Split ZIP / 7z / RAR volumes, supported self-extracting archives (SFX), and encrypted
> archives can also be read, including ZIP XZ (method 95) and legacy Zstandard (method 20)
> extraction and previews. See [KaitoKit's format support](https://github.com/shunnag/KaitoKit#対応状況)
> for supported methods, encryption, and volume layouts. Passwords are requested when
> needed; “Remember this password” enables automatic reuse and is off by default.
>
> ## Extract
>
> Drag files or folders to Finder or another app; a file promise extracts them when
> the destination accepts the drop. ⌘C explicitly extracts to temporary storage before
> placing real files on the clipboard for pasting. Extract and Expand All… let you
> choose a destination. Space opens Quick Look; Open and Open With use read-only
> temporary copies whose changes are not saved back to the archive.
>
> File > Expand Archives… extracts several archives in one batch. Finder's
> “Extract with KaitoFinder” service uses the same batch operation without opening
> document windows. The source archive's quarantine attribute propagates to extracted
> files. Path traversal through `..`, symlinks targeting locations outside the destination,
> and other unsafe extraction paths are refused.
>
> ## Add and Edit
>
> Drag or paste files into writable archives. Delete, rename, create folders, and
> drag items between folders in the same window; hold ⌥ to copy instead of move.
> When names conflict, compare size, modification date, kind, and location before
> choosing Replace or Skip. Compare Contents opens both files side by side in Quick Look.
> Apply a choice to the remaining files in a batch; folders and type changes require
> separate confirmation, and replacing a folder replaces its entire contents.
> All accepted changes form one undoable operation. Cancel aborts the whole batch.
> Undo with ⌘Z and redo with ⇧⌘Z. Before an edit, `clonefile` preserves the original
> in temporary storage on the same volume for undo. Editing and undo are refused if the
> original has changed externally since it was opened. Change detection is based on the
> file identity (device and inode), size, and modification time; an in-place overwrite
> that keeps the same inode and size and restores the modification time is not detected.
>
> ## Create and Convert
>
> New Archive… (⌘N) and Finder's “Compress with KaitoFinder” service create ZIP, tar,
> tar.gz, tar.bz2, tar.xz, 7z, or LHA archives from files and folders. Save As… (⇧⌘S) converts to a new
> file, leaves the original intact, and switches the same document to the saved file.
> Adding or pasting into a read-only archive also offers conversion to a new archive.
> ZIP, tar.gz, and tar.bz2 have selectable compression levels; ZIP also offers no compression.
> tar.xz, 7z, and LHA use fixed levels, and tar is uncompressed. Normal ZIP edits update the
> archive in place while preserving existing data; tar, tar.gz, tar.bz2, tar.xz, 7z, and LHA edits
> rewrite the whole archive, so the time needed depends on its size.
>
> ## Encryption
>
> Encryption is optional and off by default. ZIP defaults to AES-256 when enabled.
> macOS Archive Utility cannot open AES-256 ZIP files; choose the weaker legacy
> ZipCrypto method when that compatibility is needed. 7z supports AES-256 and optional
> filename encryption. tar, tar.gz, and LHA cannot be encrypted.
> Open ZIP / 7z documents offer Set Password…, Change Password…, and Remove Password.
> These operations rewrite the archive and support undo and redo. With the correct
> password, encrypted ZIP / 7z archives can also be edited; normal edits preserve
> the encryption method and 7z filename protection.
>
> ## View
>
> The Finder-style list includes a path bar, tabs, toolbar search, and a status bar.
> The customizable toolbar offers Extract, Add…, New Folder, Delete, and Quick Look.
> Images have thumbnails; encrypted images, solid 7z / RAR members, and images larger
> than 8 MiB keep their regular icons. Show Hidden Files (⇧⌘.) also affects search and status counts.
> View > Show Preview (⇧⌘P) opens the preview sidebar. Files larger than 64 MiB,
> files with unknown size, and members of solid 7z / RAR archives load only after pressing Show Preview.
> Hiding items from view does not exclude them from whole-folder extraction or editing.
> During a file drag, hold over another tab for about 0.6 seconds to select it,
> then drop into its list. Briefly passing over a tab does not select it.
>
> ## Welcome Window
>
> “Welcome to KaitoFinder” has two drop areas: Open Archive opens dropped archives,
> and Create Archive starts creation from dropped files or folders. Both can also be
> clicked. Turn off “Show the welcome window at launch” in Settings to hide it at startup.
> Window > Welcome to KaitoFinder (⇧⌘1) shows it again.
>
> ## Settings
>
> Settings… (⌘,) has General, Compression, Extract, and Updates tabs. Choose the default
> archive format, hidden-file and welcome display, compression methods and levels,
> extraction destinations and folder rules, and whether to trash an archive after
> successful extraction. When adding files or creating archives, excluding `.DS_Store`
> is on by default; excluding all hidden files is off. These exclusions do not apply
> to extracting or converting existing entries.
>
> ## Quitting and Cleanup
>
> Quitting (⌘Q) while an extraction, addition, or creation is in progress asks for
> confirmation; choosing Quit cancels the operation and removes partially written
> items, working copies, and undo backups before the app exits. Working directories
> left behind by a force quit or a crash (`.KaitoFinder-add-*` / `.KaitoFinder-new-*`)
> are recovered at the next launch from the ledger at
> `~/Library/Application Support/KaitoFinder/pending-work.json`.
>
> ## Languages
>
> All 26 supported languages are Japanese, English, German, French, Spanish, Italian,
> Portuguese (Brazil), Portuguese (Portugal), Chinese (Simplified), Chinese (Traditional),
> Korean, Thai, Vietnamese, Indonesian, Malay, Hindi, Russian, Dutch, Polish, Turkish,
> Swedish, Danish, Norwegian Bokmål, Finnish, Ukrainian, and Czech.
> Unsupported languages fall back to English.
>
> ## Limitations
>
> tar.zst, tar.lz4, tar.lzma, and tar.Z are read-only,
> as are RAR, ISO 9660, cpio, ar, xar / pkg, CAB, RPM, StuffIt, StuffIt X, and standalone
> gzip, bzip2, xz, Zstandard, LZ4, LZMA, and UNIX compress streams. Use Save As… to convert
> them to a writable format. Icon, column, and gallery views are not implemented;
> browsing uses the list view. Thumbnails cover images only, with no video or audio
> thumbnails. Only images up to 8 MiB are eligible; encrypted and solid 7z / RAR members are excluded.
> Compressed tar archives stage the inner tar when opened; above 64 MiB, staging uses a temporary file
> and needs roughly the expanded tar size in free space on the startup volume. Opening stops if free space
> would drop below 1 GiB while staging (KaitoKit's `stagingFreeSpaceReserve`).
> Remaining KaitoKit reader defaults include 1,000,000 entries / 256 MiB of retained metadata,
> 128 volumes for RAR / .001 sets, and a 1 GiB codec dictionary. The app no longer caps per-entry
> or total extracted sizes; destination disk space governs extraction.
> Entries without stored permissions use platform defaults: 0666 for files and 0777 for folders, with umask applied.
> SFX creation is not supported; supported SFX archives can be read.
>
> ## Distribution
>
> The app is distributed without a sandbox. See [design §11.5](Documentation/design.md#115-配布sandbox-なしnotarize-済み-2026-09-15)
> for Developer ID signing, notarization, and their current verification status.
> Sparkle provides automatic updates. Settings › Updates controls automatic checks and downloads,
> shows the last check time, and offers a manual check. Automatic checks are enabled by default;
> automatic downloads and installation on quit are optional.
> See [Software updates](Documentation/software-updates.md) for signed feeds and the initial release setup.
> For a release build, add `-configuration Release` and specify your Developer ID
> `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM`. Use Debug for local development.
>
> ## Development
>
> Place the KaitoKit, GyoshukuKit, and KaitoFinder checkouts beside each other under
> `~/Github/`. The Xcode project statically links `../KaitoKit` and `../GyoshukuKit`
> as local SwiftPM packages. Use Xcode 26 or later, Swift 6, and arm64; the two
> `xcodebuild` commands above build and test with the explicit arm64 destination.
> Open through File > Open… or pass archive paths to the executable.
> Tests build real archives and check them against reference implementations
> (`unzip`, `7zz`, `ditto`, `bsdtar`) and a KaitoKit round trip.
> See the [design document](Documentation/design.md), [verification records](Documentation/verification/),
> and [manual verification steps](Documentation/manual-verification.md).
