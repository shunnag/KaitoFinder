# 一括展開の実装と検証 — 2026-09-15

複数のアーカイブを文書ウインドウなしで展開する。ファイル›「アーカイブを展開…」と
Finderのサービス「KaitoFinderで展開」は、共通の`ArchiveBatchExtractor.run`へ接続する。
展開先・フォルダ作成・ゴミ箱移動は既存の`ArchivePreferences`を使う。

## 変更ファイル

| ファイル | 変更 |
|---|---|
| [KaitoFinder/Extraction/ArchiveBatchExtraction.swift](../../KaitoFinder/Extraction/ArchiveBatchExtraction.swift) | 展開先の決定、逐次展開、失敗の分離、取消し時の出力回収、任意のゴミ箱移動。 |
| [KaitoFinder/UI/ArchiveBatchExtractionController.swift](../../KaitoFinder/UI/ArchiveBatchExtractionController.swift) | アーカイブ選択、全体で一度の展開先選択、単独の進捗、名前付きのパスワード入力、最終アラート。 |
| [KaitoFinder/UI/ArchivePasswordPrompt.swift](../../KaitoFinder/UI/ArchivePasswordPrompt.swift) | 既存の入力アラートと入力待ちの管理を共有するヘルパー。 |
| [KaitoFinder/App/AppDelegate.swift](../../KaitoFinder/App/AppDelegate.swift) | ファイルメニュー、Finderサービス、重複起動の防止。 |
| [KaitoFinder/Creation/ArchiveCreationPlan.swift](../../KaitoFinder/Creation/ArchiveCreationPlan.swift) | 形式変換と展開で共有するarchiveStem(for:)。 |
| [KaitoFinder/Model/ArchiveEntryPayload.swift](../../KaitoFinder/Model/ArchiveEntryPayload.swift) | トップレベルのノードからのペイロード作成を共有。 |
| [KaitoFinder/UI/ArchiveWindowController.swift](../../KaitoFinder/UI/ArchiveWindowController.swift) | 共通のパスワード提示とペイロード作成を使用。 |
| [KaitoFinder/Info.plist](../../KaitoFinder/Info.plist) | 展開サービスを追加。対象は文書宣言の18個のUTI。 |
| [KaitoFinder/Resources/Localizable.xcstrings](../../KaitoFinder/Resources/Localizable.xcstrings) | 新規8文字列の英語・日本語。 |
| [KaitoFinder/Resources/en.lproj/ServicesMenu.strings](../../KaitoFinder/Resources/en.lproj/ServicesMenu.strings) | Extract with KaitoFinder。 |
| [KaitoFinder/Resources/ja.lproj/ServicesMenu.strings](../../KaitoFinder/Resources/ja.lproj/ServicesMenu.strings) | KaitoFinderで展開。 |
| [KaitoFinderTests/ArchiveBatchExtractionTests.swift](../../KaitoFinderTests/ArchiveBatchExtractionTests.swift) | エンジンの受け入れ・回帰テスト18件。 |
| [KaitoFinderTests/ArchiveBatchExtractionUITests.swift](../../KaitoFinderTests/ArchiveBatchExtractionUITests.swift) | 入口・UI・文言のテスト8件。 |
| [KaitoFinderTests/WordingAcceptanceTests.swift](../../KaitoFinderTests/WordingAcceptanceTests.swift) | Servicesの英語・日本語辞書に展開項目を追加。 |
| [Documentation/design.md](../../Documentation/design.md) | §5に一括展開の設計を追加。 |
| [Documentation/manual-verification.md](../../Documentation/manual-verification.md) | §6に一括展開の実機確認手順を追加。§7の設定の説明を更新。 |
| [Documentation/verification/2026-09-15-batch-extraction.md](../../Documentation/verification/2026-09-15-batch-extraction.md) | 変更ファイル、全テスト名、検証結果、仕様との差分。 |

## テスト名

26件を追加した。受け入れ条件1〜7はエンジンのテスト、8はUIの入口・宣言のテスト、
9の文言は既存の辞書検証と新規の表示検証でカバーする。既存テストを含め、型チェックは成功した。
指定のxcodebuildはテスト開始前に停止したため、実行による合格は確認できていない。
7zのfixtureには`/opt/homebrew/bin/7zz`を使い、不在なら既存の`ArchiveTestDirectory`の規則でスキップする。

### ArchiveBatchExtractionTests

- `testDestinationFolderPoliciesForSingleAndMultipleTopLevelNames`
- `testDestinationFolderUsesFinderSuffixesAndPreservesExistingFolders`
- `testArchiveStemStripsArchiveAndCompoundExtensionsAndKeepsPhotoExtension`
- `testMixedZIPAndTarGzipBatchUsesEachArchiveFolderAndTopLevelShape`
- `testChosenBaseAlwaysCreatesUniqueFolderAndNeverUsesSourceFolder`
- `testNeverCreatesWrapperEvenWithMultipleTopLevelFiles`
- `testEncryptedZIPPromptsForItsURLAndExtractsExactBytes`
- `testEncryptedZIPWrongThenRightPasswordRetriesTwice`
- `testPasswordPromptCancellationSkipsOnlyThatArchiveAndRemovesEmptyFolder`
- `testRememberedPasswordExtractsWithoutPrompting`
- `testIncorrectRememberedPasswordFallsBackToPrompt`
  - 注: KaitoKit の ZipCrypto の分類に依存し、ヘッダーチェックを誤ったパスワードが 1/256 の確率で通過していた。KaitoKit に `fix/zipcrypto-wrong-password` の変更を取り込むと、このテストの結果は決定的になる。
- `testEncryptedSevenZipHeadersRetryAtOpenAndRememberedPasswordWorks`
- `testCorruptHeaderAndPayloadFailuresAreIsolatedAndEmptyFolderIsRemoved`
- `testTrashRunsOnceForEachSuccessfulArchiveAndNeverForFailures`
- `testTrashFailureIsReportedButExtractionAndFollowingArchiveAreKept`
- `testCancelProgressFromSecondPasswordPromptStopsBatchWithoutPartialOutput`
- `testCancellationDuringWritingRemovesOnlyCurrentArchiveOutput`
- `testEmptyBatchAndPrecancelledProgressDoNotPromptOrTrash`

### ArchiveBatchExtractionUITests

- `testFinderExtractionServiceSelectorAndDeclaredArchiveTypesMatchDocuments`
- `testFileMenuExtractionImmediatelyFollowsNewArchiveInBothLanguages`
- `testOpenPanelsSelectMultipleDeclaredArchivesAndOneDestinationFolder`
- `testFinderExtractionReadsOnlyFileURLsFromPasteboard`
- `testSecondBatchServiceRequestIsRejectedAndMenuIsIgnoredWhileChoosingDestination`
- `testBatchPasswordSheetUsesStandaloneProgressWindowAndRemembersSuccessfulPassword`
- `testProgressCancellationDismissesPendingBatchPasswordSheet`
- `testBatchAlertsProgressAndPasswordNamesAreLocalizedWithCorrectPunctuation`

### 更新した既存テスト

- `WordingAcceptanceTests.testCatalogKeysFollowWordingRulesAndHaveEnglishAndJapanese`

## 検証

- アプリ本体のSwiftモジュール生成・型チェック: 終了コード0。
- 既存分を含む全テストソースの型チェック: 終了コード0。
- 上記はSwift 6.4、Swift言語モード6、macOS 26ターゲット、既定のMainActor分離と
  `NonisolatedNonsendingByDefault`で実施。既存ビルドの依存モジュールを読み、生成物と
  モジュールキャッシュは`/private/tmp/kf-batch-typecheck`へ置いた。リンクやXCTest実行の代わりにはならない。
- `Progress`の子の集計・取消し伝播の単独確認: 完了一件で`1 / 3`、次の子の5件目で取消しを伝播した。
- `Info.plist`と両言語の`ServicesMenu.strings`の`plutil -lint`: すべてOK。
- サービスの対象UTIと文書宣言の和集合の一致、全辞書の英語・日本語、文言規則: 成功。
- `git diff --check`: 成功。
- Finderでの実操作は未実施。手順は[実機確認§6](../manual-verification.md)に記載した。

### 指定コマンド

パイプの左側の終了コードを保持するため、シェルの`pipefail`を有効にして実行した。

```sh
set -o pipefail
cd /Users/nagash/Github/KaitoFinder && xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS' test 2>&1 | tail -15
```

**終了コード74。** サンドボックスがClangとSwiftPMのキャッシュへの書き込みを拒否し、
パッケージ解決で停止した。ビルドとテストの実行には到達していない。

末尾15行:

```text

Package: unknown

2026-09-15 10:25:20.324 xcodebuild[36755:10172806] Writing error result bundle to /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/ResultBundle_2026-15-09_10-25-0020.xcresult
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/gyoshukukit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/gyoshukukit.dia' for diagnostics emission (Operation not permitted)

```

## 仕様との差分と制約

外部動作と指定APIは仕様どおりに実装した。仕様には、展開サービスが取消し時に処理中の
アーカイブの部分出力を回収するという前提があった。現行サービスが削除するのは書きかけの葉だけなので、
一括エンジンで今回書き込んだURLを回収する処理を補った。完了済みアーカイブや既存ファイルは残し、
フォルダは空の場合だけ削除する。回収に失敗した場合も理由を報告する。

`GyoshukuKit`、`KaitoKit`、`project.pbxproj`は編集していない。
`git checkout`、`stash`、`reset`、`commit`は実行していない。
