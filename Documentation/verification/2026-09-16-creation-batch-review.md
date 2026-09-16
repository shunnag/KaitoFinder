# 作成・別名で保存・一括展開・設定・パスワード保管の敵対的レビューと修正(Wave I)— 2026-09-16

## 方法

Wave H と同じ手順。Codex に読み取り専用で、新規作成(`ArchiveCreationController` /
`ArchiveCreationPlan` / `ArchiveCreationTransaction` / `ArchiveSavePanel`)、別名で保存・変換、
一括展開(`ArchiveBatchExtractor` / `ArchiveBatchExtractionController`)、設定、パスワード保管を
「操作の順序・失敗の順序・異常入力」の観点で読ませ、7 件(高 5・中 2)の候補を得た。
オーケストレータがコードで確認し(GyoshukuKit の `ArchiveRewriter.open` が URL を新規に読むこと、
`ArchiveCreationTransaction` が一時名で検証してから最終名へ rename することを含む)、
**修正前に失敗するテスト**を先に書いてから直した。

## 修正した項目

| # | 症状 | 原因 | 修正 | 回帰テスト |
|---|---|---|---|---|
| 6 | 印のないフォルダに入れた隔離属性付きダウンロードを固めると、生成アーカイブに印が付かず、再展開でも伝播しない(design §9 / §12-2 が塞いだはずの「固めて取り出す」迂回路) | 隔離属性の収集が選択した項目と元のアーカイブだけ | 取り込む全ファイルも調べ、最初に見つかった値を採用 | `testNestedFileQuarantinePropagatesFromAnUnquarantinedFolder`(修正前に失敗を確認) |
| 3 | 新規作成で保存先を作成元のファイル自身にすると、原本が「自分を格納したアーカイブ」で置換される | 同一ファイルの拒否が `existing` に対してだけ | 全 source との inode 同一性を列挙前に検査して拒否(hard link も) | `testCreationCannotReplaceAnySourceThroughItsPathOrHardLink`(同) |
| 4 | 別名で保存の保存パネル待ちの間に原本が別内容で差し替わっても検出せず、表示と違う内容を保存する | `Existing` が原本の同一性を持たない | `identity`(dev/ino/size/mtime)を持ち、rewriter を開く前に検査。既存文言「処理中にアーカイブが別の操作で変更されました。」 | `testSaveAsRefusesArchiveReplacedWhileChoosingDestination`(同) |
| 5 | tar.gz の保存名を `.gz` にすると、公開後に文書の切替が「対応していないフォーマット」で失敗(新規作成なら単体 gzip として開く) | 保存パネルの許可型が `.gzip` で名前を検証せず、作成は一時名で検証してから最終名へ rename | `acceptedExtensions(for:)` を保存パネルの検証と作成トランザクションの両方で要求 | `testSavePanelValidatesTarGzipFilenameExtensions` / `testTarGzipCreationRefusesPlainGzipDestinationBeforeImport`(同)/ `testAcceptedExtensionsMatchEachFormatIgnoringCase` |


一括展開の 3 件:

| # | 症状 | 原因 | 修正 | 回帰テスト |
|---|---|---|---|---|
| 7 | 記憶したパスワードが失効した後、再入力(記憶オフ)で展開できても旧値が残り、次回も最初から「パスワードが正しくありません」 | `.incorrect` のとき保管庫から消さない(文書経路にはある) | 自動投入した旧値だけを、入力を求める前に一度 `remove(for:matching:)` | `testIncorrectRememberedBatchPasswordIsRemovedBeforePromptAndReplacedOnlyWhenRequested` / `…InvalidatedOnlyOnce` |
| 2 | 展開中にそのパスが別のアーカイブで置換されると、展開していない新しい方をゴミ箱へ入れ得る | ゴミ箱への移動がパスだけ | `ArchiveSession.sourceIdentity` と照合し、違えばゴミ箱へ入れず理由を報告(展開自体は成功のまま) | `testTrashChecksArchiveIdentityAfterExtraction`(修正前に失敗を確認) |
| 1 | 取消しの回収が、展開後に差し替えられた親のシンボリックリンクを辿って展開先の外を消し得る(脅威モデル外の並行プロセス。最小限の対処) | `WrittenItem` が URL だけ | 書き込み時の dev/ino を記録し、`lstat` が一致するときだけ `unlink` / `rmdir` | `testCancellationPreservesFilesOutsideReplacedOutputParent`(同) |

## 除外した候補(既存テストで担保)

公開直前の取消し・公開フックの失敗・保存先が既存ディレクトリ(`ArchiveCreationTests`)、変換時の
パスワード不足・誤り(同)、別名で保存後の参照先・タイトル・最近使った項目・undo(`ArchiveSaveAsTests`)、
暗号化非対応形式への切替(`ArchivePasswordUITests`)、同名出力フォルダの連番・Services の混在入力
(`ArchiveBatchExtractionTests` / `ScenarioServicesTests`)、範囲外の設定値(`ArchivePreferencesTests`)、
「すべて忘れる」と進行中の入力の競合・保管庫の破損(`ArchivePasswordVaultTests` /
`ArchivePasswordPersistenceTests`)。

## 未確認のまま残した候補

複数ウインドウにまたがる認証の競合、保管庫の書き戻し中の強制終了・ディスク障害。

## 検証

全件 `xcodebuild test` 632 件・失敗 0・skip 1(QuickLook の前面化)。回帰テスト 10 件のうち
6 件は修正前に失敗することを確認した(残りは新しい注入 API に依存するため旧コードでは
コンパイルできない)。起動スモーク(Debug、fixture を引数に起動 → ウインドウ 1 → 正常終了)。
