# M1c 敵対的レビュー後の修正検証（2026-09-10）

## 対象と結果

基準 HEAD は `439c3f8`、M1c の実装は `0902444`。報告された 4 件を修正した。
KaitoKit / GyoshukuKit の変更、新しい依存、書庫への書き込みはない。
Swift 6 strict concurrency、MainActor 既定隔離、Approachable Concurrency を維持した。

arm64 clean build と最終テストバンドルのビルドは成功し、Swift コンパイル警告は 0 件。
直接 XCTest は **73 件、69 成功、4 skip、0 失敗**。追加 6 件はすべて成功し、
既存 67 件は 63 成功・既存のサービス probe による 4 skip。
通常の app-hosted `xcodebuild test -testLanguage en -testRegion US` も試したが、
testmanagerd の sandbox 制限で実行できなかった。従って、今回この環境で通常の
app-hosted 全件実行や 0 skip を確認したとは主張しない。

> **Scope and result.** Starting from 439c3f8 (M1c implementation 0902444), all four
> reported defects are addressed without dependency, archive-writing or engine
> repository changes. Swift 6 strict concurrency and default MainActor isolation
> remain enabled. The arm64 clean build and final test-bundle build succeed with
> zero Swift compiler warnings. Direct XCTest reports 73 tests: 69 passes, four
> existing service skips and no failures. All six additions pass. Normal hosted
> testing with English selected was attempted but testmanagerd access was denied;
> a hosted zero-skip result is not claimed for this environment.

## 1. 文書キャッシュと終了時の削除

`ArchiveDocument.materializationController()` が controller とその worker の寿命を所有する。
成功した `ArchivePreviewItem` は現在選択とは別の辞書に保持し、キーは Sendable / Hashable
な `ArchiveEntryPayload`（archive URL、generation、index、path、directory flag）。
選択を新しい wrapper 配列へ差し替えても、この辞書から完成済み item を取り出す。
Quick Look パネルの終了や control の解放は要求・選択だけを取り消し、キャッシュを消さない。

`ArchiveDocument.close()` と世代更新は `ArchiveMaterializationController.close()` を呼ぶ。
close は冪等で、要求をキャンセルし、draining task の終了と遅延結果の破棄を待つ。
その後、完成したコピーと文書ディレクトリ全体を background で削除する。
文書を閉じる同期処理は再帰削除を待たない。完了は `materializationCleanup` で待機できる。
新しい要求は closed controller から開始できない。
取消し・再試行は従来どおり別の UUID 領域で行う。

Open / Open With に渡したコピーも文書のキャッシュに含まれるので、文書の終了時に削除する。
初回 M1c の「文書終了後も公開済みコピーを次回起動まで残す」という契約は廃止した。
通常の Cmd-C の実ファイルは引き続き次回起動まで保持する。削除は当該文書に限り、
他文書や clipboard 用の領域には触れない。

> **Cache and disposal.** The document owns the materialization controller and
> worker. Completed items are cached independently of selection by the full stable
> payload, so fresh selection wrappers reuse completed files. Closing or releasing
> the panel preserves the document cache. Document closure and generation changes
> cancel and drain requests, discard late results, and asynchronously remove the
> completed files and document directory. Close is idempotent and blocks new work;
> its cleanup task is awaitable. Attempts still use independent UUID directories.
> This intentionally supersedes the original lifetime of preview/Open copies:
> they now last until document closure. Cmd-C copies retain their launch-sweep
> lifetime, and another document's files are preserved.

## 2. 起動時掃除を UI から分離

`applicationWillFinishLaunching` は `ExtractionTemporaryDirectory.startLaunchSweep()` を
呼んで直ちに document controller と menu の構築へ進む。削除処理は utility priority の
`Task.detached` が実行する。main actor ではディレクトリの列挙・再帰削除をしない。

単に background へ移すだけでは、新しい copy / preview と掃除が競合する。
`create()` の領域名を `process UUID prefix + attempt UUID` にし、起動時の sweep は
今回の prefix を持つ root 直下の領域を除外する。掃除の開始前でも開始後でも、今回の
プロセスが作った領域は残る。古い形式の UUID ディレクトリも掃除の対象になる。
NOFOLLOW、所有者・permission 検査、深さに依存しない fd 数の削除方式は維持した。

既存の同期 `sweepOnLaunch()` は全消去の helper として残る。文書終了時や fixture の掃除は
この helper を使い、本番の文書終了時の呼出しは `@concurrent` worker の内側で行う。
起動時は必ず、現在プロセスを除外する非同期の入口を使う。

> **Launch sweep.** Launch schedules a detached utility task and proceeds directly
> to menu/document-controller setup. Recursive deletion never runs on the main
> actor. A per-process UUID prefix excludes all newly created request directories,
> including those created while the background sweep is pending, preventing the
> asynchronous sweep from deleting active work. Legacy UUID directories remain
> eligible. Existing ownership, NOFOLLOW and bounded-descriptor cleanup rules are
> preserved. The synchronous full-cleanup helper remains available for fixtures
> and off-main document disposal; production launch uses the asynchronous entry.

## 3. 受動的選択は静かな表示にする

window の `updatePreviewSelection` は状態機械の同名の入口を使う。
フォルダ、暗号化、不完全、リンク・特殊項目、未対応方式を含む選択は空の preview selection
へ変換する。パネルを reload し、以前の要求を停止するが、`failed` callback は呼ばない。
受動的な選択変更中に worker で判明した失敗も alert を積まない。
Space / メニューの明示的操作は従来の readableSelection の理由通知を使い、
明示的な抽出要求に対する失敗通知も維持する。

> **Passive selection.** The window routes selection changes through the state
> machine's quiet preview-selection entry. Unsupported selections become an empty
> panel selection, cancelling old work without invoking the failure callback.
> Passive extraction failures also avoid modal alerts. Explicit Space/menu actions
> retain their capability alerts and explicit request failure reporting.

## 4. ロケールから独立した可否判定

`EntryReadCapability.refusal` は `Refusal?` で、directory / encrypted / incomplete /
linkOrSpecial / missingEntry / unsupportedMethod（raw method 名）/ invalidPath の enum。
`canPreview` と `canOpen` はこの値で決める。worker も型付き `Refusal` を throw する。
表示用の `reason` は別にローカライズし、テストは表示文字列の部分一致を一切使わない。

`testCapabilityDiscriminatorsWithForcedEnglishAndJapaneseLocalization` は
`Bundle(for: ArchiveDocument.self)` からアプリ自身のコンパイル済み `en.lproj` と
`ja.lproj` を取得し、`EntryReadCapability(..., bundle:)` へ明示的に渡す。
各言語で同じ enum と可否を assert する。表示文字列の検査はこの 1 件の non-empty のみ。
`Bundle.main` がテスト runner かアプリか、日本語 key が fallback されるかには依存しない。
実行時の preferred language は `ja-JP` だったが、このテスト内では英語と日本語を両方強制した。

> **Locale-independent capability.** Stable Refusal enum values drive capability
> flags and typed worker errors. Translated reasons are separate, and no assertion
> matches user-facing substrings. One test explicitly loads the application's
> compiled English and Japanese localization bundles and injects each into the
> capability initializer. It asserts the same refusal values/flags in both
> languages and, only in that test, checks messages are non-empty. It does not rely
> on Bundle.main being xctest or on untranslated Japanese fallback keys. The
> runner preferred ja-JP; both English and Japanese were forced inside the test.

## 回帰テスト

既存 67 件は削除していない。既存の capability tests は enum と typed error の比較へ修正した。
追加テストは次の 6 件。すべて `QuickLookOpenTests.swift`。

| XCTest | 確認内容 / Coverage |
|---|---|
| `testReturningToAnEntryAfterSelectionReplacementMaterializesOnce` | 新しい選択 wrapper で 0→1→0→1→0、実体化は [0, 1] だけ / selection replacement reuses cached files |
| `testDocumentCloseDeletesItsMaterializationsAndPreservesOtherOwners` | 実 NSDocument.close 後に文書 root が消え、別文書・clipboard のファイルは残る / scoped document cleanup |
| `testDocumentCleanupWaitsForCancelledWriterBeforeDeletingItsRoot` | stream 内の gate で停止し、取消し完了後だけ root を削除 / drain before deletion |
| `testLaunchSweepReturnsBeforeFinishingAndPreservesNewCopies` | worker を gate で停止しても main actor に戻れ、新しいコピーも残る / nonblocking launch and race prevention |
| `testPassiveNonPreviewableSelectionsNeverReportAnAlert` | 5 種の非対応行で空 selection、抽出なし、failed 0 回 / quiet passive navigation |
| `testCapabilityDiscriminatorsWithForcedEnglishAndJapaneseLocalization` | 実アプリの日英 bundle を注入し stable enum を比較 / forced localization independent of host shape |

起動時掃除のテストは速度閾値を使わない。`startLaunchSweep` の worker 内で
`Thread.isMainThread == false` を assert し、semaphore で止めたまま main actor に戻って
未完了であることを確認する。その間に新しいコピーを作り、gate の解放後に旧領域だけが
削除されることを assert する。終了時の削除も stream 内の gate を用い、競合を固定する。

> **Regression evidence.** Six tests are added without removing any of the 67
> existing tests. Existing capability tests now compare enums and typed errors.
> Gate-controlled tests verify main-actor responsiveness and drain-before-delete
> without relying on elapsed-time thresholds. The launch test also creates a new
> copy while cleanup is blocked and verifies only the previous run's data is
> removed.

## 実行と未検証範囲

作業領域内 cache の build/test オプションは M1a/M1b/M1c と同じ。
`build/m1c-fixes-clean-build.log` と `build/m1c-fixes-build.log` に成功ログを保存した。
`build/m1c-fixes-hosted-en.log` は次の hosted test の出力で、bundle のビルド後に
`com.apple.testmanagerd.control` への接続を拒否され、終了コード 133。

```sh
CFFIXED_USER_HOME="$PWD/build/User" \
XDG_CACHE_HOME="$PWD/build/Cache" \
CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache" \
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -IDEPackageSupportDisableManifestSandbox=YES \
  'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox' \
  -testLanguage en -testRegion US test
```

最終バンドルは直接 XCTest で実行した（終了コード 0）。

```sh
umask 022
env -i PATH=/usr/bin:/bin TMPDIR="$TMPDIR" \
  CFFIXED_USER_HOME="$PWD/build/User" \
  DYLD_INSERT_LIBRARIES="$PWD/build/DerivedData/Build/Products/Debug/KaitoFinder.app/Contents/MacOS/KaitoFinder.debug.dylib" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  "$PWD/build/DerivedData/Build/Products/Debug/KaitoFinder.app/Contents/PlugIns/KaitoFinderTests.xctest"
```

既存のサービス probe による skip は、folder provider 構築、名前付き pasteboard の 2 件、
Open With handler discovery の計 4 件。今回の 6 テストには skip を設けていない。
ユーザーの通常環境では `xcodebuild ... -testLanguage en -testRegion US test` による
73 件・0 skip の再確認が必要。Quick Look パネルの実際の空表示、クリック操作、外部アプリの
遅延読みと文書終了の見え方は GUI を操作できないため手動確認として残る。
今回も KaitoKit / GyoshukuKit には書き込んでおらず、push はしていない。

> **Execution limits.** Hosted testing with English selected is blocked by
> testmanagerd access. Direct execution of the final bundle succeeds. The four
> unchanged service skips cover folder-provider construction, two named-pasteboard
> tests and Open With handler discovery. None of the six new tests skips. A normal
> environment should rerun all 73 tests with English selected and no skips. Actual
> panel presentation and the effect of closing a document while an external app
> reads its temporary copy remain manual GUI checks. The engine repositories were
> not modified and nothing was pushed.

### clean build 末尾 / Clean build tail

```text
Validate /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Products/Debug/KaitoFinder.app (in target 'KaitoFinder' from project 'KaitoFinder')
    cd /Users/nagash/Github/KaitoFinder
    builtin-validationUtility /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Products/Debug/KaitoFinder.app -no-validate-extension -infoplist-subpath Contents/Info.plist

Touch /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Products/Debug/KaitoFinder.app (in target 'KaitoFinder' from project 'KaitoFinder')
    cd /Users/nagash/Github/KaitoFinder
    /usr/bin/touch -c /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Products/Debug/KaitoFinder.app

RegisterWithLaunchServices /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Products/Debug/KaitoFinder.app (in target 'KaitoFinder' from project 'KaitoFinder')
    cd /Users/nagash/Github/KaitoFinder
    builtin-lsregisterurl --record-path /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/XCBuildData/registered-launchservices.txt -- /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Products/Debug/KaitoFinder.app

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/SDKExplicitPrecompiledModules

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/ExplicitPrecompiledModules

** BUILD SUCCEEDED **

```

### 最終 bundle build 末尾 / Final bundle build tail

```text
PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/ExplicitPrecompiledModules

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/SDKExplicitPrecompiledModules

** TEST BUILD SUCCEEDED **

```

### hosted test 末尾 / Hosted test tail

```text
28  xcodebuild                          0x00000001028ff230 -[XcodebuildPreIDEHandler loadXcode3ProjectSupportAndRunXcode3CommandLineBuildToolWithArguments:] + 152
29  xcodebuild                          0x00000001028fd51c -[XcodebuildPreIDEHandler runWithArguments:] + 364
30  xcodebuild                          0x00000001028fd06c main + 476
31  dyld                                0x0000000194edbe80 start + 6688
2026-09-10 08:19:13.311 xcodebuild[59467:378867]  IDETestOperationsObserverDebug: Failure collecting logarchive: Error Domain=NSCocoaErrorDomain Code=4099 "The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction." UserInfo={NSDebugDescription=The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction.}
2026-09-10 08:19:13.313 xcodebuild[59467:378866] [MT] IDETestOperationsObserverDebug: 0.014 elapsed -- Testing started completed.
2026-09-10 08:19:13.314 xcodebuild[59467:378866] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start
2026-09-10 08:19:13.314 xcodebuild[59467:378866] [MT] IDETestOperationsObserverDebug: 0.014 sec, +0.014 sec -- end
```

### 最終 XCTest 末尾 / Final XCTest tail

```text
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLargeEntryUsesCopyThresholdAndProgressCancelRemovesOutput]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLargeEntryUsesCopyThresholdAndProgressCancelRemovesOutput]' passed (0.477 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLateSuccessfulResultAfterCloseIsDiscardedWithoutRefresh]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLateSuccessfulResultAfterCloseIsDiscardedWithoutRefresh]' passed (0.142 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLaunchSweepReturnsBeforeFinishingAndPreservesNewCopies]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLaunchSweepReturnsBeforeFinishingAndPreservesNewCopies]' passed (0.142 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testMaterializedFileIsReadOnlyAndPreservesQuarantine]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testMaterializedFileIsReadOnlyAndPreservesQuarantine]' passed (0.138 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testOpenWithDiscoveryForMaterializedTextWithLaunchServicesProbe]' started.
/Users/nagash/Github/KaitoFinder/KaitoFinderTests/QuickLookOpenTests.swift:388: -[KaitoFinderTests.QuickLookOpenTests testOpenWithDiscoveryForMaterializedTextWithLaunchServicesProbe] : Test skipped - この環境では LaunchServices が標準テキストの handler を解決できません
Test Case '-[KaitoFinderTests.QuickLookOpenTests testOpenWithDiscoveryForMaterializedTextWithLaunchServicesProbe]' skipped (0.001 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testPassiveNonPreviewableSelectionsNeverReportAnAlert]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testPassiveNonPreviewableSelectionsNeverReportAnAlert]' passed (0.139 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testPreviewItemHasLazyURLRealFilenameExtensionAndArchiveTitle]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testPreviewItemHasLazyURLRealFilenameExtensionAndArchiveTitle]' passed (0.139 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testProgressThresholdMatchesCopyForKnownUnknownAndBoundarySizes]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testProgressThresholdMatchesCopyForKnownUnknownAndBoundarySizes]' passed (0.000 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testReturningToAnEntryAfterSelectionReplacementMaterializesOnce]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testReturningToAnEntryAfterSelectionReplacementMaterializesOnce]' passed (0.139 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testSelectionChangeCancelsOldWriteAndOnlyRefreshesNewSelection]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testSelectionChangeCancelsOldWriteAndOnlyRefreshesNewSelection]' passed (0.143 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testSpaceKeyDownInvokesPreviewWithoutForceTouchAction]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testSpaceKeyDownInvokesPreviewWithoutForceTouchAction]' passed (0.011 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testUnsupportedZIPIsRefusedByMaterializerWithoutCreatingFile]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testUnsupportedZIPIsRefusedByMaterializerWithoutCreatingFile]' passed (0.137 seconds).
Test Suite 'QuickLookOpenTests' passed at 2026-09-10 08:22:00.689.
	 Executed 20 tests, with 1 test skipped and 0 failures (0 unexpected) in 2.460 (2.461) seconds
Test Suite 'KaitoFinderTests.xctest' passed at 2026-09-10 08:22:00.689.
	 Executed 73 tests, with 4 tests skipped and 0 failures (0 unexpected) in 15.271 (15.276) seconds
Test Suite 'All tests' passed at 2026-09-10 08:22:00.689.
	 Executed 73 tests, with 4 tests skipped and 0 failures (0 unexpected) in 15.271 (15.276) seconds
REFUSED [0] ../escape.txt: パスに .. 成分があります
REFUSED [2] a/../../deep.txt: パスに .. 成分があります
REFUSED [4] a\..\..\windows.txt: パスに .. 成分があります
WRITTEN: ["abs.txt", "ok.txt"]; PARENT UNCHANGED
TEMP ROOT: /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/KaitoFinder-ExtractionTests-D66DFAA8-93DA-4A1F-808A-ABE635792023/out; CANONICAL ROOT: /private/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/KaitoFinder-ExtractionTests-D66DFAA8-93DA-4A1F-808A-ABE635792023/out
DIRECTORY PROMOTIONS: 20000, elapsed: 0.29081325 seconds
CAPABILITY PREFERRED LANGUAGES: ja-JP
CAPABILITY LOCALIZATION: en, stable refusal cases verified
CAPABILITY LOCALIZATION: ja, stable refusal cases verified
```
