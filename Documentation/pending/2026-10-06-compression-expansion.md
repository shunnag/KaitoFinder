# 圧縮出力の拡張候補と今回の接続

日付: 2026-10-06
対象: KaitoFinder `feature/compression-formats-ui` と、読み取り専用の隣接 GyoshukuKit `feature/write-methods-levels`。
ライブラリの公開 API を使い、AppKit の保存パネル・設定・新規作成・形式変換・既存アーカイブの編集へ接続する。ライブラリ側の変更とコミットは行わない。

## 今回の実装

| 出力 | 方式 | レベルと扱い |
|---|---|---|
| ZIP | Deflate（既定）、BZip2（12）、LZMA（14）、XZ（95）、Zstandard（93）、PPMd（98）、stored | Deflate / BZip2 / PPMd は 1〜9、LZMA / XZ は 0〜9、Zstandard は 1〜19（標準 3）。PPMd の標準は 6。Zstandard に無圧縮は表示しない |
| tar | 無圧縮 | 選択できるレベルなし |
| tar.gz / 単独 .gz | Deflate | 1〜9 |
| tar.bz2 / 単独 .bz2 | BZip2 | 1〜9 |
| tar.xz / 単独 .xz | XZ（LZMA2） | 0〜9。6 は lzmaLevel nil で従来の Apple 経路を維持 |
| tar.zst / 単独 .zst | Zstandard | 1〜19、標準は 3、無圧縮なし |
| tar.lz / 単独 .lz | lzip（LZMA1） | 0〜9。標準は 6 |
| tar.lzma / 単独 .lzma | LZMA_Alone | 0〜9。標準は 6 |
| tar.lz4 / 単独 .lz4 | LZ4 frame | 選択できるレベルなし |
| tar.br / 単独 .br | Apple Brotli | 選択できるレベルなし |
| tar.Z / 単独 .Z | UNIX compress（LZW） | 選択できるレベルなし |
| 7z | LZMA2（既定）、LZMA、Deflate、BZip2、PPMd、Copy | LZMA 系は 0〜9、Deflate / BZip2 / PPMd は 1〜9。PPMd の標準は 6。無圧縮は Copy。LZMA2 の 6 は Apple 経路を維持 |
| LHA | lh5（既定）、lh6、lh7、stored（-lh0-） | 1〜9、標準は 6。無圧縮は stored |

保存パネル、既定フォーマット、読み取り専用アーカイブへの drop の変換先は 13 形式で共通。
ZIP XZ のレベル 6 も lzmaLevel nil にし、従来の byte 列を保つ Apple 経路を使う。
旧 ZIP レベルキーは Deflate / BZip2 用に保ち、LZMA / XZ、Zstandard、PPMd にはそれぞれ別キーを設ける。tar.zst と 7z PPMd のレベル、7z の solid と filter も専用キーへ保存する。単独 .zst は tar.zst のレベルを使う。未知の方式、不正な数値、真偽値、文字列は既定へ戻す。
方式とレベルは形式ごとに設定へ保存し、保存パネル内の変更は形式ごとにメモリへ保持する。
新しい compound extension の保存 UTType を宣言する。.tlz は lzip と LZMA で曖昧なため出力には使わず、既存の読み取り動作を保つ。.tzst / .tbr / .taz は明示した入力の別名として受理する。

新しい tar.zst / tar.lz / tar.lzma / tar.lz4 / tar.br / tar.Z は ArchiveRewriter で追加・削除・改名・置換する。
CompressedTarUpdater の splice は tar.gz / tar.bz2 / tar.xz に限る。新しい形式を updater に渡さない。
既存項目の表現可能性は ArchiveRewriter.probe(reader:format:) で確認し、設定の方式・レベル・所有者 ID・追加位置を編集にも渡す。
単独 .zst を含む単独 stream は、利用者の決定に従って読み取り専用を保つ。

7z の保存パネルと設定には「ソリッド圧縮」と「フィルタ」を表示し、ほかの形式では隠す。
ソリッド圧縮は既定オフ。オンは `sevenZipSolid: .on(blockSize: nil, filesPerBlock: nil)` とし、block のサイズと件数は GyoshukuKit の既定に任せる。
ソリッドブロック内の項目の削除では、そのブロックを再圧縮する旨を短く表示する。
フィルタは「なし」（既定）/「自動」/「x86 (BCJ)」/「ARM64」/「Delta」。Delta の距離は 4 に固定し、32 bit サンプル内の同じ byte 位置を差分化する。
PPMd は ZIP var.I と 7z var.H の preset レベルを渡し、`ppmdOrder` / `ppmdMemoryMiB` の上書きは UI に表示せず nil のままにする。
既存書庫の追加と再圧縮にも、対応形式の `ppmdLevel` / `zstdLevel` / `sevenZipSolid` / `sevenZipFilter` を渡す。

## 利用者の決定

- ライセンス上採用できる形式・方式・レベルをできるだけ追加する。
- 単独ファイル圧縮は作成専用。選択元が通常ファイル 1 個の場合だけ表示し、フォルダ・symlink・パッケージを対象にしない。
- 複数の選択元には tar.X を使う。単独 stream を開いても編集を許可しない。
- 単独出力は元のファイル名と拡張子を残す（例: report.pdf.gz）。既定フォーマットとして記憶せず、次回は既定のアーカイブ形式へ戻す。
- ZIP の既定は Deflate。BZip2 / LZMA / XZ / Zstandard / PPMd は macOS Archive Utility / ditto / /usr/bin/unzip で開けないため、方式選択時に短い互換性の注記を表示する。

## 残る候補

| 候補 | 保留理由・条件 |
|---|---|
| .aar / .lzfse | Apple Archive の容器・メタデータ方針と単独 LZFSE の公開 API が未対応。用途と読み取りとの往復を確認してから追加 |
| LZMA extreme | API に探索量の設定はあるが、今回の指定 UI は数値レベルまで。標準レベル 6 の Apple 経路と共存する表示を別途検討 |
| Mac の fork / xattr 保存 | GyoshukuKit の preserveMacOSMetadata は未対応。メタデータを保持できる仕様と往復検証が必要 |

## 今回採用しない候補

| 候補 | 理由 |
|---|---|
| RAR 出力 | RARLAB ライセンスの制約から採用しない。読み取りは継続 |
| StuffIt / StuffIt X 出力 | 公開された書き込み仕様・再配布可能な encoder・検証用資料が十分でないため保留。読み取りは継続 |
| ARJ 出力 | GyoshukuKit に encoder がなく、既存 encoder のライセンスと仕様の検証が必要。今回の拡張から除外 |
| CAB-LZX / WIM 出力 | Microsoft の特許通知があるため今回の候補から除外。読み取り実装との可否は分けて扱う |
| 7z Zstd coder 出力 | 標準の 7-Zip で開けないため採用しない。既存の読み取り対応は継続 |

## 検証

形式・方式・全数値レベルの WriterOptions 対応、設定の保存・旧キーの移行、単独ファイルの表示条件、全形式の拡張子、作成・変換後の項目と本文、6 形式の編集、26 言語の翻訳をテストする。
GUI の実保存パネル検証は既存の KAITOFINDER_NATIVE_SAVE_REQUEST による opt-in を維持する。

2026-10-07、Mac mini M4（macOS 27.2 / Xcode 27.0）での確認結果:

- 全体スイートは 1742 件、スキップ 33、失敗 0。GyoshukuKit `feature/write-methods-levels` の `f273d34` と組み合わせた。
- GyoshukuKit の全体スイートは同じ `f273d34` で 728 件、スキップ 21、失敗 0。
- `Tools/verify_finder_interactions.py` と `Tools/verify_save_panel_animation.py` は成功。保存パネルの 4 つの表示経路を確認した。
- `Tools/verify_ui_integration.py` は最終コミットで 1 回、コマンド 76 件・実保存 5 件・最近使った項目の 4 回の起動まで成功。もう 1 回は既知の問題 1 で止まった。
- `Tools/press_verification_save.swift` は名前欄が期待値になるまで期限内で読み直す。

GUI 検証で見つけて修正したもの:

- ZIP 選択中に `keep.tar.gz` と入力して tar.gz へ切り替えると `keep.tar.gz.tar.gz` になった。直前形式の拡張子だけを外していたため、一致しない場合は既知のアーカイブ拡張子を外す。
- 拡張子を隠した tar.Z / 単独 .Z が `review.tar.z` で保存された。LaunchServices が宣言した拡張子のタグを小文字にするため AppKit が .tar.z を付ける。`panel(_:userEnteredFilename:confirmed:)` で正規の表記に戻し、大小文字を区別する保存先で別のファイルがある場合は戻さない。
- 保存パネルの付属ビューのサイズ取得でレイアウトを強制すると、制約更新が繰り返されて固まった。
- 7z の行を隠す前にサイズを決めていたため、初期の高さが 60pt 大きかった。`accessoryView` へ代入する前にサイズを確定する。XPC 側は代入時のサイズを保持する。

単独 .Z の大小文字の補正は単体テストだけで確認した。実保存パネルの検証は単独形式を扱っていない。

## 既知の問題

1. `ArchiveCreationUITests.testPresentedSavePanelSwitchesFormatsAfterEditingTheName`（実保存パネル、156 通りの形式の組み合わせ）は、ときどき 1 組で名前欄が AppKit の末尾一つの置換（例: `edited.report.TAR.zst`、`edited.report.lz4`）のまま残る。
   形式変更時のアプリの状態（拡張子表示、名前、再構成していないこと）は正しく、名前の付け替えを計算してパネルを開き直している。
   開き直した後も 5 秒以上この表示が続くため、そのまま保存すると誤った名前になる。
   発生は組み合わせの約 0.5% で、どの組み合わせかは毎回異なる。
   開き直しの仕組みは main と同じで、main の 42 通りでは再現していない。
   開き直し直前の `panel.isVisible` と、設定直後の `nameFieldStringValue` の記録が次の調査。
