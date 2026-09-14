# 検証: 新規書庫の作成と変換(M6)— KaitoFinder `1491bce`

Codex に仕様(⌘N / Finder サービス / 読み取り専用書庫の変換、一つの
`ArchiveCreationTransaction`)を渡し、差分を全部読み、自分のシェルで
`xcodebuild test` を回し、守りの分岐を注入で確かめた。

## 結果

- `xcodebuild test`: **336 件 0 失敗**(新規 36 件: engine 25、UI 10、drop 1)。
- 一回目の Codex 結果で直した点は一つ。**実測**: システムの
  `org.gnu.gnu-zip-tar-archive` の拡張子タグは `["tgz"]` だけで、
  `UTType(filenameExtension: "tar.gz")` は nil。保存パネルをこの UTI に限定すると
  `Docs.tar.gz` が `Docs.tar.gz.tgz` になる。tar.gz は `.gzip`(末尾 gz)で受ける。
  パネルの実挙動は実機でしか見えないので `manual-verification.md` §6 に期待を置いた。

## 注入で確かめた守り(累積で入れたが、それぞれ新しい失敗が出た)

| 注入 | 新たに落ちたテスト |
|---|---|
| 出力への quarantine 適用を外す | `testFirstQuarantinedSourceValueIsPropagatedExactly`、`testConversionPropagatesTheOriginalArchiveQuarantine` |
| 保存先 = 原本(path / symlink / hard link)の拒否を外す | `testConversionCannotReplaceOriginalThroughItsPathOrFileAliases` |
| 誤パスワードを「必要」に潰す | `testWrongConversionPasswordThrowsIncorrectAndPublishesNothing` |

## 判断

- 変換は原本を触らない(`ArchiveRewriter` の `output` 指定)。保存先が原本の別名でも拒否。
- 暗号化 entry のある書庫の変換は、保存パネルの前に `preparedPassword()` で全 entry を
  検証する(fail-closed:途中で鍵が違うと分かって部分出力が残ることがない)。確認
  ダイアログで「新しい書庫は暗号化されません」を言う。
- drop のハイライトは「操作の入口」を示すものとし、読み取り専用書庫にも出す
  (設計書 §4.3 を改訂)。通知欄が理由を、ドロップ後の確認が逃げ道を言う。
- サービスは `NSRequiredContext` で Finder に限定。Finder 以外のアプリの
  サービスメニューには出さない。
