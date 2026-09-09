# M1a 展開エンジンと安全性の検証（2026-09-10）

## 対象と結果

中断された作業の `ExtractionPath`、`ExtractionQuarantine`、`ExtractionService`、
`ArchiveSession`、`EntryTree` の変更を引き継いだ。欠けていた
`ExtractionDestination` を追加し、結果の `.init` の型を明示してコンパイルエラーを解消した。
UI は追加していない。一時領域の起動時掃除だけを AppDelegate に接続した。
KaitoKit のソースと設定は変更していない。

Xcode 27.0（27A266a）、macOS SDK 27、arm64、deployment target 26.0、Swift 6、
strict concurrency、MainActor 既定隔離、Approachable Concurrency が対象。
アプリの clean build と XCTest バンドルのビルド、実際のアプリ dylib に対する
XCTest の直接実行を検証した。通常の `xcodebuild test` 経路は、この環境の
キャッシュ書き込み制限と testmanagerd の接続制限により成功していない。
Swift コンパイル警告はないが、Xcode の AppIntents metadata の警告と環境診断は
残るため、「ツールの出力にも警告が一つもない」とは主張しない。警告抑制はしていない。

> **Scope and result.** The interrupted implementation was continued, preserving
> its path sanitizer, quarantine helper, service, session and tree changes.
> `ExtractionDestination` completes the missing output layer and the ambiguous
> result initializer now has an explicit type. No UI was added; AppDelegate only
> gained the launch sweep. KaitoKit was not modified. Verification uses Xcode
> 27.0 (27A266a), arm64, deployment target 26.0 and Swift 6 strict concurrency
> with default MainActor isolation and Approachable Concurrency. The app builds
> from clean sources, and XCTest runs directly against the built app dylib.
> The standard xcodebuild test route is blocked by this environment. Swift
> compilation has no warnings; Xcode metadata and environment diagnostics remain.
> No warning suppression was added.

## 呼び出し API と契約

```swift
ExtractionSelection(entries: [ArchiveEntry])
@MainActor ExtractionSelection(nodes: [EntryNode])

@concurrent static func ExtractionService.extract(
    _ selection: ExtractionSelection,
    from session: ArchiveSession,
    to destination: URL,
    progress: Progress = Progress(totalUnitCount: 0),
    didProcess: (@Sendable (Int) -> Void)? = nil
) async throws -> ExtractionResult

ExtractionTemporaryDirectory(root: URL) // 省略時はユーザーの一時領域以下
func create() throws -> URL
func sweepOnLaunch() throws
```

上記は呼び出し形の一覧。`entries:` は書庫順へ整列する。`nodes:` は仮想フォルダを
含む部分木を再帰収集し、重複選択を index で除去し、表示で併合された明示的な
重複ディレクトリエントリも保持する。出力は書庫内の相対パスを維持する。
単一ファイル、部分木、混合選択で API は共通。

出力 root は呼出側が用意する既存の実ディレクトリで、完了まで排他的に所有する。
root の symlink は拒否する。root/reader の準備失敗は throw、entry ごとの失敗は
`failures: [Failure(entryIndex, name, reason)]` に収集し、後続処理を継続する。
`written: [WrittenItem(entryIndex: Int?, url: URL)]` は作成物を返し、合成した
親ディレクトリの index は nil。属性の仕上げに失敗したディレクトリは、作成済みの
ため written と failures の双方に現れる。取り消しは `cancelled` で返す。

M1a は**要求一つにつき worker 一つ、extractionReader() 一つ、出力 root 一つ**。
同じ solid group の entry を分離しない。部分木の本体と body-less hard link は
書庫順で同じ reader から扱い、今回作成した target の device/inode も検査する。
別の呼び出しで作った target は流用しない。本体付き hard link は独立ファイルとして
復元できる。別々の要求は別 reader を取得して同時実行できるが、出力 root は共有しない。
`EntryStream` の作成・read loop・破棄は一つの同期 worker 内に閉じ、隔離境界を越えない。

`Progress.kind = .file`、`fileOperationKindKey = .copying`、`fileURLKey = destination`、
総数と処理済み件数を設定する。進捗は失敗を含む処理済み entry 数。`didProcess` は
同じ worker 上で各 entry の処理後に同期呼び出しする。Progress.cancel() と Swift Task
の取り消しを entry 間だけでなく 128 KiB の read/write loop 内でも確認する。
破損・取り消し・属性失敗で未完成のファイルは unlink し、完了済みの項目は保持する。
宣言サイズを使ってコピーを途中で打ち切らず、stream の終端検証まで読む。

> **API contract.** `ExtractionSelection` accepts archive entries or main-actor
> tree nodes. Nodes recursively include virtual subtrees and deduplicate
> overlapping selections without losing duplicate archive records. Relative
> archive paths are preserved. The caller supplies and exclusively owns a real
> destination directory until completion. Setup failures throw; individual
> failures accumulate alongside written URLs and a cancellation flag. Synthetic
> directories have a nil entry index. A directory whose final attributes fail
> can appear in both written items and failures. Each request uses one worker,
> one freshly reopened reader and one root in archive order, preserving solid
> groups and hard-link provenance. Concurrent requests obtain separate readers
> and require separate roots. Streams never cross isolation boundaries.
> Foundation.Progress reports copying, destination URL and attempted entry
> counts, including failures. Both Progress and Task cancellation are checked
> between entries and within the 128 KiB read/write loop. Partial files are
> removed; completed items remain. Copying continues to authenticated stream EOF
> instead of trusting the archive's declared size.

## 安全性と重複名ポリシー

- NUL、`..` 成分、空名を拒否し、先頭 `/`、drive prefix、`.` を既存の方針どおり
  正規化する。Windows の `\` も名前の区切りとして扱う。
- `isInside` は既存 symlink と `..` を成分順に解決し、root に区切りを付けた
  prefix で比較する。Foundation の `resolvingSymlinksInPath` だけでは未作成の葉の
  手前にあるリンクを解決しないケースが XCTest で見つかったため、独自の成分 walk
  で標準化する。リンクを解決する前に `a/..` を消してはいけない。
- 書き込みは検査結果だけに頼らず、root の fd から `openat`、`mkdirat`、
  `O_DIRECTORY | O_NOFOLLOW` で各親を開く。既存の中間 symlink は、内側を指していても
  書き込み経路として使わない。葉は `O_EXCL` で新規作成し、既存ファイル、リンク、
  FIFO 等を上書きしない。エラーや取り消しでは今回作成した未完成の葉だけを削除する。
- symlink entry の target は実際のリンク解決後に root 内側（root 自体も可）である
  必要がある。相対 target、安全な絶対 target、安全なリンク連鎖、単純な前方参照は
  許可し、元の target 文字列を保持する。NUL、循環、外部 target、および未作成の
  `a/..` は拒否する。後者は後続 entry が a をリンクにして意味を変えるため。
- **重複は書庫順の最初を優先**。正規化済みパスを NFC で予約し、最初の entry が
  破損していても後続へ置き換えない。後から悪意ある内容へ差し替わることを防ぎ、
  並行度に依存しない結果にする。大文字小文字等のファイルシステム上の別名衝突も
  `O_EXCL` で上書きを拒否する。今回合成したディレクトリだけは明示 directory entry
  へ昇格できる。既存の明示ディレクトリは拒否し、既存の親は属性を変更せず再利用できる。
- quarantine は session が書庫から読んだ値を新規ファイル、明示・合成ディレクトリ、
  symlink に適用する。通常ファイルとディレクトリは fd、symlink 自身は
  `XATTR_NOFOLLOW` で扱う。hard link は同じ inode の属性を共有する。
  書庫に値が無い場合は自動付与された値も除去する。適用失敗を成功扱いしない。
- 変更日時と通常の POSIX permission を復元する。setuid/setgid/sticky は復元しない。
  ディレクトリは作成時に owner の操作権を確保し、全 entry の処理後に深い順で
  変更日時と permission を適用する。取り消し時も作成済みのディレクトリを仕上げる。

> **Safety and duplicate policy.** Names reject NUL, parent traversal and empty
> paths, retaining the existing normalization of leading slashes, drive prefixes
> and dot components. Windows separators are also recognized. Containment walks
> existing symlinks before interpreting parent components and also handles a
> missing final leaf; a Foundation-only implementation failed that adversarial
> test. Actual writes separately use descriptor-relative operations and
> O_NOFOLLOW for every parent, with O_EXCL for leaves. Existing intermediate
> symlinks are never write paths, even when they point inside. Link entries may
> retain safe relative or absolute targets, safe chains and forward references;
> external targets, cycles and missing-directory parent traversals are refused.
> The first archive entry reserves each normalized NFC name, even if it fails,
> preventing replacement by later content and making results deterministic.
> Filesystem alias collisions cannot overwrite existing objects. Only directories
> synthesized by this request can be promoted to explicit directory entries.
> Archive quarantine is applied to all new objects, including implicit directories
> and links, and removed when absent on the archive. Quarantine failures propagate.
> Normal permissions and modification times are restored, with special privilege
> bits stripped. Directory metadata is applied deepest first after all children,
> including when extraction is cancelled.

## 一時領域

`FileManager.default.temporaryDirectory/com.shunnag.KaitoFinder.Extraction/UUID` を
0700 で作る。終了時には消さず、次の起動時に掃く。`.itemReplacementDirectory` は
使わない。専用 root は実ディレクトリ・現在の uid・group/other のアクセスなしを
検査する。掃除は fd 相対で行い、symlink 自身だけを unlink する。展開で 000 に
なったディレクトリも、安全に owner のアクセス権を戻して削除する。

> **Temporary storage.** The app owns UUID directories under
> `temporaryDirectory/com.shunnag.KaitoFinder.Extraction`, mode 0700. They survive
> helper destruction and app exit so pasteboard URLs remain usable, and are swept
> on the next launch. No item-replacement directory is used. The root must be a
> real directory owned by the current uid with no group/other access. Cleanup is
> descriptor-relative, removes symlinks without traversing them, and handles
> extracted directories with mode 000.

## 敵対的 fixture と実出力

`testHostileZIPRefusesTraversalAndLeavesParentUntouched` が毎回生成する実際の fixture。
下記の `p` はテスト専用親ディレクトリの `fixture.zip`。同じ親には `out/` と
`sentinel` を置く。親の項目名一覧、sentinel の内容、書庫の byte 列が展開前後で
同じこと、出力が `out/abs.txt` と `out/ok.txt` だけであることを assert する。

```python
import zipfile
z = zipfile.ZipFile(p, 'w')
z.writestr('../escape.txt', 'x')
z.writestr('/abs.txt', 'x')
z.writestr('a/../../deep.txt', 'x')
z.writestr('ok.txt', 'x')
z.writestr('a\\..\\..\\windows.txt', 'x')
z.close()
```

実際の XCTest 出力:

```text
REFUSED [0] ../escape.txt: パスに .. 成分があります
REFUSED [2] a/../../deep.txt: パスに .. 成分があります
REFUSED [4] a\..\..\windows.txt: パスに .. 成分があります
WRITTEN: ["abs.txt", "ok.txt"]; PARENT UNCHANGED
```

`/abs.txt` は設計 §9 と引き継いだ sanitizer の指定どおり先頭 `/` を除去して
**root 内の `abs.txt` へ展開する**。絶対名の一律拒否へ仕様を変えていない。
脱出する成分を持つ entry はすべて拒否され、destination の親は変更されない。

> **Adversarial fixture.** The exact ZIP fixture and refusal output are shown
> above. Tests compare the destination parent's listing, sentinel contents and
> archive bytes before and after, and assert that only abs.txt and ok.txt exist
> inside the output. Per design section 9 and the preserved sanitizer, /abs.txt
> is normalized into the destination, rather than rejected merely for being
> absolute. All escaping components are refused and the parent is unchanged.

## XCTest 名と確認内容

既存 EntryTreeTests 8 件に加え、以下の ExtractionTests 22 件を実行した。

| XCTest | 確認内容 / Coverage |
|---|---|
| `testHostileZIPRefusesTraversalAndLeavesParentUntouched` | 敵対名、親の不変 / hostile names, unchanged parent |
| `testPathSanitizationAndResolvedContainment` | NUL、drive、区切り、prefix / sanitizer and containment |
| `testPreexistingIntermediateAndLeafSymlinksNeverRedirectWrites` | 既存リンク、内向きリンク経路の拒否 / existing link writes |
| `testSymlinkTargetsInsideOutsideAndForwardReference` | 内外 target、前方参照 / inside, outside and forward links |
| `testSymlinkDotDotCannotBeReinterpretedByLaterEntry` | 後続 entry による a/.. の意味変更 / future parent traversal |
| `testSymlinkChainsAbsoluteInternalTargetsAndCycles` | 連鎖、安全な絶対 target、循環 / chains, absolute targets, cycles |
| `testExistingSymlinkBeforeDotDotIsResolvedBeforeStandardization` | リンク解決と .. の順序 / resolution before parent traversal |
| `testDuplicateNamesFirstArchiveEntryWinsIncludingNormalization` | 同名、NFC/NFD、directory 重複 / duplicate policy |
| `testExistingFileAndDirectoryAreNotOverwritten` | 既存データ保護 / existing object preservation |
| `testQuarantinePropagatesToFilesDirectoriesAndSymlinks` | setxattr した書庫から全作成物へ / quarantine propagation |
| `testArchiveWithoutQuarantineProducesNoQuarantine` | 属性なし、既存属性の除去 / absent quarantine and removal |
| `testCancellationStopsPartwayAndReportsFileProgress` | 部分取り消しと Progress 全キー / partial cancellation, file progress |
| `testTaskCancellationAndPrecancelledProgress` | Task と開始前の取り消し / both cancellation mechanisms |
| `testCancellationWithinFileRemovesPartialPayload` | read loop 中の取り消しと部分ファイル除去 / partial payload cleanup |
| `testCancellationStillFinalizesCreatedDirectoryAttributes` | 取り消し後の directory 属性 / finalization after cancellation |
| `testCorruptEntryIsRemovedAndLaterEntriesContinue` | CRC 破損、同名 fallback 拒否、継続 / corruption isolation |
| `testSubtreeArchiveOrderHardlinksAndDeepestLastDirectoryAttributes` | 部分木、同じ inode、mtime、mode / subtree and hard-link metadata |
| `testSingleFileVirtualSubtreeAndMixedSelection` | 単一、仮想部分木、混合選択 / all selection forms |
| `testSolidGroupStaysInArchiveOrderAndConcurrentRequestsUseIndependentReaders` | clean-room solid 7z、逆順選択、同時要求 / solid order and concurrent readers |
| `testBodylessHardlinkCannotUsePreexistingTargetFromAnotherExtraction` | 別 reader の target を拒否 / hard-link provenance |
| `testEmptySelectionAndMismatchedEntry` | 空選択、不一致 index / empty and mismatched selections |
| `testTemporaryDirectorySurvivesHelperLifetimeAndSweepDoesNotFollowLinks` | 保持、掃除、000 mode、root symlink / temporary directory lifecycle |

ZIP と tar は Python 標準 writer、solid 7z は byte 表と Python 標準の CRC32 から
テスト内で組み立てる。破損 ZIP は central directory を維持したまま指定 entry の
payload の 1 byte だけを反転する。既存の第三者 fixture をコピーしていない。

> **Tests.** The table lists all 22 new extraction tests in addition to the eight
> existing tree tests. ZIP and tar inputs are created with Python's standard
> writers; the solid 7z input is assembled from a byte table and standard CRC32.
> The corrupt ZIP changes one payload byte while preserving its directory.
> These are generated clean-room fixtures, not copied third-party archives.

## 実行コマンドと末尾出力

指定どおりの build/test コマンドも実行したが、既定の DerivedData と
SourcePackages への書き込みが拒否された。両方とも package 解決段階で停止する。

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' build
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' test
```

両コマンドの末尾（test の実出力から）:

```text
Resolve Package Graph
You don’t have permission to save the file “repositories” in the folder “SourcePackages”.
2026-09-10 05:04:35.958 xcodebuild[8227:72533] Writing error result bundle to /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/ResultBundle_2026-10-09_05-04-0035.xcresult
xcodebuild: error: Could not resolve package dependencies:
  You don’t have permission to save the file “repositories” in the folder “SourcePackages”.

```

既存 M0 の検証と同じ、許可された作業領域内へキャッシュと成果物を置く設定で検証した。
`-disable-sandbox` は Swift の子プロセス用で、実行環境の制限を外すものではない。
プロジェクト自体の設定は変更していない。

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

clean build は終了コード 0。末尾 20 行:

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

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/ExplicitPrecompiledModules

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/SDKExplicitPrecompiledModules

PruneExplicitPrecompiledModules /Users/nagash/Github/KaitoFinder/build/DerivedData/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules

** BUILD SUCCEEDED **

```

同じ環境オプションで `test` を実行した場合、バンドルのビルド後に
`testmanagerd.control` の接続が拒否され、終了コード 133 で停止した。
末尾 40 行:

```text
OS Version:    26A428
Application:   xcodebuild

Backtrace:
0   CoreFoundation                      0x00000001954dee90 __CFGenerateReport + 244
1   CoreFoundation                      0x000000019542e850 _CFXNotificationPostXPC + 768
2   CoreFoundation                      0x00000001953332d8 _CFXNotificationPost + 440
3   Foundation                          0x0000000196add49c -[NSDistributedNotificationCenter postNotificationName:object:userInfo:options:] + 108
4   IDEFoundation                       0x000000010bcd3548 -[IDETestProgressNotificationsObserver _considerPostingDistributedNotification] + 860
5   IDEFoundation                       0x000000010bcd7aec -[IDETestRunSession worker:forTestTargetRunner:willFinishWithResult:] + 308
6   XCTHarness                          0x0000000109d7adc0 -[XCTHTestTargetRunner testRunner:willFinishWithResult:] + 468
7   XCTHarness                          0x0000000109d7645c -[XCTHTestRunner willFinishWithResult:sessionState:] + 1404
8   XCTHarness                          0x0000000109d69d38 __63-[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:]_block_invoke_2 + 300
9   XCTHarness                          0x0000000109d6a5ec -[XCTHTestOperationCoordinator _considerDispatchingDelegateBlock] + 764
10  XCTHarness                          0x0000000109d6a828 -[XCTHTestOperationCoordinator _unconditionallyEnqueueDelegateBlock:consumingConsole:] + 196
11  XCTHarness                          0x0000000109eb40a8 -[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:].cold.1 + 308
12  XCTHarness                          0x0000000109d69bd8 -[XCTHTestOperationCoordinator _reportFinishToRunnerWithError:] + 192
13  XCTHarness                          0x0000000109d69a14 __81-[XCTHTestOperationCoordinator _tearDownLoggingAndReportFinishToRunnerWithError:]_block_invoke_2 + 36
14  libdispatch.dylib                   0x00000001950f0a34 _dispatch_call_block_and_release + 32
15  libdispatch.dylib                   0x000000019510a5a0 _dispatch_client_callout + 16
16  libdispatch.dylib                   0x0000000195128998 _dispatch_main_queue_drain.cold.6 + 832
17  libdispatch.dylib                   0x00000001950ffb0c _dispatch_main_queue_drain + 176
18  libdispatch.dylib                   0x00000001950ffa4c _dispatch_main_queue_callback_4CF + 44
19  CoreFoundation                      0x00000001953af9cc __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__ + 16
20  CoreFoundation                      0x000000019537165c __CFRunLoopRun + 1980
21  CoreFoundation                      0x000000019544b82c _CFRunLoopRunSpecificWithOptions + 536
22  CoreFoundation                      0x00000001953e94c4 CFRunLoopRun + 64
23  Xcode3Core                          0x0000000107523778 -[Xcode3CommandLineBuildTool waitForBuildWithBuildLog:buildActionTimingSection:executionEnvironment:title:operationToEnqueue:error:] + 600
24  Xcode3Core                          0x000000010752409c -[Xcode3CommandLineBuildTool doBuildForBuildAction:timingSection:colorize:colorizeFailure:error:] + 1152
25  Xcode3Core                          0x0000000107524db4 -[Xcode3CommandLineBuildTool _buildWithTimingSection:] + 700
26  Xcode3Core                          0x0000000107530c54 -[Xcode3CommandLineBuildTool run] + 4864
27  libxcodebuildLoader.dylib           0x00000001006a14bc XcodeBuildMain + 608
28  xcodebuild                          0x0000000100593230 -[XcodebuildPreIDEHandler loadXcode3ProjectSupportAndRunXcode3CommandLineBuildToolWithArguments:] + 152
29  xcodebuild                          0x000000010059151c -[XcodebuildPreIDEHandler runWithArguments:] + 364
30  xcodebuild                          0x000000010059106c main + 476
31  dyld                                0x0000000194edbe80 start + 6688
2026-09-10 05:10:11.662 xcodebuild[9559:81605]  IDETestOperationsObserverDebug: Failure collecting logarchive: Error Domain=NSCocoaErrorDomain Code=4099 "The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction." UserInfo={NSDebugDescription=The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction.}
2026-09-10 05:10:11.664 xcodebuild[9559:81498] [MT] IDETestOperationsObserverDebug: 0.015 elapsed -- Testing started completed.
2026-09-10 05:10:11.664 xcodebuild[9559:81498] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start
2026-09-10 05:10:11.664 xcodebuild[9559:81498] [MT] IDETestOperationsObserverDebug: 0.015 sec, +0.015 sec -- end
```

同じオプションで `build-for-testing` の成功を確認後、Xcode 付属の XCTest runner を
直接起動した。GUI を起動せず、ホストアプリの Debug dylib の実装に対するテストである。

```sh
env -i PATH=/usr/bin:/bin \
  CFFIXED_USER_HOME="$PWD/build/User" \
  DYLD_INSERT_LIBRARIES="$PWD/build/DerivedData/Build/Products/Debug/KaitoFinder.app/Contents/MacOS/KaitoFinder.debug.dylib" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  "$PWD/build/DerivedData/Build/Products/Debug/KaitoFinder.app/Contents/PlugIns/KaitoFinderTests.xctest"
```

**30 tests, 0 failures、終了コード 0**。抽出 22 件、既存の木モデル 8 件。
末尾 40 行:

```text
Test Case '-[KaitoFinderTests.ExtractionTests testPreexistingIntermediateAndLeafSymlinksNeverRedirectWrites]' passed (0.086 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testQuarantinePropagatesToFilesDirectoriesAndSymlinks]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testQuarantinePropagatesToFilesDirectoriesAndSymlinks]' passed (0.088 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSingleFileVirtualSubtreeAndMixedSelection]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testSingleFileVirtualSubtreeAndMixedSelection]' passed (0.404 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSolidGroupStaysInArchiveOrderAndConcurrentRequestsUseIndependentReaders]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testSolidGroupStaysInArchiveOrderAndConcurrentRequestsUseIndependentReaders]' passed (0.087 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSubtreeArchiveOrderHardlinksAndDeepestLastDirectoryAttributes]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testSubtreeArchiveOrderHardlinksAndDeepestLastDirectoryAttributes]' passed (0.140 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkChainsAbsoluteInternalTargetsAndCycles]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkChainsAbsoluteInternalTargetsAndCycles]' passed (0.084 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkDotDotCannotBeReinterpretedByLaterEntry]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkDotDotCannotBeReinterpretedByLaterEntry]' passed (0.083 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkTargetsInsideOutsideAndForwardReference]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testSymlinkTargetsInsideOutsideAndForwardReference]' passed (0.085 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testTaskCancellationAndPrecancelledProgress]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testTaskCancellationAndPrecancelledProgress]' passed (0.082 seconds).
Test Case '-[KaitoFinderTests.ExtractionTests testTemporaryDirectorySurvivesHelperLifetimeAndSweepDoesNotFollowLinks]' started.
python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
Test Case '-[KaitoFinderTests.ExtractionTests testTemporaryDirectorySurvivesHelperLifetimeAndSweepDoesNotFollowLinks]' passed (0.134 seconds).
Test Suite 'ExtractionTests' passed at 2026-09-10 05:14:42.985.
	 Executed 22 tests, with 0 failures (0 unexpected) in 2.245 (2.246) seconds
Test Suite 'KaitoFinderTests.xctest' passed at 2026-09-10 05:14:42.985.
	 Executed 30 tests, with 0 failures (0 unexpected) in 2.562 (2.564) seconds
Test Suite 'All tests' passed at 2026-09-10 05:14:42.985.
	 Executed 30 tests, with 0 failures (0 unexpected) in 2.562 (2.564) seconds
REFUSED [0] ../escape.txt: パスに .. 成分があります
REFUSED [2] a/../../deep.txt: パスに .. 成分があります
REFUSED [4] a\..\..\windows.txt: パスに .. 成分があります
WRITTEN: ["abs.txt", "ok.txt"]; PARENT UNCHANGED
```

`file` でも実装 dylib が `Mach-O 64-bit dynamically linked shared library arm64` で
あることを確認した。Swift コンパイル警告は 0 件。clean build のツール警告は以下:

```text
2026-09-10 05:11:26.682 appintentsmetadataprocessor[10081:83806] warning: Metadata extraction skipped, no AppIntents.framework dependency found
```

XCTest の Python 起動にも、この環境では `DARWIN_USER_TEMP_DIR` の取得失敗による
`/tmp` fallback の警告が出る。これはテスト失敗ではなく、全 fixture の生成と検証は
成功している。M0 の既存テストにも sandbox extension の環境診断が出る。

> **Commands and logs.** The exact requested commands were attempted and failed
> during package resolution because the default cache locations are not writable.
> With the same workspace-local cache configuration used for M0, clean build and
> build-for-testing succeed. xcodebuild test builds the bundle but exits 133 when
> this sandbox denies its testmanagerd connection. Direct invocation of Xcode's
> XCTest runner against the actual app dylib passes all 30 tests, including 22
> extraction tests, with exit status 0. The unedited output tails are included
> above. The dylib is confirmed arm64. Swift compiler warning count is zero;
> Xcode's no-AppIntents metadata warning, simulator service diagnostics and
> Python's sandbox-related temporary-directory fallback warning remain visible.

## 未確認と境界

- 通常の testmanagerd 経由での `xcodebuild test` 成功、およびツール警告を含めた
  完全な warning-free 出力は、この環境では証明できていない。
- GUI の drag/copy/Quick Look は今回の範囲外。実書庫 fixture は ZIP、tar、solid 7z。
  KaitoKit が対応する全形式、暗号化書庫、全ファイルシステムでの網羅検証ではない。
- ストリーム自体が破損した solid group では、その状態を共有する後続 entry も
  KaitoKit から失敗を返される可能性がある。サービスは試行を継続し、各失敗を記録する。
- 並行中に別プロセスが出力 root や祖先を移動・置換する状況は、呼出側の排他的所有
  契約の範囲外。既存 symlink を使った脱出は XCTest で検証済み。
- 複数 worker に要求を分割する高速化は未実装。同時要求ごとの独立 reader は検証済み。

> **Unverified boundaries.** The standard testmanagerd route and completely
> warning-free tool output cannot be proven here. GUI integration is out of scope.
> Real fixtures cover ZIP, tar and solid 7z, not every supported archive format,
> encrypted archive or filesystem. Corruption of shared solid state may also
> make later members fail in KaitoKit; the service still attempts and reports
> each item. Concurrent external replacement of the destination or its ancestors
> is outside the caller's exclusive-ownership contract. Existing symlink escape
> attempts are tested. Requests are not subdivided among multiple workers;
> independent readers for concurrent requests are tested.
