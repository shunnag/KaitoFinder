# S13 / P2-A: 非圧縮 tar の更新と編集設定

2026-09-26。KaitoFinder `feature/2026-09-24-review`、基底 `e49ecf5a2d7615952358b89c41609440878959fe`。
P2.md の P2-A、ORDER-P2-P3.md §1–§2、および ORDER-P4-P5.md §1.2 を実装した。
コミットは行っていない。Codex 自身は通常ビルド・GUI・全件試験・性能の受入判定を実施していない。
オーケストレータの全件実行の報告と、その後の修正は correction 1 の節に記録する。

## 実装と公開境界

- 分割名を持たない単一の非圧縮 tar は `.update(.tar)`。大文字拡張子・内容から判定した拡張子なしも対象。
  `ArchiveRewriter.probe` の表現可能性検査は残し、分割 tar と圧縮 tar は `.rewrite` のまま。
  `.tar.001` のように `ArchiveVolumeSet.parse(fileName:)` が成功する名前は、兄弟巻がなくても `.rewrite(.tar)`。
- `Mode.outputFormat` と `resolved(with:)` を共有し、編集ごとに設定を解決する。
  追加の先頭指定、または tar の既存項目の所有者を reset する指定は、updater を開かず rewrite へ進む。
  ZIP は常に末尾。7z / LHA には追加位置だけを渡す。
- `publish` は TarUpdater の **open だけ**で `requiresRewrite` を捕まえる。
  `rewriteBranch(format:)` は `willOpenUpdater` を呼ばず、通常の `.rewrite` case と `.update` case が各々一度呼ぶ。
  fallback 後にも変更処理は一度だけ。mutate / commit の `requiresRewrite` は fallback しない。
  fallback 先で `lstat(work) == ENOENT` を確認する。
- 作業ディレクトリは commit 後に `archive.tar` 一つだけ。原本・兄弟巻の同一性、取消し、undo の退避、
  公開前の検証、rename の公開境界、検証 reader の採用を維持する。
  TarUpdater の commit は P1b の比率による 1000 単位の進捗を使い、totalBytes が 0 でも完了する。
  自己照合失敗は検証診断を記録して `ArchivePublicationError.verificationFailed` に写し、編集可否を取り上げない。
- `ArchiveOutputProjection` は入力を保持し、fallback 時に `resolving(.rewrite(...))` で期待を作り直す。
  tar 4形式の `.update` では格納順、種類、既知のサイズ、hard link の直接の参照先の最終名を照合する。
  削除された実体の最初の生存 link だけを実体化し、その後の link は holder へ付け替える。
  既存の root・directory・symlink のサイズを updater 用の期待から消さない。
- replay は日時・owner IDs 付きの `ArchiveEditing` API を使う。追加ファイルには元の sourceStamp の ID、
  directory / 作成フォルダには 0/0 と予約日時を渡す（所有者保存が無効なら nil）。
  `ArchiveDeferredTarWriter`、`ownerRestoration` stage、一時 directory 経由の追加を削除した。
  単一保存、分割の書き直し、別名保存に同じ replay を使う。

## 設定と言語

`ArchiveAdditionPlacement` は `end`、`ArchiveTarCarriedOwnerIDs` は `keep` が既定。
不明な保存値もこの既定へ戻る。既存の `ArchiveTarPreservesOwnerIDs` の値・既定は変えていない。
設定画面の popup 二つ、追加ファイル用の checkbox 文言、コロンなしの accessibility label を実装した。
開いている文書でも、通知で更新された snapshot を次の編集から読む。

§A1 の新規10キーに26言語、合計260訳を追加した。すべて `translated`、日本語の値はキーと同じ。
既存キーの訳は変更していない。旧キー `所有者ID(uid / gid)を保存` は catalog と製品コードから削除し、
試験には「存在しない」という assertion だけを残した。

P2-A の `rewriteNotice` は構造に基づくまま。分割名を持たない単一の非圧縮 tar では nil であり、
従来設定による全体書き直しは popup の文言で伝える。「再圧縮します」とは表示しない。
設定に応じた `editNotice(options:onSave:)` は P3-A の範囲である。

## 依存と実行方法

並行編集中の `../KaitoKit` の作業ツリーはビルドに使っていない。
以下の commit を `git archive` し、`build/P2AS13Verification/dependencies/{KaitoKit,GyoshukuKit}` という
隔離した sibling 配置へ展開した。両 sibling リポジトリへの書き込みは行っていない。

| 依存 | commit |
|---|---|
| KaitoKit | `73c1b9f89978f51e6bdfaebec01b28755f39341b` |
| GyoshukuKit | `efdb6517d74d59e26fb5f7b1f46ccfd6854f8aa7`（S11） |

Xcode の `swiftc` / `xctest` を直接使った。target は `arm64-apple-macos26.0`、Swift 6、
DEBUG、MainActor default isolation、`NonisolatedNonsendingByDefault` / `InferIsolatedConformances`、非最適化。
依存・アプリ・全テストソースを実際にコンパイルした。既存の Sparkle framework をリンクし、依存のスタブは使っていない。

- [build.py](../../build/P2AS13Verification/build.py) と `KaitoKit-command.json` / `GyoshukuKit-command.json` /
  `app-command.json` / `test-command.json` に全引数。各 `*-build.log` に出力。
- [Release 型検査のコマンド](../../build/P2AS13Verification/release-typecheck-command.json):
  アプリ全ソースから DEBUG / enable-testing を外した `-typecheck` が成功。Release のリンク・実行ではない。
- [resource 包装スクリプト](../../build/P2AS13Verification/package-resources.py):
  直接コンパイルした library を検証専用 framework に置き、`xcstringstool compile` で26 lprojを生成した。
  通常のアプリ host のビルドではない。
- [選択実行スクリプト](../../build/P2AS13Verification/run-tests.py)、
  [全 selector と exit](../../build/P2AS13Verification/test-results.json)、
  [追加の回帰試験の選択](../../build/P2AS13Verification/regression-selection.json)。

直接 runner の環境とコマンドの形:

```sh
DYLD_LIBRARY_PATH="$PWD/build/P2AS13Verification" \
DYLD_FRAMEWORK_PATH="$PWD/build/P2AS13Verification:$PWD/build/Review0924Opt/Build/Products/Debug" \
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest 'KaitoFinderTests.<class または class/method>' \
  build/P2AS13Verification/P2AS13Tests.xctest
```

初回は自作 runner の Info.plist 不足で起動前に失敗した。これを直した後、新規試験の選択範囲・
synthetic entry fixture・rewrite の進捗期待値・非 tar に渡す所有者 option を修正して再実行した。
rewrite の進捗は従来どおり、total は元の件数、callback は運んだ件数であり、
fallback の試験は変更の一単位と carry の各単位が二重に数えられないことを照合する。
途中のコンパイル失敗と resource 包装スクリプトの再実行時の修正を、成功したビルド・試験として数えていない。

## 直接 XCTest の結果（correction 1 前）

初回実装時の最終結果は **114件成功、5件 skip、失敗0**（119件、再実行を重複計上しない）。
case ごとの状態は [final-summary.json](../../build/P2AS13Verification/final-summary.json)。
通常 host の全件成功という意味ではない。

| class（選択実行を含む） | 成功 | skip | 失敗 |
|---|---:|---:|---:|
| TarUpdateEditTests | 9 | 2 | 0 |
| TarUpdateProjectionTests | 3 | 0 | 0 |
| EditPlacementPreferencesTests | 4 | 0 | 0 |
| ArchiveCapabilityInspectionTests | 9 | 1 | 0 |
| ArchivePreferencesTests | 5 | 0 | 0 |
| DeferredSavePlanEquivalenceTests | 5 | 0 | 0 |
| DeferredSaveAttributeTests | 5 | 0 | 0 |
| WordingAcceptanceTests | 1 | 0 | 0 |
| ArchivePublicationTransformationTests | 6 | 0 | 0 |
| ArchiveReaderAdoptionTests | 12 | 2 | 0 |
| ArchiveRewriteTests | 33 | 0 | 0 |
| ArchiveImportTransactionVerificationTests | 11 | 0 | 0 |
| ArchiveImportCorrectionTests | 6 | 0 | 0 |
| ScenarioShapeTests | 1 | 0 | 0 |
| CompressionCapabilityTests | 1 | 0 | 0 |
| ArchiveEditTests | 1 | 0 | 0 |
| ArchivePreferencesUITests | 2 | 0 | 0 |

skip の内訳は `TarUpdateEditTests` と `ArchiveReaderAdoptionTests` の HFS+ / ExFAT 各2件、
および `ArchiveCapabilityInspectionTests.testHundredThousandEntryZIPSessionOpensInAboutOneParse` の1件。
前者は `hdiutil create` が「装置が構成されていません」で失敗、後者は opt-in の計測変数を設定していないため。
clone 無効の sequential 試験は成功した。PerformanceProbeTests は起動していない。

設定画面を操作する GUI case は実行していない。`ArchivePreferencesUITests` の直接実行2件は view model のみ。
KaitoKit 199、GyoshukuKit 43、アプリ101、テスト127の Swift ソースを直接コンパイルした。
アプリの DEBUG コンパイルと Release 型検査に警告はない。依存側と既存の
`ArchiveDocumentControllerTests` / `ArchiveEditTests` / `ArchiveImportSafetyTests` に既存の警告がある。
`git diff --check`、新規キー10件 × 26言語の JSON 検査、削除した型・stage の参照が残っていないことも確認した。

## AC と試験の対応

| 条件 | 試験 |
|---|---|
| AC-A1 | `ArchiveCapabilityInspectionTests` の tar 拡張子・分割・門番・兄弟巻のない分割名、`EditPlacementPreferencesTests.testEveryFormatOptionAndRouteCombination` |
| AC-A2 | `TarUpdateEditTests.testImmediateEditsKeepMemberBytesAttributesAndAdoptVerifiedReader` の9操作。SPI の strategy、作業ファイル数、原本 inode/mtime/byte、member group、uid/gid/uname/pax、mode/xattr/quarantine/作成日、採用を照合。空 tar 再追加・名前の生 byte は別 case |
| AC-A3 | `testDeferredFiveChangesAndRenameOnlyKeepProjectedStorageOrder`。pending の相対順と保存後の連番を照合 |
| AC-A4 | `testStructuralFallbackOpensAndMutatesExactlyOnce`。global uid / 旧 GNU sparse / CP932 × 即時・保存の6通り。`willOpenUpdater`・fallback・mutate・両 open stage は各1回。commit/mutate の requiresRewrite は拒否。設定変更は `testOpenDocumentUsesNewSettingsOnTheNextEdit` |
| AC-A5 | `testOutputOrderAndLinkCorruptionAndUpdaterVerificationAreRejected`、`TarUpdateProjectionTests`。同じ実体を指す別の直接参照先も拒否 |
| AC-A6 | `DeferredSaveAttributeTests` の記録 editor、tar / tar.gz / 7z / LHA の日時、keep/reset、別ユーザー所有の追加、大きな uid/gid と pax。`ArchiveImportCorrectionTests` と `ArchiveReaderAdoptionTests` は所有者保存時も検証 open 1回 |
| AC-A7 | HFS+ / ExFAT / MS-DOS FAT32 は `VolumePublishTestDisk` を使う3 case。clone 無効の sequential は別 caseで比較 |
| AC-A8 | `ArchivePreferencesTests`、`EditPlacementPreferencesTests`、`ArchivePreferencesUITests`。popup 実操作・refresh の GUI case は未実行 |
| AC-A9 | 下記の既存試験の変更一覧。旧設定は `testRewriterEndAndLegacyBeginningAcrossFormats`、keep/reset の試験、rewrite carry の取消し試験で明示 |
| AC-A10 | `WordingAcceptanceTests.testEditPlacementAndOwnerIDWordingHasAllTwentySixTranslations`。26言語・state・空値・bundleとの一致・日本語・旧キー不存在 |
| AC-A11 | Codex は直接コンパイル・選択実行のみ。オーケストレータの初回全件結果は correction 1 節、修正後の全件は未実行 |
| AC-A12 | PerformanceProbeTests の tar 経路期待値と direct editor を更新。P0b と正式な受入計測は未実行 |

## 変更した既存試験の全一覧（AC-A9）

新規 case の追加だけを行ったクラスはこの一覧に含めない。共通 helper の assertion を変えた場合は、
その helper を使う既存 case も列挙する。試験の削除・skip 化・許容閾値の引き下げはしていない。

- `ArchiveRewriteTests`:
  `testTarCapabilityUsesRewriteMode` → `testTarCapabilityUsesUpdateMode`、
  `testTGZCapabilityUsesTarGzipDespiteKaitoKitReportingTar`、`testSevenZipCapabilityUsesRewriteMode`、
  `testLHACapabilityUsesRewriteMode`（共通 `assertCapability`）、
  `testTarWrapperDetectionUsesMagicInsteadOfExtension`、
  `testTarDocumentEditsAndUndoRestoreOriginalSHA256`、`testTGZDocumentEditsAndUndoRestoreOriginalSHA256`、
  `testTarBzip2DocumentEditsAndUndoRestoreOriginalSHA256`、`testTarXZDocumentEditsAndUndoRestoreOriginalSHA256`、
  `testSevenZipDocumentEditsAndUndoRestoreOriginalSHA256`、`testLHADocumentEditsAndUndoRestoreOriginalSHA256`
  （共通 `assertDocumentEditsAndUndo` の mode と tar commit 1000単位）、
  `testCancellationDuringRewriteCarryPreservesBytesAndRegistersNoUndo`（旧設定 `.beginning` を明示）、
  `testExtensionlessTarRewriteUsesTarWorkFile`、`testWindowRewriteNoticeContainsRecompressionAndZIPDoesNot`。
- `ArchiveEditTests`:
  `testZIPDocumentMovePublishesIdenticalContentsAndOneMoveUndoRedoStep`、
  `testTarDocumentMovePublishesIdenticalContentsAndOneMoveUndoRedoStep`（共通 `assertDocumentMoveUndoRedo` の tar mode）。
- `CompressionCapabilityTests.testPlainTarMemberNameDoesNotMasqueradeAsBzip2Header`（tar mode）。
- `ScenarioShapeTests.testTarHardLinkAndSymlinkSurviveRewriteAppend`（tar mode、追加が末尾である順序 assertion）。
- `ArchivePublicationTransformationTests.testHardLinkDirectTargetsAndChainsPublishImmediatelyAndDeferred`
  （単一 tar は最初の生存 holder のみ実体化。圧縮 tar の従来の期待は維持）。
- `ArchiveReaderAdoptionTests.testFiveChangeSavesAdoptIncludingTarOwnerRestoration` →
  `testFiveChangeSavesAdoptIncludingPreservedTarOwners`（所有者保存の tar も open 1回）。
- `ArchivePreferencesTests.testEmptyStoreUsesDefaults`、
  `testWriterOptionsMatchEachFormatAndKeepFixedEncodersDefault`（共通 `assertOptions` に追加位置・所有者方針を追加）。
- `ArchivePreferencesUITests.testViewModelEveryControlUpdatesStore`、
  `testSettingsControlsPersistAndRefreshWithoutReopening`（新設定、popup、accessibility label、refresh）。
- `DeferredSaveAttributeTests.testPendingAndSavedDirectoryFileDatesModesAndXattrsMatchInEveryFormat`
  （TarUpdater の tar を追加）、`testTarOwnerCarrierPreservesLargeIDsAndPAXPaths`（旧 helper の直接呼出しから replay へ）。
- `DeferredSavePlanEquivalenceTests.testKeyCountsAreBoundedByEntriesAndChanges`
  （`StubEditor` に owner IDs / directory date の2要件を実装）。
- `PerformanceProbeTests.testArchiveEditsWhenEnabled`（`probeImmediate` / `probeDeferred` の tar は
  `updater_open` を要求し `rewriter_open` / `work_copy` を禁止）、
  `testArchiveEditorsDirectlyWhenEnabled`（`probeDirect` の tar は output 指定の TarUpdater）。
- `M6cNameRuleTests.testTarDeletePreservesNameBytesInBothSaveModes`
  （correction 1: 単一 tar の capability は `.update(.tar)`、圧縮 tar は `.rewrite`）。
- `ArchiveEditPathTests.testRenameDirectoryWithLeadingDotComponentsPreservesEveryDescendant`、
  `testNewFolderResolvesDisplayedParentAndOccupiedNamesInDotPrefixedTar`
  （correction 1: `.end` では運ぶ `./target/keep.txt` を保持、`.beginning` の旧設定 variant では `target/keep.txt` に正規化）。
- `AutosaveIsolationTests.testAutosaveKeysCoverAllApplicationAutosaveNames`
  （correction 1: 新設定の2キーを既存の退避対象一覧と照合）。
- `M6bReviewTests.testSplitProgressCountsRemovalsAndOnlyFinalCarryPass`
  （correction 1: 非 ZIP の carry 見積りは所有者保存に依らず `base.count`。completed の assertion は維持）。

共通試験支援の `TestProcessSetup` には新しい設定キー二つの退避・各 case 前の消去・終了時の復元を追加した。
`ArchiveCapabilityInspectionTests`、`ArchiveImportCorrectionTests`、`WordingAcceptanceTests` の既存 case は変えず、
受入条件の新規 case を追加した。

## S13 correction 1（2026-09-26）

オーケストレータから、隔離 tree（GyoshukuKit `efdb651` / KaitoKit `73c1b9f`）での
全件実行は1,450 tests、31 failures、そのうち11は既知の画面ロック時 GUI failure と報告された。
これは Codex の直接実行結果ではない。指摘された8 case に対して、以下を修正した。

- `ArchiveCapabilities.inspect` は TarUpdater R7 と同じ名前解析を使い、単独の `.tar.001` も rewrite に残す。
  新規 `testSingleTarWithSplitVolumeNameStillRewritesWithoutSiblings` は `.tar.001` / `.TAR.0001` で
  reader / URL の両 inspect を照合する。`ArchiveSplitVolumeTests` の既存 assertion は変えていない。
- 上記一覧の既存5 case の期待値を修正。dot 付き tar の2 case は `.end` と `.beginning` を両方実行する。
- フランス語の `追加した項目の位置:` / `変更しない項目の所有者ID:` の訳は、コロン前に既存の規約と同じ U+00A0 を置く。
  `WordingAcceptanceTests.testFrenchStyle` の assertion は変えていない。
- `TarUpdateEditTests.testFAT32EditsMatchAPFS` を追加し、既存の `checkVolume("MS-DOS FAT32")` 経路を使う。
  exFAT の `sourceChanged` に対する KaitoFinder 側の回避処理・skip 条件は追加していない。
  FAT/exFAT の空ファイルの sentinel inode に対する GyoshukuKit 修正と実ボリューム再実行はオーケストレータに残す。

全テストソースを `rg` で再点検した（[残る rewrite / rewriteNotice の箇所](../../build/P2AS13Verification/correction1/rewrite-expectation-audit.txt)）。
残る `.rewrite(.tar)` は分割名・分割巻の期待、明示的な rewrite 呼出し、fallback / projection、
または drag の capability 試験値である。分割名を持たない単一 tar を rewrite とする capability / notice の期待は残っていない。

今回の検証も、先に `git archive` した KaitoKit `73c1b9f` / GyoshukuKit `efdb651` の依存 library を使用した。
依存は再コンパイルせず、アプリ101ソースとテスト127ソースを DEBUG 条件で直接再コンパイルした。
両方成功し、26言語の resource を `xcstringstool` で再生成した。Release 条件の全アプリ `-typecheck` も成功した
（[全コマンドと exit](../../build/P2AS13Verification/correction1/release-typecheck-result.json)）。
アプリのコンパイル / 型検査に警告はなく、テスト側は初回と同じ既存の警告のみ。

実行した主なコマンド:

```sh
python3 build/P2AS13Verification/build.py app test
python3 build/P2AS13Verification/package-resources.py
python3 build/P2AS13Verification/correction1/run-tests.py
```

直接 XCTest は **34件成功、3件 skip、失敗0**（37件）。
初回の119件とは重複するため合算しない。[全 selector](../../build/P2AS13Verification/correction1/selection.json)、
[各 xctest コマンドと exit](../../build/P2AS13Verification/correction1/test-results.json)、
[case 別結果](../../build/P2AS13Verification/correction1/summary.json)と各 `.log` を保存した。

| class（選択実行を含む） | 成功 | skip | 失敗 |
|---|---:|---:|---:|
| ArchiveCapabilityInspectionTests | 3 | 0 | 0 |
| ArchiveSplitVolumeTests | 4 | 0 | 0 |
| M6cNameRuleTests | 1 | 0 | 0 |
| ArchiveEditPathTests | 7 | 0 | 0 |
| AutosaveIsolationTests | 1 | 0 | 0 |
| M6bReviewTests | 1 | 0 | 0 |
| WordingAcceptanceTests | 3 | 0 | 0 |
| TarUpdateEditTests | 9 | 3 | 0 |
| EditPlacementPreferencesTests | 4 | 0 | 0 |
| ArchiveReaderAdoptionTests | 1 | 0 | 0 |

skip は `TarUpdateEditTests.testHFSPlusEditsMatchAPFS` / `testExFATEditsMatchAPFS` /
`testFAT32EditsMatchAPFS`。いずれも `hdiutil create` が「装置が構成されていません」で失敗し、
既存 helper が skip した。FAT / exFAT の `sourceChanged` 解消を確認した結果ではない。
clone 無効の sequential 試験は成功した。指摘された残り7 case はすべて成功した。

`git diff --check`、全フランス語コロンの U+00A0、全26言語の catalog / bundle の一致を確認した。
今回も xcodebuild、GUI 操作、全件試験、性能プローブは実行していない。兄弟リポジトリの編集・コミットはしていない。

## オーケストレータに残す検証

- 修正後の `xcodebuild build-for-testing`、通常アプリ host での全件試験。
- Settings の popup / checkbox と表示幅、26言語の画面、非圧縮 tar の注意書きの GUI 確認。
- HFS+ / exFAT / FAT32 の実ボリューム試験（sandbox の skip は合格扱いにしない）。
- AC-A12: B-P2 との同一条件での最適化 Debug、100k / 500k / 256 MiB の P0b。
  tar は `updater_open`、fallback は両 open が一度ずつ、`rewriter_open` / `work_copy` / `reload_open` が通常経路にないこと。
  他形式の total ±10% と仕様の tar 閾値を測り、未計測値を速度改善の根拠にしない。

## release notes に書く既定の変更

- 追加した項目は既定でアーカイブの末尾に入る。tar 系・7z・LHA の従来の「先頭」へ戻す設定を用意した。
  先頭を選ぶと編集のたびにアーカイブ全体を書き直す。ZIP は常に末尾。
- 変更しない tar 項目の uid/gid は既定で保つ。「0に戻す」を選ぶと全体を書き直して従来の値へ戻す。
  追加ファイルの所有者 ID を保存する設定は別で、値と既定は従来どおり。
- 単一の非圧縮 tar の更新では、変更しない member の名前の byte（NFD、`./`、先頭の `/`、`//`）を保つ。
  編集後の表示名は従来どおり KaitoKit の解読による。構造上の fallback と従来設定の書き直しは従来の正規化になる。

## オーケストレータの検証（2026-09-26）

隔離した三つ組 `$SCR/v2/{KaitoKit,GyoshukuKit,KaitoFinder}`（KaitoKit 73c1b9f と GyoshukuKit は `git archive`、KaitoFinder は作業ツリーの rsync）。
画面はロック中（`IOConsoleLocked` = true）。

| 実行 | 結果 |
|---|---|
| S13 の全件（GyoshukuKit efdb651） | 1,450 件、31 失敗。11 件は画面ロック中の既知の GUI 系（S8 の全件と同じ集合）。残り 8 件を correction 1 で直した |
| exFAT の失敗の原因 | GyoshukuKit の不具合。FAT32 / exFAT では空のファイルに仮の inode（最上位から減る番号）が付き、最初の書き込みで cluster 番号に変わる。空のうちに記録した inode との食い違いで commit が `sourceChanged` になり、出力も残っていた。GyoshukuKit da0af7b で修正 |
| correction 1 の後の全件（GyoshukuKit の修正 1 の作業ツリー） | 1,452 件、20 失敗（9 件は想定内の失敗）。失敗した 11 試験はすべて画面ロック中の既知の GUI 系（ArchiveConflictUITests 1、ArchivePasswordUITests 8、ArchivePreviewSidebarTests 1、ArchiveTabTests 1）。新しい失敗なし |
| GyoshukuKit da0af7b での `TarUpdateEditTests`・`ArchiveSingleCopyEditTests` | 26 件、失敗 0（FAT32・exFAT・HFS+ の実イメージを含む） |

受入計測（AC-A12、P0b を B-P2 と比べる）は、負荷の平均が 4 未満のときに採り、この節の後に追記する。
