# ウインドウのカスケード・エラー文言・スナップショット保持 — 2026-09-15

## 結果

SCOPE A/B/Cを実装した。指定のxcodebuildコマンドは3種類とも実行したが、サンドボックスがClang/SwiftPMのキャッシュへの書き込みを拒否し、依存関係解決で停止した。いずれも終了コード74。**正規ビルド・指定テスト・全テストの完走は未確認**であり、成功とは扱わない。再実行でも同じ制限を確認した。

一時ディレクトリでの補助検証では、Swift 6・厳密並行性チェック・MainActor既定分離を指定してアプリ全ソースをコンパイルし、全テストソースを型チェックした。いずれも警告・エラーなし。更新したカタログもコンパイルできた。補助XCTestは**38件中37件成功、1件スキップ、失敗0件**だった。

KaitoKitとGyoshukuKitは編集していない。プロジェクト・ビルド設定の最終差分はなく、依存関係の追加やgitコミットの作成も行っていない。

## 変更内容

### A. ウインドウの配置

[ArchiveWindowController.swift](../../KaitoFinder/UI/ArchiveWindowController.swift)の初回の非表示状態での`showWindow(_:)`に配置処理を追加した。表示中のアーカイブウインドウを前面順に調べ、自分自身と同じタブグループを除外する。参照元の`cascadeTopLeft(from: .zero)`が返す位置へ新規ウインドウを配置し、その後に`super.showWindow`を呼ぶ。

参照元がなければ復元済みのフレームを保持する。表示済みのウインドウは再配置しない。共有の可変カスケード位置は使わず、移動された前面ウインドウの現在位置から毎回決める。フレーム自動保存、初期中央配置、タブ設定は変更していない。

### B. エラー文言

[ArchiveErrorText.swift](../../KaitoFinder/UI/ArchiveErrorText.swift)に`nonisolated`の共通変換処理を追加した。CancellationError、KaitoError、WriterError、RewriterError、UpdaterErrorの指定された全ケースを処理する。システムのエラー番号は`strerror`で説明に変換する。ArchiveEditErrorとExtractionFailureは既存の説明を返し、その他のエラーは`localizedDescription`を返す。

指定された次の表示経路を置き換えた。

- ArchiveCreationController、ArchiveWindowController（`editFailureReason`のフォールバックを含む）
- ArchiveCapabilities、ArchiveMaterializationController
- ArchiveIncomingFiles、ArchiveImportPlan
- ExtractionService、ArchiveBatchExtraction

注入されたBundleを持つウインドウの経路では、そのBundleをヘルパーへ渡す。既存のNSLog診断、バッチ展開のキャンセル分岐、ArchiveAlertTextによる句点の処理は維持した。

[Localizable.xcstrings](../../KaitoFinder/Resources/Localizable.xcstrings)に**27キー・各10言語**を追加した。既存222キーの内容はすべて維持し、合計249キーとなった。チェックサムの項目番号は文字列として補間し、仕様どおりの日本語の空白と既存の日本語表記検査を両立した。新しい説明文には末尾の句点を付けず、既存説明を返すケースでは指定どおり原文を保持する。

### C. スナップショットの保持

[UISnapshot.swift](../../KaitoFinderTests/Support/UISnapshot.swift)に内部ヘルパー`pruneRuns(in:keeping:)`を追加した。既定保存先に新規実行ディレクトリを作成した後、日時名で新しい順に今回を含む5世代を保持する。日時名に一致する実ディレクトリだけを削除対象とし、任意名のディレクトリ、通常ファイル、シンボリックリンクは対象にしない。

`KAITOFINDER_SNAPSHOT_DIR`が設定されている場合は削除しない。空文字列が設定されている場合にも削除しない。

[既存の保存先説明](2026-09-15-ui-snapshots.md#保存先)に保持規則と`env TEST_RUNNER_KAITOFINDER_SNAPSHOT_DIR=<dir> xcodebuild test …`を追記した。xcodebuild自身の環境変数として渡すこと、xcodebuildの引数として渡しても効果がないことを明記した。

## 追加テスト

新規12テスト。既存テストの削除・緩和は行っていない。

### ArchiveWindowCascadeTests（1件）

- `testFirstShowCascadesFromFrontmostVisibleArchiveWindow`：A→B→移動後のBを参照するC、B/Cを閉じた後のA→D、参照元なしのEを検査する。0.5ポイントの許容差で左上座標を比較し、参照元が動かないこと、表示・非表示を繰り返しても再配置しないことも確認する。ウインドウは終了時に閉じる。画面を取得できない環境では明示的にスキップする。

### ArchiveErrorTextTests（10件）

- `testCancellationAndEveryKaitoErrorInJapanese`
- `testEveryWriterErrorInJapanese`
- `testEveryRewriterErrorInJapanese`
- `testEveryUpdaterErrorInJapanese`
- `testExistingEditAndExtractionDescriptionsArePreserved`
- `testOtherErrorsUseLocalizedDescription`
- `testMalformedArchiveAndCapabilityNoticeDoNotExposeEnumDumps`
- `testEnglishRenderingAndCallerPunctuation`：英語6ケースと呼び出し側の句点付加
- `testAllErrorTextKeysHaveTenTranslations`
- `testUserFacingCallSitesDoNotDescribeErrorEnumsDirectly`：指定の8ファイルを走査し、NSLog以外の直接変換がないことを確認

### UISnapshotTests（追加1件）

- `testPrunesOnlyOldTimestampRunsAndPreservesCustomDirectory`：7世代から新しい5世代だけを残し、任意名の保存先とその内容、日時名の通常ファイルを保持する。

## 指定の検証コマンドと実出力

作業ディレクトリは次のとおり。パイプを含むxcodebuildの実行では`set -o pipefail`を有効にし、元の失敗を終了コードに反映した。

```sh
cd /Users/nagash/Github/KaitoFinder
set -o pipefail
```

### ビルド

```sh
xcodebuild -scheme KaitoFinder -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
```

終了コード：74。最終実行の実出力：

```text
2026-09-15 15:04:27.326 xcodebuild[13574:10797564] Logging connecton invalid: <OS_xpc_error: <dictionary: 0x1fca3cb60> { count = 1, transaction: 0, voucher = 0x0, contents =
[-[SimServiceContext initWithDeveloperDir:connectionType:error:]:499] WARN  : Unable to discover any Simulator runtimes. Developer Directory is /Applications/Xcode.app/Contents/Developer.
[-[SimServiceContext initWithDeveloperDir:connectionType:error:]_block_invoke:556] ERROR : Could not get list of trusted mount directories: Error Domain=com.apple.CoreSimulator.SimError Code=409 "Cannot talk to the service used to manage runtime disk images (simdiskimaged) because its launchd job is not registered or was unloaded" UserInfo={NSLocalizedDescription=Cannot talk to the service used to manage runtime disk images (simdiskimaged) because its launchd job is not registered or was unloaded}
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
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

### 指定テスト

```sh
xcodebuild -scheme KaitoFinder -destination 'platform=macOS' test -only-testing:KaitoFinderTests/ArchiveWindowCascadeTests -only-testing:KaitoFinderTests/ArchiveErrorTextTests -only-testing:KaitoFinderTests/WordingAcceptanceTests -only-testing:KaitoFinderTests/UISnapshotTests 2>&1 | grep -E 'error:|Test Suite|Executed|failed'
```

終了コード：74。最終実行の実出力：

```text
2026-09-15 15:04:28.217 xcodebuild[13586:10797639] Logging connecton invalid: <OS_xpc_error: <dictionary: 0x1fca3cb60> { count = 1, transaction: 0, voucher = 0x0, contents =
[-[SimServiceContext initWithDeveloperDir:connectionType:error:]_block_invoke:556] ERROR : Could not get list of trusted mount directories: Error Domain=com.apple.CoreSimulator.SimError Code=410 "The service used to manage runtime disk images (simdiskimaged) crashed or is not responding" UserInfo={NSLocalizedDescription=The service used to manage runtime disk images (simdiskimaged) crashed or is not responding}
[-[SimServiceContext initWithDeveloperDir:connectionType:error:]:499] WARN  : Unable to discover any Simulator runtimes. Developer Directory is /Applications/Xcode.app/Contents/Developer.
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
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

### 全テスト

```sh
xcodebuild -scheme KaitoFinder -destination 'platform=macOS' test 2>&1 | grep -E 'Executed|failed|error:' | tail -5
```

終了コード：74。最終実行の実出力：

```text
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/gyoshukukit.dia' for diagnostics emission (Operation not permitted)
```

上記はいずれもパッケージ解決で停止したため、テスト失敗件数やビルド成功を示す結果ではない。キャッシュへの書き込み拒否に加え、先頭の出力にはSimulatorサービスの接続エラーも含まれる。制限回避のためにプロジェクトやビルド設定を変更していない。

### 表示経路の直接変換検索

```sh
grep -rn 'String(describing: error)' KaitoFinder | grep -v NSLog
```

実出力は空。終了コード1は該当行なしを示す。

### 禁止語検索

仕様書末尾の大文字小文字を区別しない検索コマンドをそのまま実行した。検索語自体は記載制約に従い、このレポートには再掲しない。検索による一致行はなく、後続のechoだけが出力された。終了コード0。

```text
must print nothing
```

## 補助検証

### コンパイルと型チェック

一時フレームワークに現在のアプリ全ソースをコンパイルし、既存のビルド済みKaitoKit/GyoshukuKitをリンクした。カタログは`xcstringstool`で今回のソースから10言語分をコンパイルし、既存のServicesMenu.stringsとともに一時フレームワークへ配置した。全テストソースの型チェック後、対象テストをXCTestバンドルにコンパイルした。

```sh
python3 /private/tmp/kaitofinder-cascade-check/build-check.py
```

終了コード0。実出力：

```text
app-compile: exit 0
catalog-compile: exit 0
all-tests-typecheck: exit 0
focused-tests-compile: exit 0
```

完全なコンパイラ引数とログは`/private/tmp/kaitofinder-cascade-check/`の`*.command.txt`、`app-compile.log`、`catalog-compile.log`、`all-tests-typecheck.log`、`focused-tests-compile.log`に保存した。

### XCTest直接実行

```sh
xcrun xctest -XCTest 'CascadeCheckTests.ArchiveWindowCascadeTests,CascadeCheckTests.ArchiveErrorTextTests,CascadeCheckTests.WordingAcceptanceTests,CascadeCheckTests.UISnapshotTests,CascadeCheckTests.ArchiveEntryControlsTests/testAllEditUIAndUndoStringsHaveCatalogEntriesAndTranslations' /private/tmp/kaitofinder-cascade-check/CascadeCheckTests.xctest > /private/tmp/kaitofinder-cascade-check/xctest.log 2>&1
```

終了コード0。ログ末尾の実出力：

```text
Test Suite 'CascadeCheckTests.xctest' passed at 2026-09-15 15:03:17.059.
	 Executed 38 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.729 (0.731) seconds
Test Suite 'Selected tests' passed at 2026-09-15 15:03:17.059.
	 Executed 38 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.729 (0.732) seconds
```

| 対象 | 件数 | 結果 |
| --- | ---: | --- |
| ArchiveErrorTextTests | 10 | 成功 |
| WordingAcceptanceTests | 17 | 成功 |
| UISnapshotTests | 9 | 成功 |
| ArchiveEntryControlsTestsのカタログ網羅テスト | 1 | 成功 |
| ArchiveWindowCascadeTests | 1 | 利用可能な画面がなくスキップ |

完全な実出力は`/private/tmp/kaitofinder-cascade-check/xctest.log`に保存した。

- この環境では`NSScreen.main`を取得できず、カスケードの実表示は未確認。
- PNGの保存・読込・画素検査は成功したが、XCTest添付のエンコードでは`kLSDataUnavailableErr`を含む警告が3件出た。添付保存の成功は未確認。メニュー検査時の`Unable to find feedback application.`もログに残っている。
- 最初の補助実行で日本語表記テストが検出した項目番号の書式指定子は修正し、上記の再実行で成功を確認した。初期の独自ランナーはXCTContextの活動設定がなく停止したため、最終検証はxctestで実行した。初期ログは`focused-tests.log`に残した。
- この補助実行を、アプリをホストにした正規ビルドや全テストの成功とは扱っていない。

### 保存先・環境変数の別プロセス検証

変更したUISnapshot.swiftを一時ランナーへコンパイルし、テスト専用のTMPDIRで環境変数の有無を切り替えて実行した。

```sh
python3 /private/tmp/kaitofinder-cascade-check/check-retention.py
```

終了コード0。実出力：

```text
Default directory: newest 5 runs retained, including the new run
Configured custom directory: all 7 existing runs and saved content preserved
Configured timestamp directory: all 7 existing runs and saved content preserved
Empty environment variable: no runs deleted
```

任意名の指定先だけでなく、日時名のディレクトリを指定した場合も既存7世代を保持することを確認した。

### カタログ静的検査

```sh
python3 /private/tmp/kaitofinder-cascade-check/check-catalog.py
```

終了コード0。実出力：

```text
Catalog: 249 keys; 10 nonempty translations and matching ordered format specifiers per key
Existing catalog entries unchanged: 222; new keys: 27
Japanese spacing, French spacing, German pronouns, Spanish archive vocabulary, Korean particles: passed
```

### 差分検査

```sh
git diff --check
```

実出力は空、終了コード0。

## 最終報告

A/B/Cを実装し、[検証レポート](/Users/nagash/Github/KaitoFinder/Documentation/verification/2026-09-15-cascade-error-text.md)に記録しました。

補助テストは37件成功、1件スキップ。xcodebuildはサンドボックス制限で完走できず、全テストの成功は未確認です。パッケージ・ビルド設定は未変更、コミットは作成していません。

## 検証で見つかった回帰

### 追補の結果

追補の4項目を修正した。既存の未コミット変更を保持し、KaitoKit/GyoshukuKitと`ArchiveUndoStack.unchanged`は編集していない。プロジェクトファイルは追補開始時点の内容をそのまま保持した。コミットは作成していない。

修正後の補助検証は**49件中48件成功、1件スキップ、失敗0件**。新しい拡張属性・mtimeの2テストと既存の外部置換検査を含むScenarioExternalChangeTestsの5件はすべて成功した。Swift 6のアプリ全ソースのコンパイルと全テストソースの型チェックも成功した。正規のxcodebuildは今回もサンドボックス制限で停止し、全スイートの完走と前面でのQuick Lookの動作は未確認。

### 1. 内容を変えない拡張属性の更新で読み取り・編集を拒否する不具合

ユーザーから提供された実シェルでの検証結果は518件・2失敗で、どちらも前面でのQuick Lookテストだった。追補仕様によればHEADでも再現しており、A/B/C差分以前から存在する不具合である。

文書を開くとLaunchServicesが`com.apple.lastuseddate#PS`拡張属性を書き、内容を変えずにctimeを更新する。提供された実測はctimeが1789454337から1789454338へ変わり、inodeとmtimeは不変だった。旧`ArchiveImportTransaction.identity(_:)`はctimeも保持していたため、セッションの読み取りと編集時に原本変更と判定して拒否していた。Finderタグの更新でも同じ条件になる。

[ArchiveImportTransaction.swift](../../KaitoFinder/Import/ArchiveImportTransaction.swift)からctimeの秒・ナノ秒を除外した。同一性判定にはdevice/inode/size/mode/mtimeの秒・ナノ秒を残し、除外理由を日本語コメントに記載した。短時間の取り消し用コピーを検査する`ArchiveUndoStack.unchanged`のctime比較は維持した。

[ScenarioExternalChangeTests.swift](../../KaitoFinderTests/ScenarioExternalChangeTests.swift)に次を追加した。

- `testLastUsedDateXattrAfterOpeningDoesNotInvalidateTheSession`：文書を開いた後に指定の拡張属性へ16バイトを書き、ctime変更・inode/mtime不変・identity一致を検査する。その後の`extractionSnapshot()`とフォルダ作成が成功し、generationが1増え、取り消しが登録されることを確認する。
- `testMtimeChangeRefusesSessionReadsAndEdits`：`utimes`でmtimeを60秒進め、inodeと内容を保持したままidentityが変わることを確認する。読み取り・編集はともに`.archiveChanged`で拒否され、generationと取り消し履歴が変わらないことも確認する。
- 既存の`testReplacementWithIdenticalNamesRefusesEveryEditAndPreservesUndo`は維持し、置換後の原本に対する4種類の編集の拒否を再確認した。

#### 修正前の再現

追補開始時点のソースを一時ディレクトリへ保存し、それをコンパイルしたフレームワークに新しい回帰テストを当てた。リポジトリ内の修正を戻す操作は行っていない。

```sh
python3 /private/tmp/kaitofinder-cascade-followup-check/build-check.py --before
xcrun xctest -XCTest 'FollowupTests.ScenarioExternalChangeTests/testLastUsedDateXattrAfterOpeningDoesNotInvalidateTheSession' /private/tmp/kaitofinder-cascade-followup-check/before/FollowupTests.xctest > /private/tmp/kaitofinder-cascade-followup-check/before/xctest.log 2>&1
```

コンパイルは終了コード0、テストは終了コード1。identityの比較がctimeだけの差で失敗し、その後の読み取りも例外で終了した。実出力の該当箇所：

```text
/Users/nagash/Github/KaitoFinder/KaitoFinderTests/ScenarioExternalChangeTests.swift:24: error: -[FollowupTests.ScenarioExternalChangeTests testLastUsedDateXattrAfterOpeningDoesNotInvalidateTheSession] : XCTAssertEqual failed: ("[16777229, 101515745, 130, 33188, 1789455071, 758288159, 1789455071, 937396241]") is not equal to ("[16777229, 101515745, 130, 33188, 1789455071, 758288159, 1789455071, 758288159]")
Test Suite 'ScenarioExternalChangeTests' failed at 2026-09-15 15:51:12.132.
	 Executed 1 test, with 2 failures (1 unexpected) in 1.494 (1.494) seconds
```

修正前の補助バンドルには、一時的なAppKit初期化用オブジェクトの対象OS差によるリンカー警告が1件あった。修正後の補助ビルドでは同じmacOS 26を明示し、警告を解消した。完全な実出力は`before/xctest.log`、コンパイルの引数・出力は同じディレクトリの`*.command.txt`と`*.log`に残した。

### 2. Quick Lookの非表示アニメーションを待つ

[ArchiveDocumentOpeningTests.swift](../../KaitoFinderTests/ArchiveDocumentOpeningTests.swift)の前面Quick Lookテストで、閉じた直後の即時判定を最大2秒の待機へ変更した。既存の`runMainRunLoop`と`Task.sleep`で進行させ、最後の`XCTAssertFalse(panel.isVisible)`は維持した。URL公開を確認する既存の`XCTAssertNotNil`も変更していない。

### 3. テスト終了時にウインドウの自動保存値を戻す

[ArchiveWindowFrameAutosave.swift](../../KaitoFinderTests/Support/ArchiveWindowFrameAutosave.swift)を追加した。`NSWindow Frame ArchiveWindow`を生成前に取得し、保存値があればset、なければremoveObjectで復元する。

単独のウインドウを閉じるテストでは、閉じる処理より先に登録したdeferで最後に復元する。文書を共有ヘルパーで作るテストでは、文書の終了処理より先に復元用のXCTest teardownを登録し、後から登録した文書のclose・非同期クリーンアップが済んでから復元する。途中の失敗やスキップでも復元処理が残る。

対象はArchiveWindowCascadeTests、ArchiveDisplayTests、ArchiveDocumentOpeningTests、ArchiveEntryControlsTests、ArchivePasswordTests、ArchivePasswordPersistenceTests、ArchiveThumbnailTests、ArchiveRewriteTests、LayoutOverflowTests、ArchiveUndoStackTestsのウインドウ生成経路と、共通の`scenarioDocument`、同じ文書を2回開くScenarioConcurrencyTests。共通ヘルパーを使うScenarioNestedTestsなどの途中のcloseも、最後の復元に含まれる。通常のNSWindow、設定ウインドウ、セッションやファイルハンドルだけのcloseは対象外とした。

### 4. 同一性判定の文書を更新

[シナリオ検証レポート](2026-09-15-scenarios.md)の「名前が同じ原本への外部置換を見逃す」と、同じ判定を説明していた[ドラッグ追加の検証レポート](2026-09-10-drag-in.md)をdevice/inode/size/mode/mtimeに更新し、ctimeを除外する理由を追記した。Documentation/design.mdには該当記載がなく、変更していない。

### 追補で実行した検証

#### 修正後のコンパイル・型チェック

```sh
python3 /private/tmp/kaitofinder-cascade-followup-check/build-check.py
```

終了コード0。実出力：

```text
after app-compile: exit 0
after catalog-compile: exit 0
after all-tests-typecheck: exit 0
after bootstrap-compile: exit 0
after tests-compile: exit 0
```

現在のアプリソースをコンパイルし、既存のビルド済みKaitoKit/GyoshukuKitをリンクした。全既存・新規テストソースを型チェックし、対象テストを一時XCTestバンドルにした。修正後のコンパイル・型チェックには警告・エラーなし。

#### 修正後の補助XCTest

```sh
xcrun xctest -XCTest 'FollowupTests.ScenarioExternalChangeTests,FollowupTests.ArchiveWindowCascadeTests,FollowupTests.ArchiveErrorTextTests,FollowupTests.WordingAcceptanceTests,FollowupTests.UISnapshotTests,FollowupTests.ArchiveEntryControlsTests/testAllEditUIAndUndoStringsHaveCatalogEntriesAndTranslations,FollowupTests.ArchiveDisplayTests/testToolbarWithoutSessionKeepsOnlySearchEnabled,FollowupTests.ArchiveDisplayTests/testPathBarLayoutAndArchiveFallbackWithoutDocumentURL,FollowupTests.ArchiveDisplayTests/testArchiveWindowUsesAutomaticTabbing,FollowupTests.ArchiveDisplayTests/testRevealArchiveInFinderValidatesOpenDocumentWithoutSelection,FollowupTests.LayoutOverflowTests/testLockedPlaceholderInJapaneseAndEnglish,FollowupTests.LayoutOverflowTests/testStatusBarWithLargeCountsInJapaneseAndEnglish' /private/tmp/kaitofinder-cascade-followup-check/after/FollowupTests.xctest > /private/tmp/kaitofinder-cascade-followup-check/after/xctest.log 2>&1
```

終了コード0。最終集計の実出力：

```text
Test Suite 'FollowupTests.xctest' passed at 2026-09-15 15:52:20.480.
	 Executed 49 tests, with 1 test skipped and 0 failures (0 unexpected) in 11.437 (11.440) seconds
Test Suite 'Selected tests' passed at 2026-09-15 15:52:20.480.
	 Executed 49 tests, with 1 test skipped and 0 failures (0 unexpected) in 11.437 (11.441) seconds
```

| 対象 | 件数 | 結果 |
| --- | ---: | --- |
| ScenarioExternalChangeTests | 5 | 新規2件と既存3件が成功 |
| ArchiveDisplayTests | 4 | 成功 |
| ArchiveEntryControlsTestsのカタログ網羅テスト | 1 | 成功 |
| ArchiveErrorTextTests | 10 | 成功 |
| LayoutOverflowTestsのロック表示・項目数表示 | 2 | 成功 |
| UISnapshotTests | 9 | 成功 |
| WordingAcceptanceTests | 17 | 成功 |
| ArchiveWindowCascadeTests | 1 | 画面を取得できずスキップ |

完全なログは`/private/tmp/kaitofinder-cascade-followup-check/after/xctest.log`。実行時には、前回と同様にXCTest添付のエンコードに関する警告、Finder連携のsandbox extension拒否、feedback application未検出の診断が出た。PNG保存・読込と上記のテストアサートは成功したが、添付の保存成功は未確認。

#### 正規の指定テスト・全テスト

作業ディレクトリは`/Users/nagash/Github/KaitoFinder`。パイプでは`set -o pipefail`を有効にした。

```sh
xcodebuild -scheme KaitoFinder -destination 'platform=macOS' test -only-testing:KaitoFinderTests/ScenarioExternalChangeTests -only-testing:KaitoFinderTests/ArchiveDocumentOpeningTests -only-testing:KaitoFinderTests/ArchiveWindowCascadeTests 2>&1 | grep -E 'error:|Test Suite|Executed|failed'
```

終了コード74。実出力：

```text
2026-09-15 15:50:49.716 xcodebuild[24420:10900730] Logging connecton invalid: <OS_xpc_error: <dictionary: 0x1fca3cb60> { count = 1, transaction: 0, voucher = 0x0, contents =
[-[SimServiceContext initWithDeveloperDir:connectionType:error:]:499] WARN  : Unable to discover any Simulator runtimes. Developer Directory is /Applications/Xcode.app/Contents/Developer.
[-[SimServiceContext initWithDeveloperDir:connectionType:error:]_block_invoke:556] ERROR : Could not get list of trusted mount directories: Error Domain=com.apple.CoreSimulator.SimError Code=409 "Cannot talk to the service used to manage runtime disk images (simdiskimaged) because its launchd job is not registered or was unloaded" UserInfo={NSLocalizedDescription=Cannot talk to the service used to manage runtime disk images (simdiskimaged) because its launchd job is not registered or was unloaded}
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
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

```sh
xcodebuild -scheme KaitoFinder -destination 'platform=macOS' test 2>&1 | grep -E 'Executed|failed|error:' | tail -5
```

終了コード74。実出力：

```text
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
```


Clang/SwiftPMのキャッシュ書き込みがサンドボックスに拒否され、パッケージ解決で停止した。正規テストは起動しておらず、全スイートの成功とは報告できない。前面のQuick LookでのURL公開・非表示アニメーションと、実画面でのカスケードは実環境での再検証が必要。回避目的でプロジェクト設定やパッケージを変更する操作は行っていない。

#### 静的検査・変更範囲

- `git diff --check`：実出力なし、終了コード0。
- `grep -rn 'String(describing: error)' KaitoFinder | grep -v NSLog`：実出力なし、終了コード1（該当なし）。
- 仕様書指定の禁止語検索：一致なし。実出力は後続echoの`must print nothing`だけ、終了コード0。検索語そのものは記載しない。
- 追補開始時点のコピーと比較し、プロジェクトファイル、ArchiveUndoStack.swift、既存のカタログ、Documentation/design.mdの内容が維持されていることを確認した。

