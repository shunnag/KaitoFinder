# 圧縮出力の拡張候補と今回の接続

日付: 2026-10-06
対象: KaitoFinder `feature/compression-formats-ui` と、読み取り専用の隣接 GyoshukuKit `feature/write-methods-levels`。
ライブラリの公開 API を使い、AppKit の保存パネル・設定・新規作成・形式変換・既存アーカイブの編集へ接続する。ライブラリ側の変更とコミットは行わない。

## 今回の実装

| 出力 | 方式 | レベルと扱い |
|---|---|---|
| ZIP | Deflate（既定）、BZip2（12）、LZMA（14）、XZ（95）、stored | Deflate / BZip2 は 1〜9、LZMA / XZ は 0〜9。無圧縮は stored |
| tar | 無圧縮 | 選択できるレベルなし |
| tar.gz / 単独 .gz | Deflate | 1〜9 |
| tar.bz2 / 単独 .bz2 | BZip2 | 1〜9 |
| tar.xz / 単独 .xz | XZ（LZMA2） | 0〜9。6 は lzmaLevel nil で従来の Apple 経路を維持 |
| tar.lz / 単独 .lz | lzip（LZMA1） | 0〜9。標準は 6 |
| tar.lzma / 単独 .lzma | LZMA_Alone | 0〜9。標準は 6 |
| tar.lz4 / 単独 .lz4 | LZ4 frame | 選択できるレベルなし |
| tar.br / 単独 .br | Apple Brotli | 選択できるレベルなし |
| tar.Z / 単独 .Z | UNIX compress（LZW） | 選択できるレベルなし |
| 7z | LZMA2（既定）、LZMA、Deflate、BZip2、Copy | LZMA 系は 0〜9、Deflate / BZip2 は 1〜9。無圧縮は Copy。LZMA2 の 6 は Apple 経路を維持 |
| LHA | lh5（既定）、lh6、lh7、stored（-lh0-） | 1〜9、標準は 6。無圧縮は stored |

保存パネル、既定フォーマット、読み取り専用アーカイブへの drop の変換先は 12 形式で共通。
ZIP XZ のレベル 6 も lzmaLevel nil にし、従来の byte 列を保つ Apple 経路を使う。
旧 ZIP レベルキーは Deflate / BZip2 用に保ち、LZMA / XZ には別キーを設ける。未知の方式、不正な数値、真偽値、文字列は既定へ戻す。
方式とレベルは形式ごとに設定へ保存し、保存パネル内の変更は形式ごとにメモリへ保持する。
新しい compound extension の保存 UTType を宣言する。.tlz は lzip と LZMA で曖昧なため出力には使わず、既存の読み取り動作を保つ。.tbr / .taz は明示した入力の別名として受理する。

新しい tar.lz / tar.lzma / tar.lz4 / tar.br / tar.Z は ArchiveRewriter で追加・削除・改名・置換する。
CompressedTarUpdater の splice は tar.gz / tar.bz2 / tar.xz に限る。新しい形式を updater に渡さない。
既存項目の表現可能性は ArchiveRewriter.probe(reader:format:) で確認し、設定の方式・レベル・所有者 ID・追加位置を編集にも渡す。
tar.zst はエンコーダーがないため読み取り専用を保つ。

## 利用者の決定

- ライセンス上採用できる形式・方式・レベルをできるだけ追加する。
- 単独ファイル圧縮は作成専用。選択元が通常ファイル 1 個の場合だけ表示し、フォルダ・symlink・パッケージを対象にしない。
- 複数の選択元には tar.X を使う。単独 stream を開いても編集を許可しない。
- 単独出力は元のファイル名と拡張子を残す（例: report.pdf.gz）。既定フォーマットとして記憶せず、次回は既定のアーカイブ形式へ戻す。
- ZIP の既定は Deflate。BZip2 / LZMA / XZ は macOS Archive Utility / ditto / /usr/bin/unzip で開けないため、方式選択時に短い互換性の注記を表示する。

## 残る候補

| 候補 | 保留理由・条件 |
|---|---|
| 7z solid と filters | エンコーダーと書き込み API がまだない。block 分割、メモリ上限、取消し、更新時の再圧縮を設計してから接続 |
| PPMd | 書き込み API がまだない。実装とライセンス確認、独立 decoder との往復検証が必要 |
| Zstandard（ZIP / tar.zst / 単独 .zst） | GyoshukuKit に encoder がない。レベル・framing・互換性を確認してから追加 |
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

形式・方式・全数値レベルの WriterOptions 対応、設定の保存・旧キーの移行、単独ファイルの表示条件、全形式の拡張子、作成・変換後の項目と本文、5 形式の編集、26 言語の翻訳をテストする。
GUI の実保存パネル検証は既存の KAITOFINDER_NATIVE_SAVE_REQUEST による opt-in を維持する。
通常の xcodebuild がサンドボックス制限で使えない場合も、兄弟パッケージを一時領域へビルドして Swift の型検査と実行可能な検証を行う。

2026-10-06 の確認結果:

- 隣接パッケージのビルド出力を一時領域へ置き、Swift 6 でアプリ全ソースの実行ファイルと全 XCTest ソースをコンパイル・リンクした。
- CompressionExpansionTests の追加 10 件は成功。12 形式の作成・変換、8 種の単独圧縮、ZIP・7z・LHA の各方式、5 種の圧縮 tar の編集後に、KaitoKit で項目と本文を照合した。
- 既存の関連テストは 134 件、失敗なし、既存条件によるスキップ 1 件。26 言語の文体と全翻訳・書式指定子の検査 27 件も成功。
- Info.plist の lint と git diff --check は成功。隣接リポジトリは変更していない。
- xcodebuild build-for-testing は SwiftPM manifest のサンドボックス適用で Operation not permitted となり実行できなかった。ネイティブ保存パネルの UI テストも XPC 接続の制限で起動できず、通常の macOS 実行環境での確認が残る。
