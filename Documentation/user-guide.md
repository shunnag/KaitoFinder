# KaitoFinder 利用ガイド

KaitoFinder 0.7.0 の操作と設定の詳しい説明です。
[はじめに・インストール](../README.md)、[対応形式](formats.md)、[制限](limitations.md)も参照してください。

- [開く](#開く)
- [取り出す](#取り出す)
- [取り込む・編集する](#取り込む編集する)
- [作成と変換](#作成と変換)
- [暗号化](#暗号化)
- [表示](#表示)
- [ようこそウインドウ](#ようこそウインドウ)
- [設定](#設定)
- [終了と後始末](#終了と後始末)
- [言語](#言語)
- [English](#english)

## 開く

「ファイル > 開く…」や Finder の「このアプリケーションで開く」から、[対応形式](formats.md#開ける形式)の中身を一覧できます。
フォルダの項目が記録されていないアーカイブでも、ファイルの保存場所から階層を組み立てて表示します。
Finder で開くアプリを変更する方法は[READMEの基本の使い方](../README.md#基本の使い方)をご覧ください。

分割アーカイブは全巻を同じフォルダに置きます。`.001` / `.zNN` / `.zxNN` の巻は Finder に関連付けません。
「開く…」か、「ようこそKaitoFinderへ」ウインドウの「アーカイブを開く」へのドロップで開いてください。
途中の巻を選んでも、最初に開く巻があればセット全体を表示します。

パスワードは必要なときに入力します。「このパスワードを記憶」を選ぶと次回から自動使用できます（標準ではオフです）。

## 取り出す

- ファイルやフォルダを Finder や他のアプリへドラッグします。ドロップ先が受け取る時点で展開します。
- ⌘C では一時的な保存場所に展開したファイルをコピーします。Finder などへペーストできます。「展開」「すべて展開…」では展開先を指定できます。
- Space で「クイックルック」を開きます。「開く」「このアプリケーションで開く」でも確認できます。
  他のアプリへ渡すのは読み取り専用の一時コピーです。その変更は元のアーカイブに保存されません。
- 「表示 > プレビューを表示」（⇧⌘P）かツールバー右端のボタンで、右側に選択ファイルのプレビューを表示できます。
  新しく開いたアーカイブではオフです。境界をドラッグして幅を調整でき、アーカイブ・タブごとに切り替えられます。
  64 MiB を超えるファイル、サイズ不明のファイル、複数項目をまとめて圧縮したソリッド形式の 7z / RAR の項目は、「プレビューを表示」を押すと読み込みます。
- 「ファイル > アーカイブを展開…」で複数をまとめて展開できます。Finder のサービス「KaitoFinderで展開」も、文書ウインドウを開かず同じ一括展開を行います。
- 元のアーカイブに付いた、インターネットから入手したファイルであることを示す印を、取り出すファイルにも引き継ぎます。
  `..` で展開先の外へ出る名前や、外の場所を指すシンボリックリンクなどは拒否し、展開先の内側だけに書き込みます。
- tar 系の名前に含まれる `\` と先頭の `C:` は、展開・ドラッグ・コピー・プレビューでも文字として保ちます。
  `\` をフォルダ区切りに変えたり、`C:` を取り除いたりしません。ただし、`\` で区切って見たときに `..` が含まれる名前は拒否します。

## 取り込む・編集する

編集できるアーカイブには、Finder や他のアプリからドラッグやペーストで追加できます。
削除・名称変更・新規フォルダの作成と、同じウインドウ内のドラッグによるフォルダ間の移動ができます。
⌥ を押しながらドラッグするとコピーになります。

「設定…」の「一般 › 変更の書き込み:」で書き込み方を選びます。既定の「すぐに書き込む」はその場で保存します。
「保存時にまとめて書き込む」は「保存」まで原本を変えずに変更を保留します。この設定は次に開くアーカイブから有効です。

### 分割アーカイブの編集と保存

「保存時にまとめて書き込む」を選んでから開くと、一つのアーカイブを複数のファイルに区切った、番号付きの分割アーカイブも編集できます。
対象は ZIP・7z・LHA・tar と、書き込み可能な圧縮 tar の `.001…` です。
保存するまでは原本を変えず、保存時に元と同じ巻サイズで分割し直します。巻サイズが揃っていない場合は保存時に選びます。
FAT/exFAT・ネットワーク・同期フォルダへの保存には確認が必要です。中断した保存は、次に開くときに回復を提案します。
巻サイズが揃ったセットは「すぐに書き込む」でも編集できますが、編集ごとに確認し、変更は取り消せません。
「別名で保存…」の「分割:」では「しない」、元と同じ巻サイズ、「サイズを指定…」を選べます。
ZIP 本来の分割（`.z01…/.zip`）は読み取り専用です。

### 取り消しと外部からの変更

単一ファイルの即時編集と、保存前の保留した変更は、⌘Z で取り消し、⇧⌘Z でやり直せます。
単一ファイルの即時編集前には、原本と同じ保存領域に一時コピーを残し、取り消すときに戻します。
開いた後に原本が他のアプリなどで変更されていると、編集も取り消しもできません。
原本が別のファイルに置き換わったか、サイズや更新日時が変わったかで判断します。
同じファイルを同じサイズで上書きし、更新日時も元に戻すような変更は検出できません。

## 作成と変換

「新規アーカイブ…」（⌘N）や Finder のサービス「KaitoFinderで圧縮」から、ファイル・フォルダをアーカイブにまとめられます。
作成できる形式は ZIP / tar / tar.gz / tar.bz2 / tar.xz / tar.zst / tar.lz / tar.lzma / tar.lz4 / tar.br / tar.Z / 7z / LHA です。
「別名で保存…」（⇧⌘S）では元ファイルを残して別の形式へ変換し、同じ文書ウインドウで新しい保存先を開きます。
読み取り専用のアーカイブへの追加・ペーストでも、新しいアーカイブへの変換を案内します。
保存画面で形式・方式・レベルを選べます。[方式・レベル](formats.md#圧縮方式とレベル)、[1ファイルの圧縮](formats.md#1ファイルの圧縮)、[編集時の書き込み](formats.md#編集時の書き込み)も参照してください。

## 暗号化

暗号化は保存時に選びます（標準ではオフです）。ZIP の暗号方式は AES-256 が既定です。
macOS のアーカイブユーティリティでは AES-256 の ZIP を開けません。互換性が必要なら「ZipCrypto(互換性優先、安全性は低い)」を選べます。
7z は AES-256 と「ファイル名も暗号化」に対応します。tar（圧縮 tar を含みます）/ LHA は暗号化できません。

開いている ZIP / 7z には「パスワードを設定…」「パスワードを変更…」「パスワードを削除」を使えます。
これらの操作は全体を書き直します。単一ファイルの即時編集と保存前の保留した変更では、取り消し・やり直しもできます。
正しいパスワードが分かれば、暗号化された ZIP / 7z も追加・削除・名称変更できます。
通常の編集では、暗号化方式と 7z のファイル名の保護を引き継ぎます。

## 表示

Finder に似たリスト表示に、パスバー、タブ、ツールバーの検索、ステータスバーを備えています。
ツールバーには「戻る」「進む」「展開」「追加…」「新規フォルダ」「削除」「クイックルック」があり、配置を変更できます。
画像にはサムネイルを表示します。暗号化された画像、8 MiB を超える画像、ソリッド形式の 7z / RAR の項目は通常のアイコンになります。
「隠しファイルを表示」（⇧⌘.）で表示を切り替えると、検索結果とステータスバーの件数にも反映します。
表示で隠した項目も、フォルダ全体の展開・編集からは除かれません。

列のヘッダを右クリックするか「表示 > 列」で、表示する列を選べます。圧縮率・CRC-32・アクセス権・格納順も表示できます。
「表示 > フォルダを常に先頭に表示」では、並べ順にかかわらずフォルダを先頭にまとめます。
「表示 > 表示オプションを表示」（⌘J）では、並べ順・列の表示・アイコンと文字の大きさを変更できます。

選択済みのファイル名を、ダブルクリックにならない間隔でもう一度クリックすると名称変更できます。
最初のクリックは選択だけです。アイコン・名前のない余白・複数選択・ドラッグでは名称変更を始めません。
ファイルは拡張子を除く部分、フォルダは名前全体が選択されます。Return で確定、Escape で取り消します。
「一般」の「選択した名前をクリックして名称変更（Finderと同じ）」は標準でオンです。
オフにすると従来のクリック操作に戻りますが、Return と「名称変更」メニューは引き続き使えます。
この設定の変更は、開いているすべてのアーカイブにすぐ反映します。

ファイルはダブルクリック・⌘↓・⌘O で開きます。フォルダは標準でその中へ移動します。
「移動 > 戻る」（⌘[）・「進む」（⌘]）とツールバーで行き来し、「内包フォルダ」（⌘↑）で一つ上へ移動できます。
パスバーのフォルダからも移動できます。検索はアーカイブ全体が対象で、検索を消すと元のフォルダへ戻ります。
「一般 › フォルダを開くとき:」を「その場で展開」にすると、階層一覧を広げる従来の操作に戻ります。
Space でクイックルックを開きます。⌘Space など修飾キー付きの Space はクイックルックとして扱いません。

「一般 › アーカイブを開くとき:」では「macOSの設定に従う」（既定）・「新しいタブ」・「新しいウインドウ」を選べます。
Finder の関連付け、「開く…」、最近使った項目に共通で、変更は次に開くアーカイブから反映します。
既に開いているアーカイブをもう一度開くと、そのタブかウインドウを表示します。
タブの切り替え・分離・ウインドウの結合は、macOS 標準のウインドウメニューから行えます。
ファイルをドラッグしたまま別のタブの上で約0.6秒待つと、そのタブに切り替わり、一覧へドロップできます。
タブ上を短く通過しただけでは切り替わりません。

同じアーカイブ内のドラッグは移動、⌥ を押したドラッグはコピーです。
別のアーカイブへのドラッグは、同じウインドウの別タブも含めてコピーになり、元のアーカイブは変わりません。
フォルダと中身を一緒に選んでも、中身を重複して追加しません。
フォルダ上ならそのフォルダへ、ファイル上ならその親へ、一覧の空白部分なら表示中のフォルダへ追加します。
同名の項目があると、既存・追加元のサイズ、変更日、種類、場所を比較して「置き換える」「スキップ」「キャンセル」を選べます。
「内容を比較…」では、双方のファイルをクイックルックで左右に表示できます。
複数ファイルでは「残りのファイルにも適用」を使えます。フォルダや種類が異なる項目は別に確認し、フォルダは内容全体を置き換えます。
追加・ペースト・別のアーカイブやタブからのコピー・同じアーカイブ内の移動で、同じ確認を使います。
すべての回答が揃ってからまとめて反映します。取り消し可能なモードでは一回の「取り消す」で戻せます。
キャンセルや受信・書き込みの失敗では、全体の変更を中止します。

## ようこそウインドウ

「ようこそKaitoFinderへ」には二つの領域があります。「アーカイブを開く」へアーカイブをドロップすると開きます。
「アーカイブを作成」へファイルやフォルダをドロップすると作成に進みます。どちらもクリックして選べます。
「起動時にようこそウインドウを表示」をオフにすると、起動時の表示を省けます。
「ウインドウ > ようこそKaitoFinderへ」（⇧⌘1）で再表示できます。

## 設定

「設定…」（⌘,）には「一般」「圧縮」「展開」「アップデート」の四つのタブがあります。
アーカイブの開き方、既定の作成形式、隠しファイルやようこその表示、方式・レベル、展開先・フォルダの作成方針、展開成功後に元のアーカイブをゴミ箱へ移すかを選べます。
最後の設定をオンにした分割アーカイブの一括展開では、展開中にどの巻も変更されていないことを確認し、全巻をゴミ箱へ移します。
追加・新規作成時の `.DS_Store` の除外は標準でオン、隠しファイル全体の除外は標準でオフです。
これらの除外設定は、既存の項目の展開や形式変換には適用しません。

- 「一般 › フォルダを開くとき:」は「フォルダに移動」が既定です。「その場で展開」で従来の操作に戻せます。
- 「一般 › 追加した項目の位置:」は「末尾」が既定で、tar・圧縮 tar・7z・LHA に適用します。
  「先頭（編集のたびに全体を書き直す）」は先頭への追加に戻り、圧縮 tar・7z・LHA は全体を再圧縮します。ZIP は常に末尾です。
- 「圧縮 › 変更しない項目の所有者ID:」は、tar・圧縮 tar の既存の持ち主とグループの番号を「そのまま保つ」が既定です。
  「0に戻す（編集のたびに全体を書き直す）」で従来の扱いに戻せます。「追加するファイルの所有者ID(uid / gid)を保存」は、ディスクから追加する項目だけの別の設定です。
- 「圧縮 › 圧縮の並列数:」は「自動」が既定で、処理を同時に行う数を指定することもできます。
  明示指定の対応範囲は1〜1024です。設定の選択肢は通常Macの論理CPU数までで、それを超える保存済みの値も保持します（最大1024）。
  「自動（N）」は現在の電力設定で使う数です。通常はすべての有効な論理 CPU を使い、物理メモリの GiB 数や圧縮方式のメモリ制限に応じて減らします。
  7z・tar.xz のメモリ使用量の目安を表示します。開いているアーカイブも次の書き込みから反映し、「自動」で既定に戻せます。
- 「圧縮 › 電力の使用方針:」は「低電力モードで並列数を減らす」が既定です。
  「低電力モードや高温時に並列数を減らす」「常にすべてのコアを使う」も選べます。高温時の削減は macOS が深刻または危険な温度状態を報告したときに行います。
  次に始める圧縮・展開・パスワード検証に適用します。圧縮の並列数を明示した場合、その圧縮とパスワード検証では電力設定による削減を行いません。
  展開は処理量や独立した項目の数に応じて並列化し、圧縮の並列数の指定とは別に電力設定を使います。
- 「圧縮 › 速さを優先する（圧縮率がわずかに下がります）」は既定でオフです。オンにすると、ZIPのXZ・Zstandard、7z、単独のXZ・lzipなどで独立した圧縮片を増やし、コア数の多いMacで圧縮を速めます。
  一般的なテキストやバイナリでは出力サイズが約1〜7%増え、繰り返しの多いデータではさらに増えることがあります。tar.xz・tar.lzの圧縮片の幅は変わりません。
  次のアーカイブ作成・更新から反映され、開いているアーカイブにも適用します。同じ設定・入力での圧縮結果は、Macのコア構成や並列数に依存しません（暗号化で毎回変わる乱数などを除きます）。
- 「一般 › 変更の書き込み:」の変更は、次に開くアーカイブから有効です。

### アップデート

Sparkle による自動更新に対応しています。「アップデート」で自動確認・自動ダウンロードとインストールを選び、最終確認日時を確認できます。
自動確認は標準で有効です。「KaitoFinder > アップデートを確認…」から手動でも確認できます。
自動ダウンロード・インストールは選択式で、有効にすると取得した更新を終了時にインストールします。
詳細は[自動更新の利用者向けの動作](software-updates.md#利用者向けの動作)を参照してください。

## 終了と後始末

展開・追加・作成などの途中で終了（⌘Q）すると確認します。「終了」を選ぶと操作を取り消し、途中まで書き出した項目・作業コピー・取り消し用コピーを片付けてから終了します。
強制終了やクラッシュで残った作業用フォルダは、アプリの記録を使って次回起動時に回収します。

## 言語

次の26言語に対応し、未対応の言語では英語を表示します。

日本語、英語、ドイツ語、フランス語、スペイン語、イタリア語、ポルトガル語（ブラジル）、ポルトガル語（ポルトガル）、
中国語（簡体字）、中国語（繁体字）、韓国語、タイ語、ベトナム語、インドネシア語、マレー語、ヒンディー語、ロシア語、
オランダ語、ポーランド語、トルコ語、スウェーデン語、デンマーク語、ノルウェー語（ブークモール）、フィンランド語、ウクライナ語、チェコ語。

## English

Detailed operations for KaitoFinder 0.7.0. See also [installation](../README.md#install), [formats](formats.md#english), and [limitations](limitations.md#english).

### Open

Use File > Open… or Finder's Open With to browse a [supported format](formats.md#readable-formats).
Folder hierarchies are built from file paths even when no directory entries were stored.
See the [README quick start](../README.md#quick-start) to change the app Finder uses.
Keep all split volumes in one folder. `.001` / `.zNN` / `.zxNN` have no Finder associations; use Open… or the Open Archive area in Welcome to KaitoFinder.
Selecting a later volume opens the whole set when its entry volume is present.
Passwords are requested when needed. “Remember this password” enables automatic reuse and is off by default.

### Extract

- Drag files or folders to Finder or another app. Extraction happens when the destination accepts the drop.
- ⌘C extracts to temporary storage and copies real files for pasting. Extract and Expand All… let you choose a destination.
- Space opens Quick Look. Open and Open With also show contents using read-only temporary copies; changes in other apps do not save back to the archive.
- View > Show Preview (⇧⌘P), or the rightmost toolbar button, shows the selected file in a sidebar.
  It is off for newly opened archives. Drag the boundary to resize it; visibility is separate for each archive and tab.
  Files larger than 64 MiB, files with unknown sizes, and items in solid 7z / RAR archives (which compress several items together) load after pressing Show Preview.
- File > Expand Archives… extracts several archives together. Finder's “Expand with KaitoFinder” service uses the same batch operation without opening document windows.
- The source archive's mark identifying downloaded files is passed to extracted files. Names escaping the destination through `..`, symbolic links pointing outside it, and other unsafe paths are refused; writing stays inside the destination.
- In tar names, `\` and a leading `C:` are kept as literal characters when extracting, dragging, copying, or previewing.
  `\` does not become a folder separator, and `C:` is not removed. Names containing a `..` component when split at `\` are still refused.

### Add and Edit

Drag or paste files from Finder or other apps into editable archives. Delete, rename, create folders, and drag items between folders in the same window; hold ⌥ to copy instead of move.
Settings… > General > Write Changes: controls saving. Immediately (the default) saves each edit; Together When Saving holds changes until Save, leaving the original untouched.
The setting applies to archives opened afterwards.

#### Split archives

Choose Together When Saving before opening numbered split archives (one archive cut into files: `.001…` for ZIP, 7z, LHA, tar, and writable compressed tar) to edit them.
Save splits the updated archive using the original volume size. Uneven sets offer a size choice when saving.
Saving on FAT/exFAT, network volumes, or sync folders asks for consent. Interrupted saves offer recovery when reopening.
Uniform sets also support Immediately mode with confirmation for every edit; these changes cannot be undone.
Save As… offers None, the original volume size, or Specify Size… under Split:. Native split ZIP (`.z01…/.zip`) remains read-only.

#### Undo and external changes

Undo single-file immediate edits or pending changes with ⌘Z; redo with ⇧⌘Z.
Before a single-file immediate edit, a temporary backup on the original's storage volume allows restoration.
Editing and undo are refused if the original changed in another app after opening.
Detection checks whether it is still the same file and whether its size or modification time changed.
An overwrite of the same file that preserves its size and restores its modification time is not detected.

### Create and Convert

New Archive… (⌘N) or Finder's “Compress with KaitoFinder” service creates an archive from files and folders.
Available formats are ZIP / tar / tar.gz / tar.bz2 / tar.xz / tar.zst / tar.lz / tar.lzma / tar.lz4 / tar.br / tar.Z / 7z / LHA.
Save As… (⇧⌘S) converts to a new file, keeps the original, and switches the same document window to the saved file.
Adding or pasting into a read-only archive also offers conversion to a new archive.
Choose format, method, and level in the save panel. See [methods and levels](formats.md#english), [single-file compression](formats.md#single-file-compression), and [update behavior](formats.md#update-behavior).

### Encryption

Encryption is optional and off by default. ZIP defaults to AES-256 when enabled.
macOS Archive Utility cannot open AES-256 ZIP; “ZipCrypto (More Compatible, Less Secure)” offers legacy compatibility.
7z supports AES-256 and Encrypt File Names. tar (including compressed tar) and LHA cannot be encrypted.
Open ZIP / 7z documents offer Set Password…, Change Password…, and Remove Password.
These operations rewrite the whole archive; single-file immediate edits and pending changes support undo and redo.
With the correct password, encrypted ZIP / 7z can also be added to, deleted from, or renamed. Normal edits preserve the encryption method and 7z filename protection.

### View

The Finder-like list has a path bar, tabs, toolbar search, and a status bar.
The customizable toolbar offers Back, Forward, Extract, Add…, New Folder, Delete, and Quick Look.
Images have thumbnails; encrypted images, images larger than 8 MiB, and solid 7z / RAR items keep regular icons.
Show Hidden Files (⇧⌘.) also affects search results and status counts. Hidden items remain included in whole-folder extraction and editing.
Right-click a column header or use View > Columns to choose columns, including compression ratio, CRC-32, permissions, and archive order.
View > Keep Folders on Top groups folders first regardless of sort order. View > Show View Options (⌘J) changes sorting, visible columns, and icon and text size.

Click an already selected filename again, slowly enough to avoid a double-click, to rename it.
The first click only selects. Icons, blank name areas, multiple selections, and drags do not start renaming.
Files select the name without the extension; folders select the entire name. Return confirms; Escape cancels.
“Click a selected name to rename it (like Finder)” in General is on by default. Turning it off restores the earlier click behavior; Return and Rename remain available.
This setting takes effect in all open archives immediately.

Double-click, ⌘↓, or ⌘O opens a file; opening a folder enters it by default.
Go > Back (⌘[), Forward (⌘]), and toolbar buttons navigate history; Enclosing Folder (⌘↑) moves up.
Path-bar folders also navigate. Search covers the entire archive; clearing it returns to the original folder.
General > When opening folders: > Expand in Place restores the earlier expanding-list behavior.
Space opens Quick Look; modified Space, such as ⌘Space, does not.

General > When opening archives: offers Follow macOS Settings (default), New Tab, or New Window.
This applies to Finder associations, Open…, and recent items, starting with the next archive opened.
Reopening an already open archive selects its existing tab or window. The standard macOS Window menu switches or separates tabs and merges windows.
Hold a file drag over another tab for about 0.6 seconds to select it, then drop into its list. Briefly passing over a tab does not select it.

Dragging within an archive moves items; holding ⌥ copies. Dragging to another archive, including another tab in the same window, copies and leaves the source unchanged.
Selecting a folder and its children does not add the children twice. Dropping onto a folder adds there; onto a file adds to its parent; onto blank list space adds to the displayed folder.
For name conflicts, compare existing and incoming size, modification date, kind, and location, then choose Replace, Skip, or Cancel.
Compare Contents… shows both files side by side in Quick Look. Apply to Remaining Files repeats the choice for a batch; folders and type changes ask separately, and replacing a folder replaces all its contents.
The same prompts apply to adding, pasting, copying from another archive or tab, and moving within an archive.
Changes are applied together after all answers. In a mode supporting undo, one Undo reverses them. Cancel or a receiving or writing failure aborts the entire batch.

### Welcome Window

Welcome to KaitoFinder has two areas. Open Archive opens dropped archives; Create Archive starts creation from dropped files or folders. Both can also be clicked.
Turn off Show the welcome window at launch in Settings to hide it at startup. Window > Welcome to KaitoFinder (⇧⌘1) shows it again.

### Settings

Settings… (⌘,) has General / Compression / Extract / Updates tabs.
Choose how archives open, the default creation format, hidden-file and welcome display, methods and levels, extraction destinations and folder rules, and whether to trash the source after successful extraction.
When enabled for split archives, batch extraction checks that no volume changed during extraction, then moves all volumes to the Trash.
When adding or creating, excluding `.DS_Store` is on by default; excluding all hidden files is off. These exclusions do not apply to extracting or converting existing entries.

- General > When opening folders: defaults to Enter Folder; Expand in Place restores the earlier behavior.
- General > Position of added items: defaults to At the end for tar, compressed tar, 7z, and LHA. At the beginning (rewrite the entire archive on every edit) restores prepending and recompresses all compressed tar / 7z / LHA data. ZIP always appends.
- Compression > Owner IDs of unchanged items: defaults to Keep unchanged for existing tar / compressed tar user and group IDs. Reset to 0 (rewrite the entire archive on every edit) restores the previous behavior.
  Preserve owner IDs (uid / gid) of files being added is a separate setting affecting only files added from disk.
- Compression > Compression threads: defaults to Automatic; you can specify the number of concurrent tasks. Estimated memory use is shown for 7z / tar.xz, and open archives use the choice on the next write. Automatic restores the default.
  Explicit counts support 1–1024. Settings normally offers values up to the Mac's logical CPU count and retains a higher saved value, up to 1024.
  Automatic (N) shows the current count under the selected power policy. Normally it uses all active logical CPUs, subject to physical memory in GiB and compression method memory limits.
- Compression > Power usage: defaults to Reduce threads in Low Power Mode. You can also choose Reduce threads in Low Power Mode or when hot, or Always use all cores. The temperature option reduces threads when macOS reports serious or critical thermal pressure.
  This applies to the next compression, extraction, or password verification operation. An explicit compression thread count bypasses power-based reductions for compression and password verification. Extraction uses the power policy independently of the compression thread count, and runs in parallel when the workload and independent entries allow it.
- Compression > Prefer speed (slightly larger archives) is off by default. Turning it on increases independent compression pieces for methods such as ZIP XZ / Zstandard, 7z, and standalone XZ / lzip, helping compression run faster on Macs with many cores.
  Output is typically about 1–7% larger for text and binary data, and can grow more for highly repetitive data. Compression piece sizes for tar.xz / tar.lz stay the same.
  It applies to the next archive creation or update, including writes to open archives. With the same settings and input, compression output is independent of the Mac's core configuration and thread count (apart from randomness such as encryption salts).
- General > Write Changes: applies to archives opened after the setting changes.

#### Updates

Sparkle provides automatic updates. Updates controls automatic checks, downloads and installation, and shows the last check time.
Checks are enabled by default; KaitoFinder > Check for Updates… checks manually. Automatic downloads and installation on quit are optional.
See [update behavior for users](software-updates.md#利用者向けの動作).

### Quitting and Cleanup

Quitting (⌘Q) during extraction, addition, or creation asks for confirmation. Quit cancels the operation and removes partial output, working copies, and undo backups before exiting.
Working folders left by a force quit or crash are recovered at the next launch using the app's records.

### Languages

Supported UI languages are Japanese, English, German, French, Spanish, Italian, Portuguese (Brazil), Portuguese (Portugal),
Chinese (Simplified), Chinese (Traditional), Korean, Thai, Vietnamese, Indonesian, Malay, Hindi, Russian, Dutch, Polish, Turkish,
Swedish, Danish, Norwegian Bokmål, Finnish, Ukrainian, and Czech: 26 in total. Unsupported languages fall back to English.
