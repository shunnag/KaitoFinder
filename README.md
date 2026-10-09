# KaitoFinder

KaitoFinder は、macOS で圧縮ファイル（アーカイブ）の中身を見たり、編集したりできるアプリです。
Finder に似た操作で、必要なファイルを取り出したり、追加したりできます。ZIP や 7z、古い Mac のアーカイブなどを開けます。

## できること

- アーカイブを開き、フォルダやファイルを一覧する
- ファイルやフォルダを Finder へドラッグして取り出す
- 対応するアーカイブにファイルを追加し、削除・名称変更する
- ZIP・7z・LHA・tar などを作成し、別の形式へ変換する
- パスワード付きのアーカイブを開き、ZIP・7z を暗号化する
- 分割アーカイブを開き、「別名で保存…」で分割して保存する
- Space キーでクイックルックを使い、中身を確認する

## 動作環境

**macOS 26 以降・Apple Silicon 搭載の Mac** が必要です。

## ダウンロードとインストール

1. [GitHub Releases の最新版](https://github.com/shunnag/KaitoFinder/releases/latest)から ZIP をダウンロードします。
2. ZIP を展開し、`KaitoFinder.app` を「アプリケーション」フォルダに移動します。
3. KaitoFinder を起動します。配布アプリは Developer ID で署名し、Apple の公証を受けています。

Sparkle による更新の自動確認は標準でオンです。手動で確認するには「**KaitoFinder > アップデートを確認…**」を選びます。
自動ダウンロード・終了時のインストールは、「設定…」の「アップデート」で有効にできます。

## 基本の使い方

1. **開く:** 「ファイル > 開く…」で選ぶか、「ようこそKaitoFinderへ」ウインドウの「アーカイブを開く」へドロップします。
2. **取り出す:** 中のファイルを Finder へドラッグします。「すべて展開…」なら全体を取り出せます。
3. **追加する:** 編集できるアーカイブの一覧へ、Finder からファイルをドラッグします。名称変更や削除もできます。
4. **作成・変換する:** 「ファイル > 新規アーカイブ…」（⌘N）でファイルを選び、保存画面で形式を選びます。
   「別名で保存…」（⇧⌘S）なら、元のファイルを残して別の形式へ変換できます。

Finder では右クリックの「このアプリケーションで開く」から KaitoFinder を選べます。
ZIP・tar.gz・DMG などは補助的な関連付けのため、ダブルクリックでは現在の既定アプリが開く場合があります。
常に KaitoFinder で開くには「情報を見る」→「このアプリケーションで開く」で選び、「すべてを変更…」を使います。

編集は標準でその場で保存されます。「設定…」の「一般 › 変更の書き込み:」で「保存時にまとめて書き込む」を選ぶと、
**次に開くアーカイブから**「保存」まで変更を保留できます。分割アーカイブの編集には確認や制約があります。

Finder のサービスの「**KaitoFinderで圧縮**」からも作成できます。アプリを「アプリケーション」へ置き、一度起動すると登録されます。
一括展開には「ファイル > アーカイブを展開…」か、Finder のサービス「KaitoFinderで展開」を使います。[詳しい操作](Documentation/user-guide.md)もご覧ください。

## よくある質問・困ったとき

- **作った ZIP をアーカイブユーティリティで開けません。** 圧縮方式は標準の Deflate を選んでください。
  BZip2・LZMA・XZ・Zstandard・PPMd、AES-256 の ZIP は開けません。暗号化で互換性が必要なら、保存時に「ZipCrypto(互換性優先、安全性は低い)」を選べます。[互換性の詳細](Documentation/formats.md#互換性)をご覧ください。
- **パスワードを求められます。** 作成者が設定したパスワードが必要です。「このパスワードを記憶」は次回から自動使用する設定で、標準ではオフです。[暗号化の操作](Documentation/user-guide.md#暗号化)をご覧ください。
- **分割アーカイブはどう開きますか。** 全巻を同じフォルダに置き、「ファイル > 開く…」で選びます。
  `.001`・`.zNN`・`.zxNN` は Finder に関連付けません。[編集と保存の条件](Documentation/user-guide.md#分割アーカイブの編集と保存)も確認してください。
- **設定や表示を変えたいです。** 「KaitoFinder > 設定…」（⌘,）に一般・圧縮・展開・アップデートの設定があります。列や文字の大きさは「表示 > 表示オプションを表示」（⌘J）で変更できます。
- **開けない・編集できない形式があります。** 読み取り専用の形式は「別名で保存…」で変換できます。
  [対応形式](Documentation/formats.md)と[制限](Documentation/limitations.md)を確認し、問題が続く場合は[GitHub Issues](https://github.com/shunnag/KaitoFinder/issues)へアプリと macOS のバージョン・形式・操作手順をお知らせください。

## 対応形式

| 主な形式 | 開く・展開 | 作成・編集 |
| --- | --- | --- |
| ZIP / ZIP64、7z、LHA / LZH | ○ | ○（対応範囲内） |
| tar、tar.gz、tar.bz2、tar.xz などの圧縮 tar | ○ | ○ |
| RAR、StuffIt / StuffIt X、ISO、DMG など | ○（対応範囲内） | 読み取り専用 |
| 単体の gzip、bzip2、xz、Zstandard など | ○ | 1ファイルからの新規作成のみ |

圧縮方式や分割方法により対応範囲が異なります。全形式・方式・レベルは[対応形式の詳細](Documentation/formats.md)をご覧ください。

## 言語

日本語・英語を含む **26言語**に対応し、未対応の言語では英語を表示します。[対応言語の一覧](Documentation/user-guide.md#言語)もあります。

## プライバシー

閲覧・展開・編集は Mac 上で行います。更新の確認・ダウンロードでは GitHub Releases に接続します。
自動確認は「設定…」の「アップデート」でオフにできます。

## ライセンスと謝辞

KaitoFinder は [MIT ライセンス](LICENSE)で公開しています。0.7.0 には次のライブラリを同梱しています。

- [KaitoKit](https://github.com/shunnag/KaitoKit) 0.12.1 — 読み取り
- [GyoshukuKit](https://github.com/shunnag/GyoshukuKit) 0.9.0 — 書き込み
- [Sparkle](https://sparkle-project.org/) 2.10.0 — 自動更新

開発者向けのビルド・テスト・配布手順は[開発者向け情報](Documentation/development.md)をご覧ください。

## English

### What it does

KaitoFinder is a Finder-like archive browser and editor. Browse and extract files, add, delete or rename entries,
create and convert archives, encrypt ZIP / 7z, save split archives with Save As…, and preview with Space (Quick Look).

### Requirements

**macOS 26 or later on Apple Silicon.**

### Install

Download the ZIP from [the latest release](https://github.com/shunnag/KaitoFinder/releases/latest), extract it, and move `KaitoFinder.app` to Applications.
The app is signed and notarized. Sparkle checks automatically; use KaitoFinder > Check for Updates… to check manually.
Settings… > Updates enables automatic downloads and installation on quit.

### Quick start

1. Use File > Open…, or drop an archive onto Open Archive in the Welcome to KaitoFinder window.
2. Drag files or folders to Finder to extract; Expand All… extracts everything. Drag files in to add to an editable archive.
3. Use File > New Archive… (⌘N), choose files and a format, or Save As… (⇧⌘S) to convert while keeping the original.

In Finder, choose Open With > KaitoFinder. ZIP, tar.gz, DMG and some other types register as alternate handlers, so double-clicking may use your current default app.
To change it for that type, use Get Info → Open with → KaitoFinder → Change All….
Edits save immediately by default. Settings… > General > Write Changes: > Together When Saving defers changes until Save, **starting with the next archive you open**.
Finder services “Compress with KaitoFinder” and “Expand with KaitoFinder” are registered after placing the app in Applications and launching it once.
File > Expand Archives… also extracts several archives together. See the [user guide](Documentation/user-guide.md#english).

### FAQ

- **ZIP compatibility:** Choose Deflate for macOS Archive Utility; BZip2 / LZMA / XZ / Zstandard / PPMd and AES-256 ZIP cannot be opened by it.
  When encrypting, “ZipCrypto (More Compatible, Less Secure)” offers legacy compatibility. See [compatibility](Documentation/formats.md#compatibility).
- **Passwords:** Enter the creator's password. “Remember this password” reuses it automatically and is off by default.
- **Split archives:** Keep all volumes together and use File > Open…; `.001` / `.zNN` / `.zxNN` have no Finder association. Check the [editing conditions](Documentation/user-guide.md#add-and-edit).
- **Settings:** KaitoFinder > Settings… (⌘,) has General / Compression / Extract / Updates. View > Show View Options (⌘J) changes columns and text size.
- **Read-only or unsupported files:** Try Save As… to convert; see [limitations](Documentation/limitations.md#english). Report app and macOS versions, format and steps via [GitHub Issues](https://github.com/shunnag/KaitoFinder/issues).

### Formats

ZIP / ZIP64, 7z, LHA / LZH, tar and compressed tar support creation and editing within their supported ranges.
RAR, StuffIt / StuffIt X, ISO, DMG and other formats are read-only; standalone compressed streams can be created from one file but stay read-only.
See the [full format list and settings](Documentation/formats.md#english).

### Languages

26 UI languages, including Japanese and English; unsupported languages fall back to English.

### Privacy

Archive operations run on your Mac. Update checks and downloads connect to GitHub Releases; turn automatic checks off in Settings… > Updates.

### License

[MIT licensed](LICENSE). Version 0.7.0 includes KaitoKit 0.12.1 (reading), GyoshukuKit 0.9.0 (writing), and Sparkle 2.10.0 (updates).
