# 実運用シーンのテスト拡充

仕様 `kf-scenarios.md` を全文確認し、10テーマ・28テストを追加した。入力はテスト内でPythonのzipfile/tarfile、7zz、GyoshukuKitのLHA writerから生成する。tarの検査にはbsdtarも使う。

## 検証結果と範囲

- KaitoFinderの全Swiftソースと全テストソースを、一時領域の出力先でコンパイル・リンクできた。既存のローカルKaitoKit/GyoshukuKitビルド成果物を参照した補助検証であり、Xcodeのテスト実行とは別である。
- 新規シーンテストのうち14件が補助XCTest runnerで成功。ディスク3件はhdiutilの失敗で`XCTSkip`。UIを使う11件はコンパイル済み・実行未確認。
- 既存`WordingAcceptanceTests`の10言語のStyleテスト、カタログ完全性、件数表記/省略記号の計12件が成功。カタログ222キーの10言語と書式指定子の一致も確認した。
- 修正前のHEADを`git show`で一時領域へ読み出してビルドし、下記8条件の実行probeがすべて失敗することを確認した。同じprobeは修正後すべて成功した。
- 通常の指定コマンドはsandboxの書き込み拒否により**終了コード74**。テストは開始されていない。別途試したUI runnerも`NSApplication`の初期化を含む起動段階でSIGABRTとなったため、UI操作の成功は主張しない。
- 補助runnerの初回はリソースの配置先がdylibのBundleと異なり、言語Bundleの取得に失敗した。`xcstringstool`の出力を実際のBundleに配置後、該当2テストと既存の言語規則12テストが成功した。

1万件のテストは10,000ファイル・300フォルダ・合計140,000バイトを確認する。open+treeは4秒、filterは400msを上限とし、`CI`環境変数がある場合は時間のアサーションを省く。件数、内容、選択、抽出の検証はCIでも実行する。ファイル名は255バイトを有効な上限として受理し、256バイトを拒否する。

## 不具合と修正前の失敗アサーション

以下の「修正前」は補助probeでの実測値。アサーション欄には対応する新規XCTestの条件を示す。UIを必要とする文書操作全体、メニュー、undoの検証状況は上記の範囲に従う。

| 項目 | 失敗するアサーション | 修正前の実測 | 修正 |
| --- | --- | --- | --- |
| 選択件数の桁区切り | `XCTAssertTrue(text.contains(number))` (`ScenarioScaleTests.testStatusBarGroupsTotalFilteredAndSelectedCountsInEnglishJapaneseAndGerman`) | 選択数が`10000項目を選択中(...)` | 件数のformat処理にLocaleを渡す。en/jaの`10,000`、deの`10.000`を総数・絞り込み・選択数で検証。総数は修正前から桁区切りがあった。 |
| 空ZIPの不要な出力フォルダ | `XCTAssertTrue(contentsOfDirectory(out).isEmpty)` (`ScenarioShapeTests.testEmptyZIPOpensExtractsNothingAndBatchCreatesNoFolder`) | `.always`で`["empty"]`を作成 | トップレベル項目が空ならラッパーフォルダを計画しない。 |
| 長いパスの誤った診断 | `XCTAssertEqual(result.failures.first?.reason, ExtractionFailure.system(ENAMETOOLONG).description)` (`ScenarioPathTests.testPathMaxAndOutsideSymlinkAreReportedPerEntryWithoutEscaping`) | `出力先の外へ解決されるパスです。` | NAME_MAX/PATH_MAXを親作成・包含検査の前に検査し、`POSIX 63: File name too long`を項目単位で返す。 |
| 名前が同じ原本への外部置換を見逃す | 成功経路の`XCTFail("差し替え前の内容に対する編集を公開しました")` (`ScenarioExternalChangeTests.testReplacementWithIdenticalNamesRefusesEveryEditAndPreservesUndo`) | 置換後の原本に新規フォルダを公開した | セッション開始時のdevice/inode/size/mode/mtimeを保持。操作開始時とtransactionの開始時に照合し、`.archiveChanged`で拒否する。既存の公開直前の照合も維持する。LaunchServicesのlastuseddate拡張属性やFinderタグの変更では内容が変わらずctimeだけが更新されるため、ctimeは除外する。 |
| 削除した原本から旧inodeの内容を抽出する | 成功経路の`XCTFail("削除された原本への操作を受理しました")` (`ScenarioExternalChangeTests.testDeletedSourceRefusesExtractionAndEditAndWindowCanReload`) | 削除後も旧readerから抽出した | reader取得時に原本を確認し、`アーカイブの原本を確認できません。`を返す。表示用一覧を保持して再読み込みを可能にする。 |
| 再読み込みで形式が古いまま | `XCTAssertEqual(session.format, .sevenZip)` / `XCTAssertEqual(session.capabilities.refusal, .encrypted)` (`ScenarioExternalChangeTests.testReloadOfEncryptedReplacementUpdatesFormatAndReadOnlyCapability`) | ZIP→暗号化7zの置換後も`.zip`。拒否理由は`unavailable("invalidArchive(\"EOCD がありません\")")` | 新しいreaderの形式でcapabilityを再検査し、公開する形式も更新する。 |
| 一時コピーの出自を説明できない | `XCTAssertEqual(session.capabilities.readOnlyReason, reason)` (`ScenarioNestedTests.testOpenInnerArchiveShowsTemporaryCopyRefusalAndOuterCloseRemovesIt`) | 一般的な書き込み権限の拒否理由 | materializeしたコピーに出自のxattrを付け、`.temporaryCopy`と専用理由を表示。既存の0400属性を維持し、属性変更後も専用理由で拒否する。対応する入れ子のアーカイブはNSDocumentControllerで開く。 |
| Servicesの不正入力の診断 | `XCTAssertEqual(result.failures.first?.reason, String(localized: "対応していないフォーマットです。"))` (`ScenarioServicesTests.testExtractServiceReportsNonArchivePerItemAndContinues`) | `Unsupported archive format` | バッチ入口で未対応形式を10言語の理由に変換する。フォルダもバッチに渡し、項目単位で同じ理由を報告する。 |

Servicesのフォルダ除外はソースでも確認した。修正前の`archivesToExtract`はフォルダを除外していたため、`ScenarioServicesTests.testExtractServiceReportsFolderPerItemAndContinues`の`XCTAssertEqual(received, [invalid, fixture.archive])`が満たされない。修正後は入力順を保ったままバッチへ渡す。このServices呼び出し全体はUI環境での実行待ち。

## Expected failures・スキップ

- **`XCTExpectFailure`の追加なし。** 実行できたシーンからKaitoKit/GyoshukuKitの不具合は確認されなかった。両リポジトリは読み取り専用で扱った。
- tarとLHAの初回テストには「既存項目が先頭のまま」という誤った前提があった。rewriterは追加項目を先に書くため、名前と種類・内容・元の名前バイト列の対応を確認するアサーションへ修正し、成功を確認した。
- ディスク3件はすべて`hdiutil create -size 8m -fs APFS -volname KFTest`が終了コード1、`create failed - 装置が構成されていません`でスキップされた。マウント可能な環境での容量不足・readonlyの実動作は未確認。attachには`-nobrowse`、readonlyには`-readonly`を指定し、teardownは`hdiutil detach -force`を呼ぶ。

## 変更ファイル

### 製品コード

- `KaitoFinder/App/AppDelegate.swift` — フォルダを含むServices入力の維持、テスト用バッチ実行境界。
- `KaitoFinder/Extraction/ArchiveBatchExtraction.swift` — 空の出力計画、フォルダ・未対応形式の診断。
- `KaitoFinder/Extraction/EntryMaterializer.swift` — 一時コピーを識別するxattr。
- `KaitoFinder/Extraction/ExtractionDestination.swift` — 名前/パス長の事前診断、一時コピーの属性設定。
- `KaitoFinder/Import/ArchiveImportTransaction.swift` — 原本identityの共有と開始時の照合、変更済み原本のエラー。
- `KaitoFinder/Model/ArchiveCapabilities.swift` — `.temporaryCopy`。
- `KaitoFinder/Model/ArchiveSession.swift` — 開いた原本のidentityの保持と照合、再読み込み時の形式更新。
- `KaitoFinder/UI/ArchiveWindowController.swift` — Localeによる件数表示、入れ子の文書オープン、変更済み原本の理由、書き込みフックと状態照会。
- `KaitoFinder/Resources/Localizable.xcstrings` — `一時的なコピーのため変更できません。`、`対応していないフォーマットです。`をja/en/de/fr/es/it/pt-BR/zh-Hans/zh-Hant/koで追加。

### 既存テスト・共通fixture

- `KaitoFinderTests/ArchiveTestDirectory.swift` — 共通fixture、内容/digest検査、文書の後始末、書き込みを止める同期ゲート。
- `KaitoFinderTests/ArchiveBatchExtractionTests.swift` — 空の出力計画の期待値更新。
- `KaitoFinderTests/ArchiveBatchExtractionUITests.swift` — Servicesがフォルダをバッチへ渡す期待値更新。
- `KaitoFinderTests/ArchiveEditTests.swift` — 外部置換の診断を`.archiveChanged`へ更新。
- `KaitoFinderTests/ArchiveRewriteTests.swift` — 暗号化した外部置換の開始時拒否を検証。
- `KaitoFinderTests/ArchiveUndoStackTests.swift` — 初期のpermission/quarantineの準備を文書オープン前に移動。
- 本報告書 `Documentation/verification/2026-09-15-scenarios.md`。

`project.pbxproj`はHEADとbyte-identical。新規テストは既存の同期フォルダから取り込まれる。checkout/stash/reset/commitは実行していない。追加したコードコメントは日本語。

## 新規テスト一覧

### A. Scale — [ScenarioScaleTests.swift](../../KaitoFinderTests/ScenarioScaleTests.swift)

- `testTenThousandEntriesOpenFilterSelectAllAndExtractExactBytes` — 成功
- `testStatusBarGroupsTotalFilteredAndSelectedCountsInEnglishJapaneseAndGerman` — 成功

### B. Names — [ScenarioNameTests.swift](../../KaitoFinderTests/ScenarioNameTests.swift)

- `testJapaneseNFCAndNFDShareOneFolderAndFirstOutputWins` — 成功
- `testCaseInsensitiveDiskRefusesSecondSpellingAndPreservesFirst` — 成功
- `testNameMaxBoundaryUnicodeSpacesReservedNamesAndTraversalAreIsolated` — 成功

### C. Depth and paths — [ScenarioPathTests.swift](../../KaitoFinderTests/ScenarioPathTests.swift)

- `testTwoHundredLevelsExtractWithExactLeafContents` — 成功
- `testPathMaxAndOutsideSymlinkAreReportedPerEntryWithoutEscaping` — 成功

### D. Disk conditions — [ScenarioDiskTests.swift](../../KaitoFinderTests/ScenarioDiskTests.swift)

- `testFullDiskExtractionReportsNoSpaceAndRemovesPartialPayload` — hdiutilによるスキップ
- `testFullArchiveVolumeRefusesAppendWithoutPublishOrUndo` — hdiutilによるスキップ
- `testReadOnlyVolumeRefusesEditingWithPermissionReasonAndBatchReportsEachArchive` — hdiutilによるスキップ

### E. External changes — [ScenarioExternalChangeTests.swift](../../KaitoFinderTests/ScenarioExternalChangeTests.swift)

- `testReplacementWithIdenticalNamesRefusesEveryEditAndPreservesUndo` — コンパイル済み・UI実行未確認
- `testDeletedSourceRefusesExtractionAndEditAndWindowCanReload` — コンパイル済み・UI実行未確認
- `testReloadOfEncryptedReplacementUpdatesFormatAndReadOnlyCapability` — コンパイル済み・UI実行未確認

### F. Concurrency — [ScenarioConcurrencyTests.swift](../../KaitoFinderTests/ScenarioConcurrencyTests.swift)

- `testSlowExtractionDisablesPasteNewFolderAndDeleteUntilCompletion` — コンパイル済み・UI実行未確認
- `testOpeningSameArchiveTwiceReturnsOneDocument` — コンパイル済み・UI実行未確認
- `testDifferentDocumentsActuallyWriteConcurrently` — コンパイル済み・UI実行未確認

### G. Nested archives — [ScenarioNestedTests.swift](../../KaitoFinderTests/ScenarioNestedTests.swift)

- `testOpenInnerArchiveShowsTemporaryCopyRefusalAndOuterCloseRemovesIt` — コンパイル済み・UI実行未確認
- `testTemporaryCopyNoticeHasAllTenTranslations` — 成功

### H. Shapes — [ScenarioShapeTests.swift](../../KaitoFinderTests/ScenarioShapeTests.swift)

- `testEmptyZIPOpensExtractsNothingAndBatchCreatesNoFolder` — コンパイル済み・UI実行未確認
- `testDirectoriesOnlyArchiveCreatesEveryDirectoryWithoutFiles` — 成功
- `testSingleFileArchiveExtractsUnderEveryFolderPolicy` — 成功
- `testTarHardLinkAndSymlinkSurviveRewriteAppend` — 成功
- `testSolidSevenZipRewriteAppendKeepsEveryEntryAndByte` — 成功
- `testCP932LHANameAndContentsSurviveRewriteAppend` — 成功

### I. Batch mix — [ScenarioBatchTests.swift](../../KaitoFinderTests/ScenarioBatchTests.swift)

- `testThirtyMixedArchivesPreserveOrderIsolateFailuresAndTrashOnlySuccesses` — 成功

### J. Services inputs — [ScenarioServicesTests.swift](../../KaitoFinderTests/ScenarioServicesTests.swift)

- `testCompressEmptyPasteboardReturnsSelectionError` — コンパイル済み・UI実行未確認
- `testExtractServiceReportsNonArchivePerItemAndContinues` — コンパイル済み・UI実行未確認
- `testExtractServiceReportsFolderPerItemAndContinues` — コンパイル済み・UI実行未確認


## 補助probeの修正前後

### 修正前

```text
FAIL selectedStatus.contains(10,000) | actual: 10000項目を選択中(Zero KB)
FAIL emptyZIP.outputNames.isEmpty | actual: ["empty"]
FAIL longPath.reason == ENAMETOOLONG | actual: 出力先の外へ解決されるパスです。
FAIL replacedArchive.nextEditIsRefused | actual: published
FAIL deletedArchive.extractionIsRefused | actual: extracted old inode
FAIL nestedArchive.reason == temporaryCopy | actual: このアーカイブは変更できません。アーカイブまたは親フォルダへの書き込み権限がありません。
FAIL reloadedArchive.format == sevenZip && refusal == encrypted | actual: zip, Optional(KaitoFinder.ArchiveCapabilities.Refusal.unavailable("invalidArchive(\"EOCD がありません\")"))
FAIL nonArchive.reason == unsupportedFormatLocalized | actual: Unsupported archive format
```

### 修正後

```text
PASS selectedStatus.contains(10,000) | actual: 10,000項目を選択中(Zero KB)
PASS emptyZIP.outputNames.isEmpty | actual: []
PASS longPath.reason == ENAMETOOLONG | actual: POSIX 63: File name too long
PASS replacedArchive.nextEditIsRefused | actual: アーカイブが変更されています。開き直してください。
PASS deletedArchive.extractionIsRefused | actual: アーカイブの原本を確認できません。
PASS nestedArchive.reason == temporaryCopy | actual: 一時的なコピーのため変更できません。
PASS reloadedArchive.format == sevenZip && refusal == encrypted | actual: sevenZip, Optional(KaitoFinder.ArchiveCapabilities.Refusal.encrypted)
PASS nonArchive.reason == unsupportedFormatLocalized | actual: 対応していないフォーマットです。
```

補助コンパイルと実行ログは `/private/tmp/kf-scenarios-validation/` にある。`before/probe.log`、`after/probe.log`、`all-tests-build.log`、`scenario-runner.log`、`localization-runner.log`、`batch-runner.log`を参照。

## 指定コマンドの検証末尾

```sh
cd /Users/nagash/Github/KaitoFinder && xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS' test 2>&1 | tail -15
```

`pipefail`を有効にしてxcodebuildの終了コードを取得した。終了コード: **74**。sandboxがSwiftPM/Clangのキャッシュ書き込みを拒否した。

```text

Package: unknown

2026-09-15 14:13:46.939 xcodebuild[1616:10685325] Writing error result bundle to /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/ResultBundle_2026-15-09_14-13-0046.xcresult
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/gyoshukukit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
```
