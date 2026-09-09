# M1c Quick Look / Open の検証（2026-09-10）

## 対象と結果

M1b の安全な展開経路に、単一項目の遅延実体化、Quick Look、Open / Open With を接続した。
開始時の HEAD は指定の `1871791` そのものではなく、その直後に M1b 検証記録の英訳を
同期した `d6ccce4` だった。その追補を保持して作業した。KaitoKit の変更、新しい依存、
書庫への書き込みはない。設計 §5 に今回の Quick Look 契約を追記した。

Xcode 27.0（27A266a）、macOS SDK 27、deployment target 26.0、arm64、Swift 6 strict
concurrency、MainActor 既定隔離、Approachable Concurrency を維持した。
作業領域内のキャッシュを使う **clean build は成功、Swift コンパイラ警告は 0 件**。
生成 dylib は `Mach-O 64-bit dynamically linked shared library arm64`。
AppIntents metadata の警告と Simulator 等の環境診断は残る。警告抑制は追加していない。

XCTest は生成した実アプリ dylib とテストバンドルを直接実行して、
**67 件、63 成功、4 skip、0 失敗**。既存 53 件は 50 成功・既存 probe による 3 skip。
追加 14 件は 13 成功・LaunchServices probe による 1 skip。
**既存 53 件をこの環境で全件実行できた、通常の xcodebuild test が成功した、または
実パネルと外部アプリの動作を確認したとは主張しない。**

> **Scope and result.** M1c connects lazy single-entry materialization, Quick Look,
> Open and Open With to M1b's safe extraction path. Actual starting HEAD was
> d6ccce4, the documentation-only English synchronization immediately following
> the requested 1871791; that addendum is preserved. No KaitoKit changes, new
> dependencies or archive writes are included. Design §5 now records the contract.
> The arm64 clean build succeeds with zero Swift compiler warnings under Swift 6
> strict concurrency, default MainActor isolation and Approachable Concurrency.
> AppIntents metadata and environment diagnostics remain. Direct execution of the
> generated app dylib and XCTest bundle reports 67 tests: 63 passed, four skipped,
> zero failures. The existing 53 contribute 50 passes and three existing service
> skips; the 14 additions contribute 13 passes and one LaunchServices skip.
> This does not claim all 53 existing tests ran here, normal xcodebuild test
> succeeded, or real panel/application integration was verified.

## API と実装契約

```swift
EntryReadCapability(entry:isDirectory:format:)
EntryReadCapability.canPreview / canOpen / reason
ArchiveSession.format: ArchiveFormat

@MainActor ArchivePreviewItem: NSObject, QLPreviewItem
ArchivePreviewItem.previewItemURL: URL?       // 未完了なら nil
ArchivePreviewItem.previewItemTitle: String? // 書庫内の raw path

actor EntryMaterializer
EntryMaterializer.init(session:temporaryDirectory:)
EntryMaterializer.materialize(_:progress:didWrite:) async throws -> URL
@concurrent EntryMaterializer.discard(_:) async

@MainActor ArchiveMaterializationController
ArchiveMaterializationController.init(materialize:)
ArchiveMaterializationController.setSelection(_:)
ArchiveMaterializationController.item(at:)
ArchiveMaterializationController.display(index:ready:)
ArchiveMaterializationController.cancel() / close()
ArchiveMaterializationController.started / finished / failed

@concurrent ExtractionService.extract(
    _:from:to:progress:promisedItem:readOnly:didWrite:didProcess:
) async throws -> ExtractionResult

ArchiveOutlineView.keyDown(with:)
ArchiveWindowController.acceptsPreviewPanelControl(_:)
ArchiveWindowController.beginPreviewPanelControl(_:)
ArchiveWindowController.endPreviewPanelControl(_:)
ArchiveWindowController.numberOfPreviewItems(in:)
ArchiveWindowController.previewPanel(_:previewItemAt:)
ArchiveWindowController.previewPanel(_:handle:)
ArchiveWindowController.togglePreviewPanel(_:)
ArchiveWindowController.openEntry(_:) / openWithEntry(_:)
ArchiveWindowController.menuNeedsUpdate(_:)

NSWorkspace.shared.open(_:)
NSWorkspace.shared.urlsForApplications(toOpen: URL)
NSWorkspace.shared.open(_:withApplicationAt:configuration:completionHandler:)
```

`ArchivePreviewItem` は bare NSURL ではなく独自の QLPreviewItem。URL getter と
`item(at:)` に抽出の副作用はない。全選択の件数と item を公開する一方、実体化開始は
`display(index:ready:)` だけ。パネルの先読み照会に含まれる index ではなく、
`currentPreviewItemIndex` を採用する。完了済み item は保持して戻る操作や Open に再利用する。

QLPreviewPanel に index 変更 delegate はないため、公開 index と可視状態を 50 ms 間隔で
照会し、data source callback の次の main-actor task でも同期する。KVO 通知の有無には
依存しない。通常の Space はカスタム NSOutlineView の `keyDown(with:)` で
`charactersIgnoringModifiers == " "` を判定する。`quickLookWithEvent:` は使わない。
SDK の NSObject カテゴリに隔離注釈がない三つの responder override だけは
`nonisolated` とし、AppKit の main-thread 呼出しを `MainActor.assumeIsolated` で受ける。

状態機械はパネル・NSWorkspace を参照しない。取消しは要求番号を更新し、Progress と
Task を取り消し、公開 callback を破棄する。次の reader は古い Task の終了を待ってから
起動し、solid 群の二つの reader を重ねない。既存の並列展開計測は設計根拠として採用し、
今回速度を再計測してはいない。read/write は `@concurrent` の worker 内で行う。
パネル側も完了時に所有 controller・可視状態・現在 index・item の同一性を再確認する。
選択変更・終了後の結果から stale な panel を refresh しない。

文書別 UUID ディレクトリの下に要求別 UUID ディレクトリを作り、実ファイル名と拡張子を
維持する。別の要求が同名でも衝突しない。実体化はすべて既存の
ExtractionService / ExtractionDestination を通し、パス検査・NOFOLLOW・quarantine を継承する。
読み取り専用オプションは通常ファイルだけを許し、元の属性を復元した後、公開前に同じ fd で
`fchmod(0400)` を適用する。通常の drag / copy / extract の権限方針は変えない。
途中取消しでは既存エンジンが部分ファイルを unlink し、worker が要求ディレクトリも削除する。
完成直後・UI 配送直前の取消しでも未公開の完成コピーを削除する。
公開済みコピーは外部アプリが遅延読みできるよう文書を閉じても残し、次回起動の既存 sweep で
掃除する。空の文書ディレクトリもその sweep が掃除する。

読み取り可否はメタデータだけで判定し、照会のために stream を開かない。
フォルダ、暗号化（M1 にパスワード入力はない）、isIncomplete、リンク・特殊項目、
既知の未対応方式を理由付きで拒否する。方式表は KaitoKit 0.3.0 の decoder と対応させた。
圧縮データ中で初めて判明する破損や追加制約は抽出時に既存の失敗報告へ渡す。
メニュー無効時は理由を tooltip にし、Space や action の直接実行では同じ失敗 alert で示す。

ファイルの double-click と Cmd-O は読み取り専用コピーを外部アプリで開く。
フォルダの double-click は展開／折りたたみ。書庫を選ぶ「開く…」は Cmd-Shift-O。
コンテキストメニューは右クリックした行を選び、「このアプリケーションで開く」サブメニューを
要求したときに一項目を実体化し、実 URL で handler を照会する。未作成 URL で結果を推測しない。
handler 取得中は説明行を出し、取得後に候補へ置換する。Open / Open With への移行では
プレビュー要求を取り消す。同じ item の完成コピーがあれば再利用する。
外部起動の失敗も既存の alert で報告する。

32 MiB 以上・サイズ不明・合計 overflow の方針は ArchiveCopyOut と共通。
既存の ExtractionProgressSheet を抽出前に表示し、Cancel は同じ Progress を取り消す。
シートの responder chain を文書へ戻す。文書下部に「読み取り専用の一時コピーであり、
変更は書庫に保存されない」ことを常時表示し、Open メニュー名にも明記した。
追加した UI 文字列は日英 xcstrings に登録した。

Apple の API 契約は SDK の QuickLookUI / AppKit ヘッダと
[Quick Look の現在項目と refresh](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel/currentpreviewitem)、
[NSWorkspace の URL handler 照会](https://developer.apple.com/documentation/appkit/nsworkspace/urlforapplication(toopen:)-7qkzf)
を参照した。API の存在・型の確認と、この環境で実 GUI を操作したという主張は区別する。

> **API and behavior.** The custom QLPreviewItem exposes the archive path as its
> title and a nil URL until materialization completes. Item enumeration has no
> side effects: only display(index:ready:) starts extraction. Completed items are
> reused when navigating back or opening the same item. The thin panel adapter
> uses currentPreviewItemIndex, never the index of a speculative data-source
> query, synchronizing through deferred callbacks and a 50 ms check of the public
> index/visibility properties without depending on KVO. Space is handled by
> keyDown, not the Force Touch selector. The three unannotated NSObject-category
> overrides bridge AppKit's main-thread calls using MainActor.assumeIsolated.
>
> The plain controller knows neither QLPreviewPanel nor NSWorkspace. Cancellation
> advances a request revision, cancels Progress and Task, and drops the publication
> callback. Successor work waits for the previous worker to stop, avoiding
> overlapping solid-group readers. The earlier performance measurements inform
> this policy; no new throughput benchmark was performed. The adapter separately
> checks panel ownership, visibility, current index and item identity before
> refreshing. Selection replacement and closure cannot publish stale results.
>
> Materialization preserves the real filename/extension beneath per-document and
> per-request UUID directories. Every payload write uses ExtractionService and
> ExtractionDestination, inheriting path validation, NOFOLLOW and quarantine.
> The read-only option only accepts regular files and applies fchmod(0400) on the
> same descriptor after archive attributes and before publication. Other extraction
> modes keep their existing permission policy. Cancellation removes the partial
> file and request directory; a late completed result is also discarded if never
> published. Published copies survive document closure for external readers until
> the existing next-launch sweep. Empty document directories share that policy.
>
> Capability checks use metadata without opening streams. Directories, encrypted
> entries without a password workflow, incomplete entries, links/special files and
> known unsupported methods have explicit reasons. Method tables match the current
> KaitoKit 0.3.0 decoders; errors only discoverable in payload data remain extraction
> failures. Disabled menus expose reasons as tooltips; direct actions and Space use
> the same failure alert. Double-click/Cmd-O open files, folder double-click toggles
> expansion, and Cmd-Shift-O selects an archive. Open With materializes one item
> when its submenu is requested, discovers handlers from the real URL and replaces
> its loading row asynchronously. Transitioning to Open/Open With cancels preview
> work and reuses an existing completed item where available. Launch failures are
> reported. The existing 32 MiB/unknown-size/overflow progress policy and Cancel
> sheet are reused. A persistent document notice and Open menu title explicitly
> identify a read-only temporary copy with no archive write-back.

## 追加 XCTest

すべて `KaitoFinderTests/QuickLookOpenTests.swift`。ZIP 入力は Python 標準 writer で生成する。
大きい項目は 40 MiB、通常項目は 512 KiB。取消しテストでは最初の 128 KiB 書き込み後に
同期 gate で止め、main actor から取り消してから解放する。read/write が main thread でない
ことも assert する。単なる事前取消しや、抽出速度の偶然による成功には依存しない。
late-result テストは書き込み完了と main actor への配送の間にも独立の停止点を置く。

| XCTest | 確認内容 / Coverage | 結果 |
|---|---|---|
| `testPreviewItemHasLazyURLRealFilenameExtensionAndArchiveTitle` | nil → 実 URL、実名・拡張子・raw path title・実内容 / URL transition, filename, title, bytes | pass |
| `testFiveRequestedItemsMaterializeOnlyCurrentIndexAndThenNext` | 5 item 照会で 0 回、index 0 で 1 回、index 1 で計 2 回、戻ると再利用、文書領域共有 / exact counts and reuse | pass |
| `testCancelDuringWriteRemovesPartialFileAndDoesNotRefresh` | 非空の部分ファイルから取消し、ファイル削除、refresh 0 / partial cleanup, no publication | pass |
| `testSelectionChangeCancelsOldWriteAndOnlyRefreshesNewSelection` | 古い選択の取消し、新しい選択だけ公開 / replacement policy | pass |
| `testClosingPreviewCancelsOldWriteWithoutTouchingStalePanel` | close 後は公開 0、旧ファイルなし / closure policy | pass |
| `testArrowDuringWriteCancelsPreviousIndexBeforeExtractingNext` | 書き込み中の index 移動、新項目だけ公開 / navigation during a write | pass |
| `testLateSuccessfulResultAfterCloseIsDiscardedWithoutRefresh` | 完成と配送の競合でもファイル回収、refresh 0 / late-success race | pass |
| `testLargeEntryUsesCopyThresholdAndProgressCancelRemovesOutput` | 40 MiB の進捗開始、Progress.cancel、後始末 / shared progress and cancellation | pass |
| `testMaterializedFileIsReadOnlyAndPreservesQuarantine` | POSIX mode 0400、通常ファイル、quarantine と内容 / disk permissions and bytes | pass |
| `testDirectoriesEncryptedIncompleteAndUnsupportedEntriesReportReasonsWithoutExtraction` | 理由付き拒否、抽出・公開 0、通常ファイルは許可 / capability and reporting | pass |
| `testUnsupportedZIPIsRefusedByMaterializerWithoutCreatingFile` | 実 ZIP の method 93 を拒否 / actual unsupported ZIP fixture | pass |
| `testProgressThresholdMatchesCopyForKnownUnknownAndBoundarySizes` | 32 MiB 境界の上下・不明サイズ / threshold boundary | pass |
| `testSpaceKeyDownInvokesPreviewWithoutForceTouchAction` | 合成 Space を custom keyDown に直接渡す / direct key handler | pass |
| `testOpenWithDiscoveryForMaterializedTextWithLaunchServicesProbe` | 実 txt URL の default と handler 配列 / real handler discovery | skip |

> **Tests.** The 14 additions use generated ZIP fixtures and actual extraction.
> Deterministic gates pause after the first 128 KiB write so cancellation acts on
> a real nonempty partial file, with assertions that I/O runs off the main thread.
> A separate completion gate covers the late-success delivery race. These tests do
> not rely on pre-cancellation or fast extraction accidentally finishing first.
> The table records exact counts, state changes, on-disk cleanup, permission bits,
> quarantine, bytes, refusal reasons and direct keyboard routing. The single new
> service-dependent case probes handler discovery without launching any app.

## サービス probe と未検証事項

新しい LaunchServices テストは、まず標準の `UTType.plainText` に対する default app を
照会する。この環境では nil のため XCTSkip。probe 成功後は実体化した txt の URL を使い、
default app が存在すること、handler 配列が非空で default を含むこと、各 app URL が
ディスクに存在することを assert する。空配列や false の conformance を成功扱いにしない。
他の追加 13 件は LaunchServices・pasteboard・実パネルの有無に依存しない。
既存の folder provider と名前付き pasteboard 2 件の probe は変更していない。
**skip は上表のロジック検証を代替していない。** サービスのある環境で全 67 件・0 skip を
再実行する必要がある。この作業では pasteboard.general の変更や他アプリの起動をしていない。

**実 Quick Look パネルの挙動と実 Open With は、この環境では検証できなかった。**
指定された画面収録・Accessibility・System Events の制約に従い、GUI 自動操作は試していない。
次は通常環境での手動確認として残す。

1. Space で表示／閉じる、実 QL renderer の nil URL → refresh、ファイル形式ごとの表示とタイトル。
2. 複数選択の矢印移動、連続移動、パネル内のナビゲーション UI、Escape／閉じる／orderOut、
   抽出中の選択変更、別文書への controller 引継ぎと終了後の refresh 抑止。
3. 実 responder routing による Cmd-O、double-click、フォルダの展開／折りたたみ、
   右クリックした行の選択、Open With の非同期候補表示と候補クリック、外部アプリの実起動。
4. 32 MiB 以上の項目での進捗シート表示、UI 応答性、ボタンの Cancel と sheet/QL の所有権。
   自動検証した Progress の停止と、画面上のボタンを押した検証は区別する。
5. 外部アプリでの読み取り専用コピーの表示・保存動作、文書下部の説明の視認性、
   文書を閉じた後の外部アプリの遅延読み、quarantine に対する実 Gatekeeper の対応。
6. 新しい 67 件を LaunchServices / pasteboard / testmanagerd が動く環境で再実行し、
   0 skip・0 failure を確認する。実 solid 7z の操作感と性能は今回未計測。

> **Probes and limits.** The new integration test first asks LaunchServices for a
> default app for the standard plainText type and skips only when that probe fails.
> After a successful probe, it requires a real materialized text URL's default app,
> a nonempty handler list containing that default, and existing application URLs.
> Empty results or universally false conformance are never treated as success.
> The other 13 additions are independent of LaunchServices, pasteboards and an
> actual panel. Existing service probes remain unchanged; skips do not substitute
> for any logic acceptance test. A service-enabled rerun must still demonstrate
> all 67 tests with zero skips. No general pasteboard write or external app launch
> was performed in these tests.
>
> Real Quick Look panel behavior and real Open With could not be verified here.
> No GUI automation was attempted under the stated recording/accessibility/System
> Events limits. Manual checks remain for renderer refresh/title, Space and arrow
> navigation, rapid selection/closure and document handoff, real responder routing,
> folder expansion, contextual selection, asynchronously populated handler menus,
> actual app launches, progress presentation/button clicks and responsiveness,
> sheet/panel ownership, external-app read-only/save behavior, notice visibility,
> delayed reads after closing the document, Gatekeeper and real solid-7z performance.
> Automated Progress cancellation is distinct from clicking a real Cancel button.

## 実行コマンドと末尾出力

指定コマンドは全出力を保存し、末尾を下に掲載した（パイプの tail が失敗コードを隠さない
よう xcodebuild の終了コードを別途確認）。build と test はともに終了コード 74。
既定の ModuleCache / SwiftPM manifest cache が書き込み許可外のため、依存解決で失敗した。

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' build
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' test
```

作業領域内キャッシュの clean build は終了コード 0。同じ設定の test はテストバンドルを
生成した後、testmanagerd.control と分散通知の sandbox 制限で終了コード 133。
Swift コンパイル警告は build / test とも 0。直接 XCTest 実行は終了コード 0。
`-disable-sandbox` は Swift の子プロセス用であり、この実行環境の制限は維持される。

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
  'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox' clean build
# 同じ設定で末尾を test にした実行も記録した。

umask 022
env -i PATH=/usr/bin:/bin TMPDIR="$TMPDIR" \
  CFFIXED_USER_HOME="$PWD/build/User" \
  DYLD_INSERT_LIBRARIES="$PWD/build/DerivedData/Build/Products/Debug/KaitoFinder.app/Contents/MacOS/KaitoFinder.debug.dylib" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  "$PWD/build/DerivedData/Build/Products/Debug/KaitoFinder.app/Contents/PlugIns/KaitoFinderTests.xctest"
```

全ログは `build/m1c-requested-build.log`、`build/m1c-requested-test.log`、
`build/m1c-build.log`、`build/m1c-test.log`、`build/m1c-xctest.log`（git 管理外）。

> **Commands.** Requested build/test both exit 74 because default caches are outside
> writable roots. Workspace-local clean build exits 0 with zero Swift warnings.
> The equivalent test command builds the test bundle, then exits 133 on denied
> testmanagerd/distributed-notification access. Direct XCTest exits 0. Full logs are
> retained under build/; exact tails follow. These outcomes are deliberately
> distinguished from a successful normal xcodebuild test run.

### 指定 build — 末尾 20 行 / Requested build

```text
2026-09-10 07:13:49.681 xcodebuild[40173:261084]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult, NSUnderlyingError=0x7609730f60 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}
2026-09-10 07:13:49.681 xcodebuild[40173:261084]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult, NSUnderlyingError=0x7609731980 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}

Package: kaitokit

Package: unknown

2026-09-10 07:13:49.771 xcodebuild[40173:261049] Writing error result bundle to /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/ResultBundle_2026-10-09_07-13-0049.xcresult
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)

```

### 指定 test — 末尾 40 行 / Requested test

```text
[-[SimDiskImageManager _onQueue_checkConnection:]:219] ERROR : simdiskimaged connection is currently unavailable because connection became invalid
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
    request = "notification_subscription";
    "set_path" = "/Users/nagash/Library/Developer/CoreSimulator/Devices";
}) because we are not connected to CoreSimulatorService.
2026-09-10 07:13:56.721 xcodebuild[40222:261266] Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedDescription=CoreSimulatorService connection became invalid.  Simulator services will no longer be available.}
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
    request = "notification_subscription";
    "set_path" = "/Users/nagash/Library/Developer/CoreSimulator/Devices";
}) because we are not connected to CoreSimulatorService.
2026-09-10 07:13:56.721 xcodebuild[40222:261239] Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedDescription=CoreSimulatorService connection became invalid.  Simulator services will no longer be available.}
2026-09-10 07:13:56.721 xcodebuild[40222:261266]  iOSSimulator: [SimServiceContext defaultDeviceSetWithError:] returned nil (Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedFailureReason=Failed to subscribe to notifications from CoreSimulatorService., NSLocalizedDescription=Failed to initialize simulator device set., NSUnderlyingError=0x7c7bb18b10 {Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedDescription=CoreSimulatorService connection became invalid.  Simulator services will no longer be available.}}}). Simulator device support disabled.
2026-09-10 07:13:56.722 xcodebuild[40222:261239]  IDESimulatorAvailability: startObservingSimulatorUpdates() FAILED to register SimDeviceSet observer
Resolve Package Graph
2026-09-10 07:13:56.838 xcodebuild[40222:261266]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-53-29-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-53-29-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-53-29-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-53-29-+0900.xcresult, NSUnderlyingError=0x7c7bb19b00 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}
2026-09-10 07:13:56.838 xcodebuild[40222:261266]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-52-52-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-52-52-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-52-52-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-52-52-+0900.xcresult, NSUnderlyingError=0x7c7bb19c20 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}
2026-09-10 07:13:56.841 xcodebuild[40222:261266]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult, NSUnderlyingError=0x7c7bb19200 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}
2026-09-10 07:13:56.842 xcodebuild[40222:261266]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult, NSUnderlyingError=0x7c7bb19b30 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}

Package: kaitokit

Package: unknown

2026-09-10 07:13:56.931 xcodebuild[40222:261238] Writing error result bundle to /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/ResultBundle_2026-10-09_07-13-0056.xcresult
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)

```

### 作業領域内 clean build — 末尾 20 行 / Workspace-local clean build

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

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/ExplicitPrecompiledModules

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/SDKExplicitPrecompiledModules

** BUILD SUCCEEDED **

```

### 作業領域内 test — 末尾 40 行 / Workspace-local test

```text
OS Version:    26A428
Application:   xcodebuild

Backtrace:
0   CoreFoundation                      0x00000001954dee90 __CFGenerateReport + 244
1   CoreFoundation                      0x000000019542e850 _CFXNotificationPostXPC + 768
2   CoreFoundation                      0x00000001953332d8 _CFXNotificationPost + 440
3   Foundation                          0x0000000196add49c -[NSDistributedNotificationCenter postNotificationName:object:userInfo:options:] + 108
4   IDEFoundation                       0x000000010dbd3548 -[IDETestProgressNotificationsObserver _considerPostingDistributedNotification] + 860
5   IDEFoundation                       0x000000010dbd7aec -[IDETestRunSession worker:forTestTargetRunner:willFinishWithResult:] + 308
6   XCTHarness                          0x000000010bc7adc0 -[XCTHTestTargetRunner testRunner:willFinishWithResult:] + 468
7   XCTHarness                          0x000000010bc7645c -[XCTHTestRunner willFinishWithResult:sessionState:] + 1404
8   XCTHarness                          0x000000010bc69d38 __63-[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:]_block_invoke_2 + 300
9   XCTHarness                          0x000000010bc6a5ec -[XCTHTestOperationCoordinator _considerDispatchingDelegateBlock] + 764
10  XCTHarness                          0x000000010bc6a828 -[XCTHTestOperationCoordinator _unconditionallyEnqueueDelegateBlock:consumingConsole:] + 196
11  XCTHarness                          0x000000010bdb40a8 -[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:].cold.1 + 308
12  XCTHarness                          0x000000010bc69bd8 -[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:] + 192
13  XCTHarness                          0x000000010bc69a14 __81-[XCTHTestOperationCoordinator _tearDownLoggingAndReportFinishToRunnerWithError:]_block_invoke_2 + 36
14  libdispatch.dylib                   0x00000001950f0a34 _dispatch_call_block_and_release + 32
15  libdispatch.dylib                   0x000000019510a5a0 _dispatch_client_callout + 16
16  libdispatch.dylib                   0x0000000195128998 _dispatch_main_queue_drain.cold.6 + 832
17  libdispatch.dylib                   0x00000001950ffb0c _dispatch_main_queue_drain + 176
18  libdispatch.dylib                   0x00000001950ffa4c _dispatch_main_queue_callback_4CF + 44
19  CoreFoundation                      0x00000001953af9cc __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__ + 16
20  CoreFoundation                      0x000000019537165c __CFRunLoopRun + 1980
21  CoreFoundation                      0x000000019544b82c _CFRunLoopRunSpecificWithOptions + 536
22  CoreFoundation                      0x00000001953e94c4 CFRunLoopRun + 64
23  Xcode3Core                          0x0000000109257778 -[Xcode3CommandLineBuildTool waitForBuildWithBuildLog:buildActionTimingSection:executionEnvironment:title:operationToEnqueue:error:] + 600
24  Xcode3Core                          0x000000010925809c -[Xcode3CommandLineBuildTool doBuildForBuildAction:timingSection:colorize:colorizeFailure:error:] + 1152
25  Xcode3Core                          0x0000000109258db4 -[Xcode3CommandLineBuildTool _buildWithTimingSection:] + 700
26  Xcode3Core                          0x0000000109264c54 -[Xcode3CommandLineBuildTool run] + 4864
27  libxcodebuildLoader.dylib           0x00000001023814bc XcodeBuildMain + 608
28  xcodebuild                          0x0000000102273230 -[XcodebuildPreIDEHandler loadXcode3ProjectSupportAndRunXcode3CommandLineBuildToolWithArguments:] + 152
29  xcodebuild                          0x000000010227151c -[XcodebuildPreIDEHandler runWithArguments:] + 364
30  xcodebuild                          0x000000010227106c main + 476
31  dyld                                0x0000000194edbe80 start + 6688
2026-09-10 07:15:47.371 xcodebuild[40925:264188]  IDETestOperationsObserverDebug: Failure collecting logarchive: Error Domain=NSCocoaErrorDomain Code=4099 "The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction." UserInfo={NSDebugDescription=The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction.}
2026-09-10 07:15:47.373 xcodebuild[40925:264158] [MT] IDETestOperationsObserverDebug: 0.013 elapsed -- Testing started completed.
2026-09-10 07:15:47.373 xcodebuild[40925:264158] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start
2026-09-10 07:15:47.373 xcodebuild[40925:264158] [MT] IDETestOperationsObserverDebug: 0.013 sec, +0.013 sec -- end
```

### 直接 XCTest — 末尾 40 行 / Direct XCTest

```text
Test Case '-[KaitoFinderTests.QuickLookOpenTests testArrowDuringWriteCancelsPreviousIndexBeforeExtractingNext]' passed (0.082 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testCancelDuringWriteRemovesPartialFileAndDoesNotRefresh]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testCancelDuringWriteRemovesPartialFileAndDoesNotRefresh]' passed (0.138 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testClosingPreviewCancelsOldWriteWithoutTouchingStalePanel]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testClosingPreviewCancelsOldWriteWithoutTouchingStalePanel]' passed (0.150 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testDirectoriesEncryptedIncompleteAndUnsupportedEntriesReportReasonsWithoutExtraction]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testDirectoriesEncryptedIncompleteAndUnsupportedEntriesReportReasonsWithoutExtraction]' passed (0.000 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testFiveRequestedItemsMaterializeOnlyCurrentIndexAndThenNext]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testFiveRequestedItemsMaterializeOnlyCurrentIndexAndThenNext]' passed (0.137 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLargeEntryUsesCopyThresholdAndProgressCancelRemovesOutput]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLargeEntryUsesCopyThresholdAndProgressCancelRemovesOutput]' passed (0.418 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLateSuccessfulResultAfterCloseIsDiscardedWithoutRefresh]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testLateSuccessfulResultAfterCloseIsDiscardedWithoutRefresh]' passed (0.140 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testMaterializedFileIsReadOnlyAndPreservesQuarantine]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testMaterializedFileIsReadOnlyAndPreservesQuarantine]' passed (0.137 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testOpenWithDiscoveryForMaterializedTextWithLaunchServicesProbe]' started.
/Users/nagash/Github/KaitoFinder/KaitoFinderTests/QuickLookOpenTests.swift:388: -[KaitoFinderTests.QuickLookOpenTests testOpenWithDiscoveryForMaterializedTextWithLaunchServicesProbe] : Test skipped - この環境では LaunchServices が標準テキストの handler を解決できません
Test Case '-[KaitoFinderTests.QuickLookOpenTests testOpenWithDiscoveryForMaterializedTextWithLaunchServicesProbe]' skipped (0.001 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testPreviewItemHasLazyURLRealFilenameExtensionAndArchiveTitle]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testPreviewItemHasLazyURLRealFilenameExtensionAndArchiveTitle]' passed (0.134 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testProgressThresholdMatchesCopyForKnownUnknownAndBoundarySizes]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testProgressThresholdMatchesCopyForKnownUnknownAndBoundarySizes]' passed (0.000 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testSelectionChangeCancelsOldWriteAndOnlyRefreshesNewSelection]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testSelectionChangeCancelsOldWriteAndOnlyRefreshesNewSelection]' passed (0.157 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testSpaceKeyDownInvokesPreviewWithoutForceTouchAction]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testSpaceKeyDownInvokesPreviewWithoutForceTouchAction]' passed (0.012 seconds).
Test Case '-[KaitoFinderTests.QuickLookOpenTests testUnsupportedZIPIsRefusedByMaterializerWithoutCreatingFile]' started.
Test Case '-[KaitoFinderTests.QuickLookOpenTests testUnsupportedZIPIsRefusedByMaterializerWithoutCreatingFile]' passed (0.142 seconds).
Test Suite 'QuickLookOpenTests' passed at 2026-09-10 07:16:45.997.
	 Executed 14 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.648 (1.649) seconds
Test Suite 'KaitoFinderTests.xctest' passed at 2026-09-10 07:16:45.997.
	 Executed 67 tests, with 4 tests skipped and 0 failures (0 unexpected) in 13.722 (13.726) seconds
Test Suite 'All tests' passed at 2026-09-10 07:16:45.997.
	 Executed 67 tests, with 4 tests skipped and 0 failures (0 unexpected) in 13.722 (13.727) seconds
REFUSED [0] ../escape.txt: パスに .. 成分があります
REFUSED [2] a/../../deep.txt: パスに .. 成分があります
REFUSED [4] a\..\..\windows.txt: パスに .. 成分があります
WRITTEN: ["abs.txt", "ok.txt"]; PARENT UNCHANGED
TEMP ROOT: /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/KaitoFinder-ExtractionTests-2B952561-2839-4C7D-9B35-DF33585D3139/out; CANONICAL ROOT: /private/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/KaitoFinder-ExtractionTests-2B952561-2839-4C7D-9B35-DF33585D3139/out
DIRECTORY PROMOTIONS: 20000, elapsed: 0.266120542 seconds
```

## ローカルコミットの実行制限

実装と検証後に `git add` を実行したが、`.git/index.lock` の作成を sandbox に拒否された
（終了コード 128）。このセッションでは `.git` が読み取り専用のため、ステージングと
ローカルコミットは未完了。push はしていない。指定の日本語コミットメッセージと末尾の
Co-Authored-By / Claude-Session は `build/m1c-commit-message.txt` に保存した。

```text
fatal: Unable to create '/Users/nagash/Github/KaitoFinder/.git/index.lock': Operation not permitted
```

書き込み可能なセッションでの残作業:

```sh
git add Documentation/design.md Documentation/verification/2026-09-10-quicklook-open.md KaitoFinder KaitoFinderTests/QuickLookOpenTests.swift
git commit -F build/m1c-commit-message.txt
```

> **Commit limitation.** After implementation and verification, git add exited 128
> because the sandbox denied creation of .git/index.lock. The repository metadata
> is read-only in this session, so staging and the requested local commit remain
> unfinished. Nothing was pushed. The Japanese commit message, including the exact
> requested Co-Authored-By and Claude-Session trailers, is saved in
> build/m1c-commit-message.txt. The commands above complete the remaining step in a
> session that can write repository metadata.

## コーディネーターによる再実行(2026-09-10)

LaunchServices と pasteboard サービスが利用できる環境で `xcodebuild test` を
実行した結果、**67 件・0 skip・0 失敗**、Swift 警告 0 だった。

```
Executed 67 tests, with 0 failures (0 unexpected) in 11.861 (11.882) seconds
** TEST SUCCEEDED **
```

sandbox で probe により skip されていた 4 件は、いずれも実行されて成功した。

| テスト | 結果 |
|---|---|
| `testLargeEntryUsesCopyThresholdAndProgressCancelRemovesOutput` | passed (0.497 s) |
| `testMaterializedFileIsReadOnlyAndPreservesQuarantine` | passed (0.071 s) |
| `testOpenWithDiscoveryForMaterializedTextWithLaunchServicesProbe` | passed (0.071 s) |
| `testSpaceKeyDownInvokesPreviewWithoutForceTouchAction` | passed (0.008 s) |

実 Quick Look パネルの表示、実 Open With による外部起動、responder routing、
進捗シートの操作感、solid 7z での体感は、この環境でも画面収録と
アクセシビリティが塞がれているため**依然として手動確認が必要**である。

> **Coordinator rerun (2026-09-10).** Run in an environment where LaunchServices
> and the pasteboard services are available, `xcodebuild test` reported 67 tests,
> zero skips, zero failures and zero Swift compiler warnings. The four cases the
> sandbox had skipped behind service probes all ran and passed. Real Quick Look
> panel presentation, real Open With launching, responder routing, the feel of the
> progress sheet and behaviour on a solid 7z still require manual checking,
> because screen recording and accessibility are blocked here too.
