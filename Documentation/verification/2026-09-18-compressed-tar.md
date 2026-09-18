# 圧縮 tar の追加検証（2026-09-18）

## 実装

- GyoshukuKit に `.tarBzip2` / `.tarXZ` と `WriterOptions.bzip2Level`（1〜9、既定9）を追加。
  tar のレコード出力を共通のストリーム圧縮器へ渡す。XZ は Apple Compression の固定設定、
  bzip2 は macOS の libbz2 を使い、外部プロセスは製品に組み込まない。
- 読み書きのバッファは256 KiB。通常の tar と同じリンク・時刻・所有者の扱い、
  原本の変更検知、取り消し、途中出力の削除、公開境界を維持する。
- KaitoFinder の作成・形式変換・編集、保存形式、設定の既定形式に両形式を追加。
  gzip と bzip2 のレベルは別々に保存する。XZ のレベルは固定と表示する。
  `tar.bz2` / `tbz` / `tbz2`、`tar.xz` / `txz` を受理する。
- 追加した設定のラベルと説明は26言語に反映。
  旧テストで「未対応の圧縮 tar」としていた bzip2 fixture は、必要な箇所だけ LZMA_Alone に変更した。

## 通過した検証

macOS 27.2 / Apple Silicon / Xcode 27.0。macOS 26 と Intel は今回実行していない。

- `GYOSHUKU_LARGE_TAR_TESTS=1 swift test`: **202件、失敗0、skip0**（524.715秒）。
  BSD tar、Python、xz/bzip2、7zz で全レコード・全バイトを照合。
  空書庫、端数、長いUTF-8名、1/3/37 byte入力、大きな最終入力、bzip2全レベル、
  キャンセル、無効なパス、原本の変更、原子的な書き換えも含む。
- **4 GiB + 513 byte** の実ファイルを両形式で作成。
  Pythonの全バイト比較、bsdtar一覧、7zz検査、KaitoKitの逐次読み出しが一致。
  SHA-256: `763f370bb3466c282fe66ec8c245f1e830dc105c0677dfbc881824467ef3ec9c`。
  読取側の既定4 GiB上限は変更せず、この大容量テストだけ明示的に上限を上げた。
- KaitoKit: **1,168件、失敗0、既知skip43**。別スイートの互換性検証 **24件も失敗0**。
  Swap追加後の再実行では **1,176件、失敗0、既知skip43**、互換層 **24件、失敗0**。
  GyoshukuKitも **202件、失敗0、skip0**を再確認した（523.278秒）。
- KaitoFinder の作成・編集・設定・ディスク容量・型宣言の選択検証:
  **169件、失敗0、skip0**（119.145秒）。
  容量8 MiBのAPFSテストボリュームへ圧縮しにくい16 MiBの入力を追加して失敗させ、
  原本のSHA、世代、undo、残存作業ファイルを照合した。
  別途、26言語×ライト／ダークの `LayoutOverflowTests` が通過している。
  設定・保存アクセサリの描画と操作3テストも再実行し、失敗0。
  16枚の日本語・英語画像を `build/CompressedTarSwapVerification/screenshots` に保存した。
  これはビューの描画検証であり、標準保存ボタンの実操作とは区別する。

## メモリ測定

`python3 Tools/benchmark_tar_memory.py` は製品の TarWriter と圧縮器を `swiftc -O` でビルドし、
各測定を別プロセスで実行する。入力は逐次生成し、Python と7zzで出力を検証する。
16 / 64 / 256 MiB の反復データと固定シードの擬似乱数で測定した。
ドライバーの入力生成・SHA計算も所要時間に含む。

| 形式・入力 | 入力 MiB | ピーク RSS MiB | 書庫 byte | 秒 |
|---|---:|---:|---:|---:|
| XZ・反復 | 256 | 84.75 | 39,240 | 2.21 |
| XZ・擬似乱数 | 16 | 101.13 | 16,779,348 | 3.17 |
| XZ・擬似乱数 | 64 | 101.14 | 67,113,060 | 14.21 |
| XZ・擬似乱数 | 256 | 101.20 | 268,449,616 | 58.84 |
| bzip2・反復 | 256 | 14.28 | 302 | 1.41 |
| bzip2・擬似乱数 | 16 | 14.80 | 14,875,669 | 0.91 |
| bzip2・擬似乱数 | 64 | 14.53 | 59,505,842 | 3.65 |
| bzip2・擬似乱数 | 256 | 14.53 | 238,021,492 | 14.56 |

ソースのSHA-256は測定ログに記録する。`--max-rss-mib 128` で上限を検査できる。

## 保存パネルで検出した問題と後続検証

非表示パネルのテストだけでは、表示中のXPC保存パネルの名前を保証できなかった。
`nameFieldStringValue`はconfiguration phaseに限られ、表示後の変更は拒否される。
また、`allowedContentTypes`の差し替えだけでは複合拡張子が重複した。

08:12以降はOSのロックで確定操作を中断した。18:38 JSTの解除後に再開し、
固定の型一覧と公開の`currentContentType`、設定時の候補名、手入力時の短縮拡張子を組み合わせて修正した。
実際の保存50回・上書き確認10回、全7形式の切り替え、名前の再編集が成功している。
保存先URLと確認対象を照合するネイティブ操作テストをUIドライバーへ追加した。
最終の仕様・制約と横断検証は[保存パネルの検証記録](2026-09-18-native-save-panel.md)を参照。

記録先:

- `/private/tmp/kaitofinder-compressed-tar-gyoshuku-full.log`
- `/private/tmp/kaitofinder-compressed-tar-kaitokit-full.log`
- `/private/tmp/kaitofinder-compressed-tar-core-finder.log`
- `/private/tmp/kaitofinder-compressed-tar-memory.log`

圧縮器は [Apple Compression](https://developer.apple.com/documentation/compression) と
[bzip2 の公開API文書](https://sourceware.org/bzip2/manual/manual.html)に基づく。
第三者のcodec実装ソースは参照していない。
