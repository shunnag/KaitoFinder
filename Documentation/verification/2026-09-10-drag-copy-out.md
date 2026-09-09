# M1b drag / copy out の検証（2026-09-10）

## 追補: サービス利用可能な環境で見つかった 2 件の修正

基準コミットは `e626bbb`。コーディネーターが LaunchServices と名前付き pasteboard
を利用できる環境で全 53 テストを再実行したところ、2 件が失敗した。
初回 sandbox 実行の「50 成功、3 skip」は、正常なサービス上での正しさの証明では
なかった。以下に提供された実測と今回の修正を記録する。

- `testInvalidPromiseTypeFallsBackToData` の期待値を訂正した。`public.url` は
  `public.data` に準拠するため、`validatedType(.url)` が `.url` を返すのが正しい。
  無効型の検証には data/directory のどちらにも準拠しない `.item` を使い、
  `.item -> .data`、`.folder -> .folder`、`.data -> .data` を assert する。
  この三つの期待値は LaunchServices の有無で変わらない。
  `ArchiveFilePromise.validatedType` の実装は変更していない。
- `ArchiveCopyOut.copy` は、各 pasteboard item の `.string` にその項目自身の
  書庫内パスだけを設定する。先頭 item へ全選択の文字列を入れる処理を削除した。
  pasteboard 全体の string 読み出しは各 item の文字列を連結するため、先頭に全体を
  入れると後続パスが二重になる。
- `testCopyPublishesExistingRealURLsAndPlainTextOnNamedPasteboard` は同じテスト内で
  2 項目と 3 項目の選択を検証する。集約文字列だけでなく各 item の `.string` と
  `.fileURL`、件数と順序、読み戻した実ファイルの内容、promise metadata がないことを
  assert する。テスト数は 53 件のまま、既存の 3 個の XCTSkip probe も維持する。

コーディネーターが報告した修正前の実出力:

```text
testInvalidPromiseTypeFallsBackToData
XCTAssertEqual failed: ("public.url") is not equal to ("public.data")

testCopyPublishesExistingRealURLsAndPlainTextOnNamedPasteboard
XCTAssertEqual failed: ("folder\nother.txt\nother.txt") is not equal to ("folder\nother.txt")

** TEST FAILED **
53 tests, 2 failures
```

名前付き pasteboard のテストは「どの環境でも未実行」ではない。
サービスのある環境で実行され、取消し時の元の文字列・changeCount・fileURL 非公開を
確認するテストと実 folder provider のテストは、コーディネーターの報告では成功した。
公開テストは実 URL とテキストを読み戻し、文字列の二重掲載という実装上の欠陥を検出した。
修正後の 2 項目・3 項目の期待値はそれぞれ `folder\nother.txt` と
`folder\nother.txt\nthird.txt` である。

**確認済み(2026-09-10)。** 修正後の作業ツリーを、LaunchServices と pasteboard
サービスが利用できる環境で `xcodebuild test` にかけた結果は次のとおり。

```
Executed 53 tests, with 0 failures (0 unexpected) in 10.287 (10.302) seconds
** TEST SUCCEEDED **
```

- XCTest の skip は **0 件**(`Test Case .* skipped` の一致数 0)。
- Swift コンパイラ警告は **0 件**。
- sandbox で skip されていた 3 件と、誤った前提で通っていた 1 件は、いずれも実行され
  成功した。

| テスト | 結果 |
|---|---|
| `testFolderProviderUsesFolderUTI` | passed (0.068 s) |
| `testCopyPublishesExistingRealURLsAndPlainTextOnNamedPasteboard` | passed (0.136 s) |
| `testCancelledCopyPreservesPasteboardWithoutPartialURLs` | passed (0.717 s) |
| `testInvalidPromiseTypeFallsBackToData` | passed (0.001 s) |

後段の初回実行表・ログは履歴として保持する。

> **Confirmed (2026-09-10).** The corrected tree was rerun with LaunchServices and
> pasteboard services available: `Executed 53 tests, with 0 failures (0 unexpected)`,
> `** TEST SUCCEEDED **`, zero XCTest skips and zero Swift compiler warnings. The
> three cases the sandbox had skipped, and the one that had passed on a false
> premise, all ran and passed.
>
> **Two corrections following a service-enabled run.** The coordinator reran all
> 53 tests on e626bbb with LaunchServices and pasteboard services available and
> reported two failures. public.url conforms to public.data, so the production
> validator was correct. The invalid-type test now uses public.item and retains
> the folder/data cases; all three assertions have the same expected values with
> or without LaunchServices. The validator implementation is unchanged.
> Copy-out now assigns only each item's own path to its string representation.
> The pasteboard's aggregate read then joins every selected path exactly once.
> The existing publication test covers both two and three items, checking aggregate
> text, per-item strings and URLs, order, counts, file contents and absence of
> promise metadata. All three existing service probes remain; the suite still
> contains 53 tests. These integration tests did run outside the sandbox: the
> cancellation-preservation and folder-provider tests passed in the coordinator's
> report, while publication caught a real duplication bug. The coordinator
> subsequently confirmed the corrected two- and three-item cases and all 53 tests
> passing with zero skips in the service-enabled environment, as recorded above.
> Historical sandbox results remain below.

## 対象と結果

M1a の展開エンジンに、世代付きの項目識別、file promise による drag out、
事前展開による copy out、取り出しメニューと進捗シートを接続した。
書庫への書き込み、Quick Look、KaitoKit の変更は含まない。
2026-09-09 の pasteboard 検証結果は設計の前提として採用し、再検証していない。
Copy に promise や遅延 data provider は使用しない。

Xcode 27.0（27A266a）、macOS SDK 27、deployment target 26.0、arm64、Swift 6 strict
concurrency、MainActor 既定隔離と Approachable Concurrency を維持した。
作業領域内のキャッシュを使った **clean build は成功、Swift コンパイル警告は 0 件**。
生成された dylib は `Mach-O 64-bit dynamically linked shared library arm64`。
Xcode の AppIntents metadata 警告と Simulator 等の環境診断は残る。警告抑制は追加していない。

初回の sandbox 内で XCTest を実アプリ dylib とともに直接実行した結果は
**53 件、50 成功、3 skip、0 失敗**（この結果の限界と後日の実測は上の追補を参照）。
既存 35 件はすべて成功した。追加 18 件のうち 15 件が成功した。
3 件の skip は名前付き pasteboard 2 件と、LaunchServices を必要とするフォルダ
provider 構築 1 件。**全 acceptance criteria がこの環境で実証済み、とは主張しない。**

> **Scope and result.** M1b connects generation-aware identity, drag-out promises,
> eager copy-out, extraction commands and a progress sheet to M1a. Archive writing,
> Quick Look and KaitoKit changes are excluded. The measured pasteboard facts are
> accepted without retesting; copying uses neither promises nor lazy providers.
> The arm64 clean build succeeds with zero Swift compiler warnings under Swift 6
> strict concurrency, default MainActor isolation and Approachable Concurrency.
> Xcode metadata and environment diagnostics remain. Direct XCTest execution
> against the app dylib reports 53 tests: 50 passed, three skipped, zero failures.
> All 35 existing tests pass. The skipped cases require named pasteboard access
> or LaunchServices folder-type resolution. This is not a claim that every
> acceptance criterion has been demonstrated in this environment.

## API と実装契約

```swift
ArchiveEntryPayload(
    archiveURL: URL, generation: UInt64, entryIndex: Int?,
    path: String, isDirectory: Bool
)
@MainActor ArchiveEntryPayload(node: EntryNode, archiveURL: URL, generation: UInt64)

ArchiveSession.generation: UInt64
ArchiveSession.snapshot() -> (entries: [ArchiveEntry], generation: UInt64)
ArchiveSession.reloadAfterMutation() throws
ArchiveDocument.generation: UInt64
ArchiveDocument.reloadAfterMutation() async throws

@MainActor ArchiveFilePromise(payload: ArchiveEntryPayload, session: ArchiveSession,
                              progress: Progress, finished: @Sendable () -> Void)
ArchiveFilePromise.makeProvider() throws -> NSFilePromiseProvider
ArchiveFilePromise.operationQueue(for:) -> OperationQueue
nonisolated ArchiveFilePromise.filePromiseProvider(
    _:writePromiseTo:completionHandler:
)

@MainActor FilePromiseRegistry.register(payload:session:owner:now:)
FilePromiseRegistry.began(sessionID:promises:)
FilePromiseRegistry.beganPending(sessionID:owner:)
FilePromiseRegistry.ended(sessionID:now:)
FilePromiseRegistry.sweep(now:)

@concurrent ExtractionService.extract(
    _ payloads: [ArchiveEntryPayload], from: ArchiveSession, to: URL,
    progress: Progress, promisedItem: ArchiveEntryPayload? = nil,
    didProcess: (@Sendable (Int) -> Void)? = nil
) async throws -> ExtractionResult

@concurrent ArchiveCopyOut.prepare(
    _:from:progress:temporaryDirectory:didProcess:
) async throws -> ArchiveCopyOut.Prepared
@MainActor ArchiveCopyOut.copy(
    _:from:to:progress:temporaryDirectory:didProcess:
) async throws -> [URL]
```

上記は呼び出し形の一覧。`EntryNode.path` は仮想フォルダにも書庫内パスを与える。
実 entry の raw name は従来どおり保持する。仮想フォルダの `entryIndex` は nil。
表示時の一覧と世代を同じ snapshot から取得し、その世代を payload に固定する。

将来の書庫変更後は `ArchiveDocument.reloadAfterMutation()` を呼ぶ契約。
session は世代を進めて URL から reader を開き直す。`reopen()` で旧 inode を継承しない。
開き直しに失敗しても世代は進み、旧 reader による展開は拒否される。
世代が違うファイルは raw path で再解決し、不在・同名複数ならエラー。
フォルダは現在の部分木を選ぶ。解決と専用 reader の `reopen()` の間には await がなく、
同じ世代の entry、reader、quarantine が一組で worker に渡る。
実際の archive mutation / atomic replace の実装は M2 の範囲である。

Drag は `outlineView(_:pasteboardWriterForItem:)` が行ごとに provider を返す。
外部・ローカルの source operation mask は `.copy` だけ。
フォルダの型は `UTType.folder.identifier`、ファイルの拡張子由来の型は data/directory
への conformance を検査し、不適切なら `.data`。型サービスが必要な型を解決できない場合は
provider 構築前に Swift のエラーにする。

フォルダの promise は一つの URL にディレクトリを作り、その中へ部分木を相対配置する。
選択フォルダの祖先を重ねて作らない。単一ファイルは受け側が渡す名前の URL に書く。
どちらも一 reader・一出力 root・書庫順で、hard link の検証にも同じパス対応を使う。
明示フォルダ entry の属性は root に子より後で適用する。
不正な子のパスは黙って除外せず、M1a の拒否結果を promise の失敗へ変換する。
既存項目は上書きしない。フォルダの途中失敗・取消しでは、完了済みの項目が残り得る。
選択外の target に依存する body-less hard link は、M1a と同様に失敗する。

Delegate は MainActor、write callback は明示的に nonisolated。
その中では不変の Sendable payload・session actor・Progress・同期状態だけを使う。
専用の background OperationQueue を返し、write は detached task から既存 worker を呼ぶ。
各要求は一つの reader を持ち、stream は同期 worker の内側に閉じる。
AppKit の非 Sendable completion block だけを `PromiseCompletion` の同期境界へ渡す。
この private な `@unchecked Sendable` の箱は lock 下で callback を取り出して nil にし、
lock 外で一度だけ呼ぶ。成功、catch、取消しの全経路が同じ完了点を通る。

Registry は provider と weak delegate の実体を保持し、drag sequence number で索引する。
完了すると項目と空の session 索引を除去する。未使用 promise は drag 終了後 60 秒の猶予を
与え、15 秒ごとの sweep で除去する。drag 開始に至らなかった provider にも作成後 60 秒の
期限がある。書き込み中は期限で除去せず、完了まで保持する。通常の sweep 間隔を含めると
未使用項目は約 60–75 秒で回収される（main run loop が動作している場合）。
猶予を超えて初めて要求する receiver は保証しない。

Copy は `ExtractionTemporaryDirectory` の新しい UUID ディレクトリへ先に展開する。
すべて成功してから `.fileURL` の実 URL と `.string` の書庫内パスを pasteboard に書く。
コピー後の URL はウィンドウの寿命と切り離し、次回起動時の既存 sweep に管理させる。
取消し・失敗した事前展開の作成物も次回 sweep まで残り得るが、pasteboard へ公開しない。
UI は選択親に含まれる子の重複 URL を除く。Copy は選択があるときだけ有効で、実行中の
重複要求を無効にする。32 MiB 以上、サイズ不明、集計 overflow では確定進捗シートを先に
表示する。小さい copy はシートなしで実行するが、stream 読み込みは main actor に置かない。

File メニューの「選択した項目を取り出す…」「すべて取り出す…」は
`NSOpenPanel(canChooseDirectories: true, canChooseFiles: false)` と進捗シートを使う。
Foundation.Progress の総 entry 数・完了数を表示し、Cancel は `Progress.cancel()` を呼ぶ。
M1a が 128 KiB read/write loop 内でも停止を確認する。文書を閉じる場合も task と progress を
取り消す。ユーザー向けの新しいメニュー・シート文字列は日英 `.xcstrings` に追加した。

> **API and behavior.** Payloads carry archive URL, generation, optional index,
> path and directory kind. Virtual folders have paths and no index. Display and
> generation come from one snapshot. Future mutations must use the document's
> reload hook, which increments the generation and opens the replaced archive by
> URL; failure invalidates the old reader. Stale file payloads resolve by exact
> path, rejecting missing or ambiguous matches. Resolution and reader acquisition
> do not suspend between generations. Actual archive mutation remains M2.
>
> Drag exports one provider per row, offers copy only, validates extension-derived
> UTIs and uses the folder UTI for folders. A folder creates the supplied directory
> and extracts its subtree with one reader and one root in archive order, preserving
> hard-link provenance and applying root metadata last. Single files honor the
> receiver's supplied filename. Unsafe descendants produce errors. Existing items
> are not overwritten; completed items may remain after a failed/cancelled folder
> extraction, and hard links whose targets are outside the selection still fail.
>
> The MainActor delegate has a nonisolated write callback and a private background
> OperationQueue. Extraction uses a detached task and the concurrent engine; no
> stream crosses an isolation boundary. The SDK's non-Sendable completion block
> is the only unchecked Sendable bridge: a private locked, single-use callback
> box. Every result reaches one completion point. The registry retains both
> provider and delegate, indexes them by drag session, releases on completion,
> and sweeps uncalled promises after a 60-second grace period every 15 seconds.
> Pre-drag providers also expire. Active writes survive the sweep; receivers that
> wait past the grace period before requesting data are not guaranteed service.
>
> Copy eagerly prepares a UUID directory, then publishes real file URLs plus
> archive-path text only after complete success. It never uses promises or lazy
> data providers. Published files outlive windows and remain until the next launch
> sweep; failed staging may remain until that sweep without being published.
> Copy is enabled only for a selection and prevents duplicate in-flight requests.
> At 32 MiB or more, unknown size or overflow, a determinate sheet appears first.
> Smaller copies have no sheet and still read off the main actor. File-menu
> extraction commands use a directory picker and a progress sheet. Cancellation
> calls Foundation.Progress.cancel(), which M1a checks inside its stream loop;
> closing the document also cancels. New UI strings have Japanese and English
> catalog entries.

## 追加 XCTest

以下は初回 sandbox 実行時の表。修正後の確認内容とコーディネーターの実測は追補を参照。
すべて `KaitoFinderTests/DragCopyOutTests.swift`。入力 ZIP/tar は各テストで Python 標準
writer により生成する。folder fixture の body-less hard link は先行ファイルを参照し、
内容だけでなく inode の一致を assert する。

| XCTest | 確認内容 / Coverage | 結果 |
|---|---|---|
| `testPromiseSingleFileCompletesExactlyOnceOnSuccess` | 指定 URL、内容、background queue、完了 1 回 / supplied URL, bytes, queue, one completion | pass |
| `testFolderPromiseHasOneProviderAndPreservesHardlinkSubtree` | folder 型方針、部分木、hard link の内容と inode / folder policy, subtree, hard link | pass |
| `testVirtualFolderPromiseExpandsWholeSubtree` | 仮想フォルダの path と深い子 / virtual folder path and descendants | pass |
| `testPromiseCompletesExactlyOnceOnFailureAndDoesNotOverwrite` | 既存データ不変、エラー、完了 1 回 / no overwrite, one failure completion | pass |
| `testPromiseCompletesExactlyOnceOnCancellation` | 事前取消し、出力なし、完了 1 回 / cancelled promise, no output, one completion | pass |
| `testGenerationMismatchResolvesPathUsingNewReader` | index 0 を別項目へ変更、元の path の新内容 / reordered entries, new inode and content | pass |
| `testGenerationMismatchMissingPathFailsExactlyOnce` | path 削除で別 entry を書かない / deleted identity never writes another entry | pass |
| `testFailedMutationReloadInvalidatesOldPromises` | 開き直し失敗時も世代更新と旧 reader 拒否 / failed reload invalidates old reader | pass |
| `testRegistrySweepsUncalledDragsAndPendingProviders` | 300 drag と未開始 provider、weak delegate と session 索引も解放 / 301 unused promises released | pass |
| `testRegistryRetainsAfterDragEndAndReleasesAfterWrite` | drag 終了後の delegate と完了後の回収 / post-drag retention and completion release | pass |
| `testRegistrySweepKeepsAnActiveWriteUntilCompletion` | 期限超過でも write 中は保持し、完了後に回収 / active writes survive expiry | pass |
| `testInvalidPromiseTypeFallsBackToData` | 不適切な UTI の fallback / invalid conformance fallback | pass |
| `testFolderPromiseReportsUnsafeChildrenRatherThanSilentlyDroppingThem` | 部分木内の traversal を失敗として通知 / unsafe descendants cause failure | pass |
| `testCopyPreparationEagerlyCreatesFilesAndSurvivesHelperLifetime` | フォルダとファイルの実体・内容・保持 / eager files, bytes and lifetime | pass |
| `testCopyPreparationCancellationStopsBeforeReturningURLs` | 1 entry 後で停止、URL を返さず後続ファイルなし / cancellation before URL return | pass |
| `testFolderProviderUsesFolderUTI` | 実際の provider の folder UTI / real folder provider construction | skip |
| `testCopyPublishesExistingRealURLsAndPlainTextOnNamedPasteboard` | 名前付き pasteboard の URL readback と内容 / named pasteboard round trip | skip |
| `testCancelledCopyPreservesPasteboardWithoutPartialURLs` | 元の clipboard と changeCount 不変 / cancelled copy leaves clipboard unchanged | skip |

直接 write テストでは `NSFilePromiseProvider()` を引数にして、実装した
`filePromiseProvider(_:writePromiseTo:completionHandler:)` を直接呼ぶ。
write は provider の metadata に依存せず payload だけを使うので、この経路も実際の
callback と同じ展開を行う。成功・失敗・取消しごとに同期カウンタが **1** であることを
明示的に assert し、最初の通知後にも短い観測時間を設けている。

> **Tests.** The table lists all 18 additions and their observed outcomes. Generated
> ZIP/tar fixtures test actual bytes, hard-link inode identity, renamed destination
> paths, mutation/reordering, completion counts, cancellation and registry cleanup.
> Direct write tests pass a default NSFilePromiseProvider into the real delegate
> method; the write implementation depends on its captured payload, not provider
> metadata. Completion counters are explicitly asserted to equal one on success,
> failure and cancellation, with a short post-completion observation interval.

## 未検証事項と手動確認

**実際の drag-to-Finder と Finder 内の Cmd-V は、この環境では検証できなかった。**
画面収録・Accessibility が使えず、System Events も Finder の window を報告しないという
既知の環境条件に従い、GUI 自動操作は試みていない。他アプリの drop/paste、メニューの
実際の responder routing、destination picker、進捗シートの表示とボタン操作、UI 応答性も
手動確認として残る。エンジンによる停止と callback は XCTest で確認したが、ボタンを
実際に押す検証とは区別する。

この実行 sandbox では名前付き pasteboard の `setString` が false を返した。
テストはランダムな名前だけを使い、**`NSPasteboard.general` には一切触れていない**。
サービスの preflight が通らなければ該当 2 件を XCTSkip にする。そのため acceptance 7 の
実 pasteboard round trip と acceptance 8 の pasteboard 不変性は、この sandbox 実行だけでは
未実証だった。後日のサービス利用可能な環境では取消し保護のテストは成功し、
公開テストは二重文字列の欠陥を検出した（追補参照）。
事前展開の実体・内容・途中取消しは別テストで成功した。

また LaunchServices が `UTType.folder.conforms(to: .directory)` を false とし、有効な
`public.folder` に対する provider 初期化も `NSInvalidArgumentException` で拒否した。
これは既知の無効 UTI の conformance 問題を再調査したものではなく、この sandbox で
有効な型を解決できないという実行制約。実装は conformance を構築前に検査し、照会失敗を
Swift のエラーにする。実 folder provider のテスト 1 件は preflight で skip する。
フォルダの型方針、直接 write による部分木と hard link の出力は別途 pass している。

通常環境での残作業:

1. ~~修正後の `xcodebuild test` をサービス利用可能な環境で再実行し、全 53 件・0 skip・
   0 失敗を確認する。~~ **完了**(上記)。初回のサービス利用可能な実行が、追補に記した
   2 件の失敗を検出した。
2. 単一ファイル・仮想フォルダ・hard link を含むフォルダ・複数選択を Finder へ drag し、
   内容、改名された受取先、copy カーソル、declined drop を確認する。
3. Cmd-C → Finder Cmd-V とテキストエディタへの paste を確認する。window を閉じても
   コピーした実体が利用できること、次回起動 sweep の寿命方針も確認する。
4. 32 MiB 以上の copy とメニューからの取り出しで、確定進捗の更新、Cancel による停止、
   取り消した copy が clipboard を変更しないことを確認する。

> **Unverified and manual checks.** Real drag-to-Finder and real Cmd-V-in-Finder
> could not be verified here. No GUI automation was attempted given the stated
> lack of screen recording and Accessibility. Other receivers, responder routing,
> picker/sheet presentation, actual button clicks and responsiveness remain manual
> checks. Engine cancellation is verified separately from clicking the UI.
>
> The sandbox also rejects writes to randomly named pasteboards. Tests never touch
> NSPasteboard.general and skip the two integration cases when preflight fails.
> Thus acceptance 7's pasteboard round trip and acceptance 8's unchanged clipboard
> were unproven by this sandbox run. The coordinator's later service-enabled run
> passed cancellation preservation and caught the publication duplication bug;
> see the addendum. Eager preparation and partial cancellation pass independently.
> LaunchServices cannot resolve the valid folder UTI in this sandbox; one provider
> construction case is also skipped. The production factory checks before calling
> AppKit and returns a Swift error when required type information is unavailable.
> Folder output and hard links are independently verified through direct writes.
> The coordinator has now confirmed all 53 tests without skips in a normal
> environment. Remaining manual checks cover Finder drag/paste, other apps,
> window-independent clipboard lifetime,
> the directory picker and progress/cancellation UI.

## 実行コマンドと末尾出力

指定の build/test は既定キャッシュへの書き込みが拒否され、いずれも終了コード 74。
次のコマンドの全出力を `build/m1b-requested-build.log` と
`build/m1b-requested-test.log` に保存した。

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' build
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' test
```

許可された作業領域へキャッシュを移した clean build は終了コード 0。
`-disable-sandbox` は Swift の子プロセス用であり、実行環境の制限は維持される。

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
```

同じオプションの `test` はテストバンドルを生成したが、testmanagerd.control の接続制限で
終了コード 133。既存 M1a と同じく、生成バンドルを直接実行した（終了コード 0）。

```sh
umask 022
env -i PATH=/usr/bin:/bin TMPDIR="$TMPDIR" \
  CFFIXED_USER_HOME="$PWD/build/User" \
  DYLD_INSERT_LIBRARIES="$PWD/build/DerivedData/Build/Products/Debug/KaitoFinder.app/Contents/MacOS/KaitoFinder.debug.dylib" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  "$PWD/build/DerivedData/Build/Products/Debug/KaitoFinder.app/Contents/PlugIns/KaitoFinderTests.xctest"
```

> **Commands.** Both requested commands exit 74 because default caches are outside
> writable roots. Workspace-local clean build exits 0. The equivalent test command
> builds the bundle but exits 133 because testmanagerd access is denied. Direct
> execution of that bundle against the real app dylib exits 0 with the three
> explicitly recorded integration skips. Complete requested and adjusted command
> tails follow; full logs remain under build/.

### 指定 build — 末尾 20 行

```text
2026-09-10 06:45:03.987 xcodebuild[31507:220039]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult, NSUnderlyingError=0x7aa9684db0 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}
2026-09-10 06:45:03.988 xcodebuild[31507:220039]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult, NSUnderlyingError=0x7aa9685140 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}

Package: kaitokit

Package: unknown

2026-09-10 06:45:04.105 xcodebuild[31507:220004] Writing error result bundle to /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/ResultBundle_2026-10-09_06-45-0004.xcresult
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)

```

### 指定 test — 末尾 40 行

```text
[-[SimDiskImageManager _onQueue_checkConnection:]:239] ERROR : simdiskimaged returned error (invalid), marking disconnected.
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
    request = "notification_subscription";
    "set_path" = "/Users/nagash/Library/Developer/CoreSimulator/Devices";
}) because we are not connected to CoreSimulatorService.
2026-09-10 06:45:09.023 xcodebuild[31527:220148] Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedDescription=CoreSimulatorService connection became invalid.  Simulator services will no longer be available.}
[-[SimServiceContext sendRequest:reply:error:]:1982] ERROR : Unable to deliver request ({
    request = "notification_subscription";
    "set_path" = "/Users/nagash/Library/Developer/CoreSimulator/Devices";
}) because we are not connected to CoreSimulatorService.
2026-09-10 06:45:09.024 xcodebuild[31527:220178] Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedDescription=CoreSimulatorService connection became invalid.  Simulator services will no longer be available.}
2026-09-10 06:45:09.024 xcodebuild[31527:220178]  iOSSimulator: [SimServiceContext defaultDeviceSetWithError:] returned nil (Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedFailureReason=Failed to subscribe to notifications from CoreSimulatorService., NSLocalizedDescription=Failed to initialize simulator device set., NSUnderlyingError=0x7849af8ba0 {Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedDescription=CoreSimulatorService connection became invalid.  Simulator services will no longer be available.}}}). Simulator device support disabled.
2026-09-10 06:45:09.024 xcodebuild[31527:220148]  IDESimulatorAvailability: startObservingSimulatorUpdates() FAILED to register SimDeviceSet observer
Resolve Package Graph
2026-09-10 06:45:09.147 xcodebuild[31527:220182]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-53-29-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-53-29-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-53-29-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-53-29-+0900.xcresult, NSUnderlyingError=0x7849af9650 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}
2026-09-10 06:45:09.147 xcodebuild[31527:220182]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-52-52-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-52-52-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-52-52-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-52-52-+0900.xcresult, NSUnderlyingError=0x7849af9a10 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}
2026-09-10 06:45:09.151 xcodebuild[31527:220182]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-56-24-+0900.xcresult, NSUnderlyingError=0x7849af99b0 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}
2026-09-10 06:45:09.151 xcodebuild[31527:220182]  IDELogStore: Unable to remove item at path /Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult: Error Domain=NSCocoaErrorDomain Code=513 "“Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
    Remove
), NSFilePath=/Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult, NSURL=file:///Users/nagash/Library/Developer/Xcode/DerivedData/KaitoFinder-dlbnzamtbnwxqfcpbfhrykjstdpf/Logs/Test/Test-KaitoFinder-2026.09.10_05-55-03-+0900.xcresult, NSUnderlyingError=0x7849af8120 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}

Package: kaitokit

Package: unknown

2026-09-10 06:45:09.247 xcodebuild[31527:220147] Writing error result bundle to /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/ResultBundle_2026-10-09_06-45-0009.xcresult
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)

```

### 作業領域内 clean build — 末尾 20 行

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

### 作業領域内 xcodebuild test — 末尾 40 行

```text
OS Version:    26A428
Application:   xcodebuild

Backtrace:
0   CoreFoundation                      0x00000001954dee90 __CFGenerateReport + 244
1   CoreFoundation                      0x000000019542e850 _CFXNotificationPostXPC + 768
2   CoreFoundation                      0x00000001953332d8 _CFXNotificationPost + 440
3   Foundation                          0x0000000196add49c -[NSDistributedNotificationCenter postNotificationName:object:userInfo:options:] + 108
4   IDEFoundation                       0x000000010e467548 -[IDETestProgressNotificationsObserver _considerPostingDistributedNotification] + 860
5   IDEFoundation                       0x000000010e46baec -[IDETestRunSession worker:forTestTargetRunner:willFinishWithResult:] + 308
6   XCTHarness                          0x000000010c50edc0 -[XCTHTestTargetRunner testRunner:willFinishWithResult:] + 468
7   XCTHarness                          0x000000010c50a45c -[XCTHTestRunner willFinishWithResult:sessionState:] + 1404
8   XCTHarness                          0x000000010c4fdd38 __63-[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:]_block_invoke_2 + 300
9   XCTHarness                          0x000000010c4fe5ec -[XCTHTestOperationCoordinator _considerDispatchingDelegateBlock] + 764
10  XCTHarness                          0x000000010c4fe828 -[XCTHTestOperationCoordinator _unconditionallyEnqueueDelegateBlock:consumingConsole:] + 196
11  XCTHarness                          0x000000010c6480a8 -[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:].cold.1 + 308
12  XCTHarness                          0x000000010c4fdbd8 -[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:] + 192
13  XCTHarness                          0x000000010c4fda14 __81-[XCTHTestOperationCoordinator _tearDownLoggingAndReportFinishToRunnerWithError:]_block_invoke_2 + 36
14  libdispatch.dylib                   0x00000001950f0a34 _dispatch_call_block_and_release + 32
15  libdispatch.dylib                   0x000000019510a5a0 _dispatch_client_callout + 16
16  libdispatch.dylib                   0x0000000195128998 _dispatch_main_queue_drain.cold.6 + 832
17  libdispatch.dylib                   0x00000001950ffb0c _dispatch_main_queue_drain + 176
18  libdispatch.dylib                   0x00000001950ffa4c _dispatch_main_queue_callback_4CF + 44
19  CoreFoundation                      0x00000001953af9cc __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__ + 16
20  CoreFoundation                      0x000000019537165c __CFRunLoopRun + 1980
21  CoreFoundation                      0x000000019544b82c _CFRunLoopRunSpecificWithOptions + 536
22  CoreFoundation                      0x00000001953e94c4 CFRunLoopRun + 64
23  Xcode3Core                          0x0000000109cb7778 -[Xcode3CommandLineBuildTool waitForBuildWithBuildLog:buildActionTimingSection:executionEnvironment:title:operationToEnqueue:error:] + 600
24  Xcode3Core                          0x0000000109cb809c -[Xcode3CommandLineBuildTool doBuildForBuildAction:timingSection:colorize:colorizeFailure:error:] + 1152
25  Xcode3Core                          0x0000000109cb8db4 -[Xcode3CommandLineBuildTool _buildWithTimingSection:] + 700
26  Xcode3Core                          0x0000000109cc4c54 -[Xcode3CommandLineBuildTool run] + 4864
27  libxcodebuildLoader.dylib           0x0000000102dcd4bc XcodeBuildMain + 608
28  xcodebuild                          0x0000000102cbf230 -[XcodebuildPreIDEHandler loadXcode3ProjectSupportAndRunXcode3CommandLineBuildToolWithArguments:] + 152
29  xcodebuild                          0x0000000102cbd51c -[XcodebuildPreIDEHandler runWithArguments:] + 364
30  xcodebuild                          0x0000000102cbd06c main + 476
31  dyld                                0x0000000194edbe80 start + 6688
2026-09-10 06:45:57.030 xcodebuild[31753:221733]  IDETestOperationsObserverDebug: Failure collecting logarchive: Error Domain=NSCocoaErrorDomain Code=4099 "The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction." UserInfo={NSDebugDescription=The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction.}
2026-09-10 06:45:57.032 xcodebuild[31753:221705] [MT] IDETestOperationsObserverDebug: 0.014 elapsed -- Testing started completed.
2026-09-10 06:45:57.032 xcodebuild[31753:221705] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start
2026-09-10 06:45:57.032 xcodebuild[31753:221705] [MT] IDETestOperationsObserverDebug: 0.014 sec, +0.014 sec -- end
```

### 直接 XCTest — 末尾 40 行

```text
Test Case '-[KaitoFinderTests.ExtractionTests testPreexistingIntermediateAndLeafSymlinksNeverRedirectWrites]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testPreexistingIntermediateAndLeafSymlinksNeverRedirectWrites]' passed (0.090 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testQuarantinePropagatesToFilesDirectoriesAndSymlinks]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testQuarantinePropagatesToFilesDirectoriesAndSymlinks]' passed (0.086 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testRestoredFileAndDirectoryPermissionsRespectProcessUmask]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testRestoredFileAndDirectoryPermissionsRespectProcessUmask]' passed (0.091 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSingleFileVirtualSubtreeAndMixedSelection]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testSingleFileVirtualSubtreeAndMixedSelection]' passed (0.410 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSolidGroupStaysInArchiveOrderAndConcurrentRequestsUseIndependentReaders]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testSolidGroupStaysInArchiveOrderAndConcurrentRequestsUseIndependentReaders]' passed (0.086 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSubtreeArchiveOrderHardlinksAndDeepestLastDirectoryAttributes]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testSubtreeArchiveOrderHardlinksAndDeepestLastDirectoryAttributes]' passed (0.138 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkChainsAbsoluteInternalTargetsAndCycles]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkChainsAbsoluteInternalTargetsAndCycles]' passed (0.092 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkDotDotCannotBeReinterpretedByLaterEntry]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkDotDotCannotBeReinterpretedByLaterEntry]' passed (0.086 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkTargetsInsideOutsideAndForwardReference]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkTargetsInsideOutsideAndForwardReference]' passed (0.088 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testTaskCancellationAndPrecancelledProgress]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testTaskCancellationAndPrecancelledProgress]' passed (0.086 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testTemporaryDirectorySurvivesHelperLifetimeAndSweepDoesNotFollowLinks]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testTemporaryDirectorySurvivesHelperLifetimeAndSweepDoesNotFollowLinks]' passed (0.135 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testTemporaryRootSymlinksAllowRootTargetsAndRejectSelfAliases]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testTemporaryRootSymlinksAllowRootTargetsAndRejectSelfAliases]' passed (0.086 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testTemporarySweepRemovesThreeHundredLevelsWithBoundedDescriptors]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testTemporarySweepRemovesThreeHundredLevelsWithBoundedDescriptors]' passed (2.586 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testTwentyThousandDirectoryPromotionsKeepUniqueResults]' started.
Test Case '-[KaitoFinderTests.ExtractionTests testTwentyThousandDirectoryPromotionsKeepUniqueResults]' passed (4.029 seconds).
Test Suite 'ExtractionTests' passed at 2026-09-10 06:46:22.527.
	 Executed 27 tests, with 0 failures (0 unexpected) in 9.238 (9.240) seconds
Test Suite 'KaitoFinderTests.xctest' passed at 2026-09-10 06:46:22.527.
	 Executed 53 tests, with 3 tests skipped and 0 failures (0 unexpected) in 12.789 (12.794) seconds
Test Suite 'All tests' passed at 2026-09-10 06:46:22.527.
	 Executed 53 tests, with 3 tests skipped and 0 failures (0 unexpected) in 12.789 (12.794) seconds
REFUSED [0] ../escape.txt: パスに .. 成分があります
REFUSED [2] a/../../deep.txt: パスに .. 成分があります
REFUSED [4] a\..\..\windows.txt: パスに .. 成分があります
WRITTEN: ["abs.txt", "ok.txt"]; PARENT UNCHANGED
TEMP ROOT: /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/KaitoFinder-ExtractionTests-19C8114B-54B5-4A03-8989-CDF60D52DF52/out; CANONICAL ROOT: /private/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/KaitoFinder-ExtractionTests-19C8114B-54B5-4A03-8989-CDF60D52DF52/out
DIRECTORY PROMOTIONS: 20000, elapsed: 0.305978042 seconds
```
