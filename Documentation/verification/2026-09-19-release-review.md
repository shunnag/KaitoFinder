# Release review, round A — 2026-09-19

Scope: A1–A12 in `kf-tier-a.md`. Existing uncommitted work was retained; no stash or commit was made. Neither KaitoKit nor GyoshukuKit was edited. `ExtractionPath` is unchanged; changes to `ExtractionDestination` are confined to A1/A2 and preserve descriptor-relative traversal, `O_EXCL`, and `O_NOFOLLOW`.

## Verification status and observed failures

**The initial round added 14 Swift regression tests and 4 Python tests.** The Python file now runs **13 tests, all passing**. **No Swift XCTest executed locally during the initial round**: both the prescribed build and test commands stop at package resolution. Accordingly, the initial-round sections have no locally observed pre-fix Swift assertion text; their assertion messages describe the written regression tests, not a claimed test run. The correction-1 record includes the orchestrator's supplied failures and one additional Swift regression test. Correction 2 below records three more Swift tests and actual standalone XCTest results.

Tests for each code item were written before its behavioral fix. The A6 byte counter and A10 presentation hooks were installed as test instrumentation before the fixes. For A12, the initial API error was recorded, then the optional parameter was scaffolded without a guard to obtain an assertion failure before implementing validation.

### B0 — blocker shared by A1–A7, A9, A10

The prescribed `build-for-testing` and `test-without-building` commands both exited **74**, before compilation/test execution, with this exact diagnostic:

```text
xcodebuild: error: Could not resolve package dependencies:
  Failed to clone repository https://github.com/sparkle-project/Sparkle:
    Cloning into bare repository '/Users/nagash/Github/KaitoFinder/build/CodexDerivedData/SourcePackages/repositories/Sparkle-09d89c53'...
    fatal: unable to access 'https://github.com/sparkle-project/Sparkle/': Could not resolve host: github.com
  fatalError
```

A cached-checkout attempt also encountered:

```text
<unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/gyoshukukit.dia' for diagnostics emission (Operation not permitted)
```

Using writable cache paths got past those errors, but Xcode's package graph then reported `Missing package product 'KaitoKit'`, `Missing package product 'GyoshukuKit'`, and `Missing package product 'Sparkle'`. This was not a successful build.

Independent compiler checks **did succeed** using existing dependency modules, with outputs/caches confined to writable paths:

- Swift 6 parse check of all 55 app and 70 test source files.
- Full app type-check with main-actor default isolation and the project's concurrency features; current app module emitted with testing enabled.
- Full test-target type-check against that freshly emitted app module, cached KaitoKit/GyoshukuKit modules, and Xcode's XCTest overlay.
- `xcstringstool compile --dry-run` succeeded. Exactly three new keys have all 26 language values (78 translations); existing keys are byte-for-byte equivalent as decoded catalog entries and format placeholders match.
- Compiled and executed the Swift fixture builders, then independently read their output with Python's standard ZIP/tar readers: ZIP CRC/content/external attributes and both signed PAX timestamps/content passed. Fixtures themselves are generated entirely in Swift.
- `git diff --check` passed.

These checks do **not** establish that XCTest/AppKit behavior passes. Full-suite, native UI drivers, real-volume extraction/clone behavior, and real signing/notarization remain unverified here. No stale test bundle was counted as a test of these changes. Raw logs and reproducible compiler command arrays are in ignored `build/TierAVerification/`.

## A1 — saturating modification times

**Evidence:** `ExtractionDestination.attributes` previously refused seconds outside `Int`'s range, after payload verification; `file`'s cleanup then unlinked the completed file. KaitoKit's PAX parser accepts the signed magnitude `10000000000000000000`.

**Change:** saturate seconds to ±9,223,372,036 before converting to `timespec`; handle non-finite input without an integer-conversion trap. Quarantine and permission failures still fail the entry.

**Files:** `KaitoFinder/Extraction/ExtractionDestination.swift`; `KaitoFinderTests/ExtractionTests.swift`; new `KaitoFinderTests/Support/ReleaseReviewFixtures.swift`.

**Test added (1):** `ExtractionTests.testExtremePAXModificationTimesPreserveVerifiedPayloads` builds a native Swift PAX tar with positive and negative extreme dates and checks empty failures, exact bytes, file presence, and bounded `st_mtimespec.tv_sec`.

**Pre-fix assertion observed:** none; B0. The test's failure message is `Extreme mtime must not discard verified files: …`. The old refusal `変更日時が範囲外です。` is source evidence, not an assertion observed in this run. **Executed: 0.**

## A2 — defaults for absent permissions

**Evidence:** creation modes were 0600/0700 and missing archive permissions skipped final `fchmod`; synthesized parents had no finalization.

**Change:** normal files without stored modes receive `0666 & ~processMask` after quarantine and CRC verification; explicit and synthesized directories receive `0777 & ~processMask`. Synthesized directories are finalized deepest-first, after explicit directories, through `openDirectory(create: false)` and descriptor `fchmod`. The file creation mode remains 0600, directories remain 0700 while being created, and read-only files finish at 0400. The code explicitly documents the quarantine-before-mode-widening order.

**Files:** `ExtractionDestination.swift`, `ExtractionService.swift` under `KaitoFinder/Extraction`; `KaitoFinderTests/ExtractionTests.swift`; `KaitoFinderTests/Support/ReleaseReviewFixtures.swift`; `README.md`; `Documentation/design.md` §9.

**Test added (1):** `ExtractionTests.testMissingZIPPermissionsUsePlatformDefaultsForFilesAndDirectories` first asserts nil permissions from the native Swift ZIP (`external_attr == 0`), then checks file, explicit directory, and synthesized directory modes, including nested implicit parents.

Existing stored-mode tests (`testSiblingFilesRetainContentsAndAttributesAcrossParentCacheSwitches` and the umask coverage in `ExtractionTests`) and `QuickLookOpenTests`' 0400 assertion remain intact. The security ordering is reviewed in code, not claimed as an observed runtime test.

**Pre-fix assertion observed:** none; B0. The regression compares actual `st_mode & 0777` with `0666/0777 & ~processMask`. **Executed: 0.**

## A3 — no solid-member thumbnails

**Evidence:** each thumbnail opens/materializes independently; the old eligibility guard allowed solid members, causing preceding solid data to be decoded for each row.

**Change:** require `entry.solidGroup < 0` before queuing any production. README describes image-only thumbnails, the 8 MiB limit, and exclusion of encrypted/solid 7z/RAR members.

**Files:** `KaitoFinder/UI/ArchiveThumbnailProvider.swift`; `KaitoFinderTests/ArchiveThumbnailTests.swift`; `README.md`.

**Test added (1):** `ArchiveThumbnailTests.testSolidMemberNeverStartsThumbnailProduction` checks nil image, synchronous idle state, no temporary materialization directory, and no generated files/callback.

**Pre-fix assertion observed:** none; B0. Written assertion: `Solid members must not start a production`. **Executed: 0.**

## A4 — bounded failure reports

**Evidence:** copy-out, batch, import, and creation joined all failures into alert text. Failure names/reasons can themselves contain line breaks.

**Change:** shared `ArchiveFailureReport` groups identical reasons in first-occurrence order, emits up to 20 representative lines and one localized summary, formats grouped counts, flattens embedded newlines, and caps each displayed name/reason at 1,024 characters. Summary counts undisplayed item names and repeated reasons; group lines include their full group count. All failure-join paths, including incoming file promises and batch cleanup, use it.

**Files:** new `KaitoFinder/Extraction/ArchiveFailureReport.swift`; `ArchiveCopyOut.swift` and `ArchiveBatchExtraction.swift` in that directory; `KaitoFinder/Creation/ArchiveCreationTransaction.swift`; `KaitoFinder/Import/ArchiveIncomingFiles.swift`; `KaitoFinder/UI/ArchiveBatchExtractionController.swift`; `KaitoFinder/UI/ArchiveWindowController.swift`; `KaitoFinder/Resources/Localizable.xcstrings`; `KaitoFinderTests/ExtractionTests.swift`.

**Tests added (2):**

- `ExtractionTests.testFailureReportIsBoundedForTwoThousandUnwritableEntries`: a native Swift ZIP with 2,000 entries and a 0500 output directory; checks 2,000 extraction failures, thrown report, ≤22 lines, and localized 2,000 count.
- `ExtractionTests.testFailureReportBoundsDistinctReasonsAndEmbeddedNewlines`: 2,000 distinct reasons with embedded line breaks; checks line bound and first/last detail selection.

**Pre-fix assertion observed:** none; B0. Written messages include `Failure reports must be bounded` and `Failure report must retain the grouped total`. **Executed: 0.**

## A5 — retain failed cleanup and continue sweeping

**Evidence:** one `removeItem` error aborted the sweep before saving; publish/creation defers unregistered directories even when deletion failed.

**Change:** catch and log removal errors per entry, retain failed rows, and continue to save the ledger. Non-ENOENT `lstat` failures are retained as well. Both transaction defers call `removeAndUnregister`, which unregisters only after successful removal or `lstat == ENOENT`.

**Files:** `KaitoFinder/Persistence/PendingWorkRegistry.swift`; `KaitoFinder/Import/ArchiveImportTransaction.swift`; `KaitoFinder/Creation/ArchiveCreationTransaction.swift`; `KaitoFinderTests/PendingWorkRegistryTests.swift`; `KaitoFinderTests/ScenarioDiskTests.swift`.

**Tests added (3):**

- `PendingWorkRegistryTests.testSweepRetainsUnremovableDirectoryAndContinuesToNextEntry`: dead-owner blocked A and removable B; confirms continued cleanup and retained A ledger row.
- `ScenarioDiskTests.testFailedPublishKeepsUnremovableWorkRegistered`: chmod parent to 0555 at publication, check unchanged original and registered surviving work directory.
- `ScenarioDiskTests.testFailedCreationKeepsUnremovableWorkRegistered`: same boundary for a new archive, with no destination published.

All permission changes have deferred restoration.

**Pre-fix assertion observed:** none; B0. Written messages: `An unremovable directory must not abort the sweep`, `Failed cleanup must remain registered`. **Executed: 0.**

## A6 — remember after request verification

**Evidence:** document-side `verifyRememberedPassword` streamed every encrypted entry before the session verified the selection.

**Change:** remove that whole-archive pass. The session emits a one-shot acceptance callback only after its requested encrypted entries verify and the candidate is adopted. The document checks candidate/session/generation and saves with the captured vault generation. Wrong stored-password eviction and stale/closed-session checks remain. The DEBUG-only counter records bytes consumed by password verification, excluding normal extraction writes.

**Files:** `KaitoFinder/Documents/ArchiveDocument.swift`; `KaitoFinder/Model/ArchiveSession.swift`; `KaitoFinderTests/ArchivePasswordPersistenceTests.swift`.

**Test added (1):** `ArchivePasswordPersistenceTests.testRememberingPasswordVerifiesOnlyRequestedEntry`: two 4 MiB stored AES ZIP members, request only the first with remember=true, assert verification bytes ≤1.1× its compressed size, exact extracted bytes, and saved vault password. The existing persistence/password regressions are unchanged.

**Pre-fix assertion observed:** none; B0. Written assertion: `Remembering a password must not verify unrelated members`. Both old verification passes were instrumented before removal so a pre-fix run would account for the extra pass. **Executed: 0.**

## A7 — determine clone support before destructive confirmation

**Evidence:** the stack started at `cloningSupported = true`; ENOTSUP/EXDEV was discovered only after the first confirmation decision.

**Change (including C1):** tri-state clone support, with unknown treated conservatively. The document's first undo-availability query reads `ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES` using `getattrlist` on the archive's directory, checking the valid `VOL_CAP_INT_CLONE` interface capability. The injectable query is cached even for an unknown result; it creates no files/directories and never invokes the capture closure. `emptyCopy()` preserves both injections and starts unknown for the new backing file. Runtime ENOTSUP/EXDEV handling remains in `capture()`. Append/move replacement sheets and password-removal confirmation use the same gate and the single new localized sentence `この操作は取り消せません。`.

**Files:** `KaitoFinder/Model/ArchiveUndoStack.swift`; `KaitoFinder/Documents/ArchiveDocument.swift`; `KaitoFinder/UI/ArchiveWindowController.swift`; `KaitoFinder/UI/ArchiveConflictPrompt.swift`; `KaitoFinder/UI/ArchivePasswordEditor.swift`; `KaitoFinder/Resources/Localizable.xcstrings`; `KaitoFinderTests/ArchiveUndoStackTests.swift`.

**Tests added (3):**

- `ArchiveUndoStackTests.testFirstDeleteOnUnsupportedCloneVolumeRequiresConfirmation`: injected false/nil capability results, first selection/delete, non-nil sheet, false undo availability, no capture, unchanged digest before confirmation and after cancellation.
- `ArchiveUndoStackTests.testCloneProbeRunsOnceAndEmptyCopyRechecksNewBackingFile`: count false/nil queries across repeated checks and a new backing archive; verify no captures.
- `ArchiveUndoStackTests.testReplacementAndPasswordRemovalWarningsFollowUndoGate`: both existing confirmation types show the warning only when undo is unavailable.

**Pre-fix assertion observed:** none; B0. Written messages include `First destructive edit must ask before publication` and `Unsupported clone must be known before the first edit`. **Executed: 0.** No expansion was deferred.

## A8 — documentation

**Files:** `README.md`; `Documentation/software-updates.md`; this record.

README retains compressed-tar staging guidance; Japanese and English document remaining reader caps, unrestricted per-entry/total sizes, default permissions, thumbnail restrictions, and the preview threshold. Japanese Settings now names all four tabs. Update documentation explains commit `created_at`, attaching `appcast.xml` before publication, one-item feeds, and not making an older-line maintenance release latest.

**Tests added/executed: 0; documentation-only, no failing assertion applicable.** Full-suite/driver results can be appended by the orchestrator after a build is available.

## A9 — explicit loading for large sidebar previews

**Evidence:** a single eligible selection immediately materialized the entire entry, without a size gate.

**Change:** a documented 64 MiB automatic-preview limit; larger/unknown sizes show an awaiting-load message and the existing Show Preview action. Small files still load automatically. Space-triggered Quick Look is untouched.

**Files:** `KaitoFinder/UI/ArchivePreviewSidebar.swift`; `KaitoFinderTests/ArchivePreviewSidebarTests.swift`; `KaitoFinder/Resources/Localizable.xcstrings`; `README.md`.

**Test added (1):** `ArchivePreviewSidebarTests.testLargeAndUnknownPreviewsWaitForExplicitActionButSmallFilesLoadAutomatically`: large, unknown, exactly-at-limit, and small sizes; checks no passive task/call, visible action, and one successful load after the explicit action. Uses task completion, not sleeps.

**Pre-fix assertion observed:** none; B0. Written assertion: `Large previews must wait for explicit action`. **Executed: 0.**

## A10 — cancel save-panel reconfiguration synchronously

**Evidence:** calling `savePanel.panel.cancel(nil)` bypassed the wrapper's clearing of a pending filename change and completion between dismissal and re-presentation.

**Change:** `cancelExtraction()` calls `ArchiveSavePanel.cancel()`. DEBUG-only hooks replace native presentation and stage a filename change so the existing real completion/main-queue path can be exercised deterministically.

**Files:** `KaitoFinder/UI/ArchiveWindowController.swift`; `KaitoFinder/UI/ArchiveSavePanel.swift`; `KaitoFinderTests/ArchiveCreationUITests.swift`.

**Test added (1):** `ArchiveCreationUITests.testCancelExtractionFinishesReconfiguringSavePanelExactlyOnce`: enters the real queued re-presentation path, cancels through the window controller, checks synchronous completion exactly once with `.cancel`, then drains the main queue and confirms no second presentation.

**Pre-fix assertion observed:** none; B0. Written messages: `cancelExtraction must finish a pending filename change synchronously`, `Save completion must be called once with cancel`, `A cancelled save panel must not re-present`. **Executed: 0.** Native save-panel driver was not run.

## A11 — reader-options comment and prior limit evidence

**Files:** `KaitoFinder/Model/ArchiveReaderOptions.swift`; this record.

Read `../KaitoKit/Sources/KaitoKit/Core/ReadLimits.swift` without modifying it. The comment now distinguishes destination-disk-bounded extraction, compressed-tar memory staging (`inMemorySingleFileLimit`, default 64 MiB), the temporary-disk reserve (`stagingFreeSpaceReserve`, default 1 GiB), and all other unchanged defaults. No explicit staging reserve is set.

Empirical CLI evidence supplied with the release-review specification, **not rerun here**: at KaitoKit default limits the ZIP64 4 GiB+1 fixture was refused with:

```text
Read limit exceeded: size 4294967297 exceeds limit 4294967296
```

The 68 GiB tar was refused with:

```text
Read limit exceeded: total uncompressed size
```

**Tests added/executed: 0; comment/record-only, no failing assertion applicable.** Existing `LargeArchiveTests` remain intact.

## A12 — previous-feed version guard

**Files:** `Tools/prepare_update.py`; `Tools/tests/test_prepare_update.py`; `Documentation/software-updates.md`.

**Change:** optional offline `--previous-appcast <path>`. Select the greatest numeric Sparkle build independent of feed order, support element and enclosure-attribute versions, require a strictly greater build and nondecreasing marketing version, and reject absent/malformed version metadata before any external tool. Dotted versions are zero-padded for numeric comparison.

**Tests added (4):**

- `test_previous_appcast_accepts_increased_build_and_same_marketing_version`
- `test_previous_appcast_rejects_nonincreasing_build_before_any_tool`
- `test_previous_appcast_rejects_marketing_downgrade_before_any_tool`
- `test_previous_appcast_rejects_missing_or_malformed_versions`

**Exact observed pre-fix failure text:** initially `TypeError: prepare() got an unexpected keyword argument 'previous_appcast'`. After scaffolding the optional parameter without validation, both nonincreasing-build and marketing-downgrade regressions failed with **`AssertionError: ValueError not raised`**. The malformed-feed case also produced that assertion. Subsequent subcases in the same red run produced these secondary assertions because the first wrongly accepted release had already created output/called tools:

```text
AssertionError: Lists differ: [False, False, False, False, False, False] != []
AssertionError: "CFBundleVersion must be strictly greater" does not match "The output directory already exists; choose a new directory to preserve previous updates."
```

**Counts:** initial API-red run 13 tests / 9 errors; scaffolded behavioral-red run 13 tests / 8 failures (including subtests); final run **13 tests / 0 failures / 0 errors**. Real signature tools are mocked by the existing harness, so signing/notarization is not claimed. `--help` exposes the new option.

## Commands and results

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/CodexDerivedData build-for-testing
```

Result before and after fixes: exit 74, B0, no compile/test count.

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/CodexDerivedData \
  test-without-building \
  -only-testing:KaitoFinderTests/ExtractionTests \
  -only-testing:KaitoFinderTests/ArchiveThumbnailTests \
  -only-testing:KaitoFinderTests/PendingWorkRegistryTests \
  -only-testing:KaitoFinderTests/ArchiveEditTests \
  -only-testing:KaitoFinderTests/ArchiveUndoStackTests \
  -only-testing:KaitoFinderTests/ArchivePasswordPersistenceTests \
  -only-testing:KaitoFinderTests/ArchivePasswordTests \
  -only-testing:KaitoFinderTests/ScenarioDiskTests \
  -only-testing:KaitoFinderTests/DragCopyOutTests \
  -only-testing:KaitoFinderTests/WordingAcceptanceTests \
  -only-testing:KaitoFinderTests/ArchivePreviewSidebarTests \
  -only-testing:KaitoFinderTests/ArchiveCreationUITests
```

Result before and after fixes: exit 74, B0, **0 Swift tests executed**. The last two filters cover A9/A10 in addition to the specified suite. `QuickLookOpenTests`' existing read-only-copy mode coverage likewise remains unexecuted.

```sh
python3 -m unittest discover -s Tools/tests -p test_prepare_update.py -v
xcrun xcstringstool compile --dry-run --output-directory /private/tmp/kf-tier-a-localization \
  KaitoFinder/Resources/Localizable.xcstrings
git diff --check
```

Results: **13 Python tests pass**, catalog compilation passes, whitespace check passes. Full-suite and native-driver results: **not run; append after resolving the build environment**.

## Correction 1 — C1 clone-support query and C2 resolved path comparisons

**Files changed in this correction:** `KaitoFinder/Model/ArchiveUndoStack.swift`, `KaitoFinderTests/ArchiveUndoStackTests.swift`, `KaitoFinderTests/ScenarioDiskTests.swift`, and this record. `ArchiveEntryControlsTests.swift` and `ArchivePreviewSidebarTests.swift` were verified byte-for-byte unchanged from the start of this correction. No commit/stash or sibling-package edits were made.

**Before — failures supplied by the orchestrator, not observed in a local XCTest run:**

- `ArchiveEntryControlsTests.testMultiSelectionDeletesOnceAndRegistersOneUndoEntryWithoutConfirmation`: `XCTAssertEqual failed: ("2") is not equal to ("1")`.
- `ArchiveEntryControlsTests.testPendingDeleteDisablesBothActionsAndCancellationPreservesBytesAndUndo`: `XCTAssertFalse failed` from the main-thread gate assertion, then `("timedOut") is not equal to ("success")`.
- The two C2 `ScenarioDiskTests` path comparisons: `XCTAssertEqual failed: (["/var/folders/.../locked/.KaitoFinder-add-…"]) is not equal to (["/private/var/folders/.../locked/.KaitoFinder-add-…"])` (the path excerpt is reproduced as supplied).

**Corrections:** C1 uses the volume query described under A7 instead of a trial clone. C2 applies `standardizedFileURL.resolvingSymlinksInPath().path` to both sides of each ledger/work-directory comparison; no C2 product behavior changed.

**Tests:** one new test, `ArchiveUndoStackTests.testDefaultCloneSupportQuerySupportsAPFSWithoutCapturing`, was written before the product fix. It requires the default query to enable undo on the fixture's APFS volume without calling the injected capture closure. Two existing A7 tests now cover both false and nil query results, confirmation, cached resolution, and `emptyCopy()` using a different archive. The two C2 assertions were updated. Thus this correction adds **1** Swift test and adjusts **4** existing tests; the combined A1–A12/C1 total is **15 new Swift tests**. **Local XCTest count: 0.**

**Local execution before/after:** the pre-fix `test-without-building` attempt against the orchestrator's existing `.xctestrun` exited 133 before any tests ran, including this exact diagnostic:

```text
The connection to service named com.apple.testmanagerd.control was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction.
```

Both pre-fix and post-fix prescribed `build-for-testing` attempts exited 74 at Sparkle resolution with `fatal: unable to access 'https://github.com/sparkle-project/Sparkle/': Could not resolve host: github.com`. The post-fix XCTest bundle could not be built or run, so there is **no post-fix XCTest assertion/pass result** to report. The stale pre-fix bundle was not counted as post-fix verification.

**Compiler and standalone checks:** the first full test-target typecheck exposed `error: contextual closure type '@Sendable (URL) -> Bool?' expects 1 argument, but 2 were used in closure body`. Keeping `clone` first among the initializer's closure parameters fixed existing trailing-closure calls without editing their tests. Final app module emission and all **70 test-source files** typecheck successfully against that fresh module, using cached dependencies. A standalone execution of the exact volume-query function passed three checks: APFS support is true; a missing directory yields nil; resolving `/var/folders` and `/private/var/folders` yields equal paths. These are smoke checks, not XCTest results. `git diff --check` passed. Logs are in ignored `build/TierAVerification/Correction1/`.

## Correction 2 — A13/A14

The three new regression tests were written before the behavioral fixes. A13's DEBUG-only sweep/write-state counters were installed as instrumentation while the original sweep behavior was still present. No sleeps were added; A13's explicit 200 ms performance requirement is the exception to the original round's prohibition on timing assertions. Fixtures for the new tests use the existing native Swift ZIP builder.

The prescribed Xcode build and targeted test commands both exited **74 before and after the fixes**, with:

```text
xcodebuild: error: Could not resolve package dependencies:
    fatal: unable to access 'https://github.com/sparkle-project/Sparkle/': Could not resolve host: github.com
```

An alternative local runner successfully compiled all **55 app sources and 70 test sources**, linking the cached KaitoKit/GyoshukuKit object files and Sparkle framework without editing them. It uses Swift 6, the project's main-actor default isolation/concurrency settings, and a fresh app library and XCTest bundle under `/private/tmp/kf-tier-a-c2-nativecheck/`. `xcrun xctest` executes that bundle directly. This is actual XCTest execution, but does not verify the normal Xcode app-host/build pipeline. The initial pre-fix run executed **3 tests, all failing, with 10 assertion failures**.

### A13 — sweep once at drag initiation, deadlines before delegate locks

**Files:** `KaitoFinder/Extraction/ArchiveFilePromise.swift`; `KaitoFinderTests/DragCopyOutTests.swift`; this record.

**Change:** `register` no longer scans existing records. `beganPending` sweeps once before collecting the drag's pending providers. `sweep` first rejects nil/unexpired deadlines, then checks the delegate's `isWriting` mutex only for expired records. The automatic **15-second sweep task is unchanged**.

**Tests added (2):**

- `testRegisteringFiveThousandPromisesSweepsAtMostOncePerDrag`: creates 5,000 native ZIP members/payloads, times registration plus `beganPending`, requires at most two sweeps and less than 200 ms, then verifies grace-period cleanup.
- `testRegistrySweepChecksDeadlinesBeforeDelegateWriteState`: pending/unexpired and active-drag records must not reach the delegate mutex; only the expired record is checked and removed.

**Exact pre-fix assertions observed:**

```text
XCTAssertLessThanOrEqual failed: ("5000") is greater than ("2") - Drag initiation must not sweep once per promised row
XCTAssertLessThan failed: ("1.482926667 seconds") is not less than ("0.2 seconds") - Registering 5,000 promises must finish within 200 ms
XCTAssertEqual failed: ("3") is not equal to ("1") - Unexpired and active-drag promises must not take the delegate mutex
XCTAssertEqual failed: ("4") is not equal to ("1") - Only expired promises need a write-state check
```

**After:** the full `DragCopyOutTests` suite executed **23 tests, 20 passed, 3 skipped, 0 failures**. Both new tests pass, including the measured registration duration below 200 ms. Existing tests for never-called promises, pending providers, session-specific waiting, completed writes, and overlapping/active writes pass unchanged. The whole performance test's reported 0.208 seconds includes fixture setup and cleanup; its timed registration section passes the separate 0.200-second assertion.

The three existing skips report `この実行環境では名前付き pasteboard サービスへ書き込めません` (two pasteboard tests) and `この実行環境では LaunchServices が public.folder を解決できません` (folder UTI test).

### A14 — solid members require an explicit sidebar action

**Files:** `KaitoFinder/UI/ArchivePreviewSidebar.swift`; `KaitoFinderTests/ArchivePreviewSidebarTests.swift`; this record.

**Change:** entries with `solidGroup >= 0` enter A9's `.awaitingLoad` state even when small. The existing message and Show Preview action are reused; no localization keys or Quick Look/Space behavior changed.

**Test added (1):** `testSmallSolidMemberWaitsForExplicitPreviewAction`: a 7-byte member with `solidGroup: 0` must start no task/materialization on selection, show the A9 message/action, and start exactly one materialization when clicked. The test holds that materialization with an actor gate, observes `.loading`, then cancels/drains it without relying on native preview rendering.

**Exact primary pre-fix assertions observed:**

```text
XCTAssertEqual failed: ("loading") is not equal to ("awaitingLoad") - Solid members must wait for an explicit preview action
XCTAssertNil failed: "Task<(), Never>(_task: (Opaque Value))" - Selecting a solid member must not start materialization
XCTAssertEqual failed: ("プレビューを読み込んでいます…") is not equal to ("大きなファイルです。プレビューを表示するには読み込みが必要です。")
XCTAssertEqual failed: ("キャンセル") is not equal to ("プレビューを表示")
```

The initial version also completed materialization and checked `.ready`; its pre-fix run had six assertions fail. After observing the standalone Quick Look cleanup limitation below, the new test was made deterministic around the gate/action behavior. That final test was rerun against a temporary library built from the saved pre-fix sidebar source: **1 test, 7 failures**, including the same four assertions above, a secondary unfulfilled materialization expectation, `("failed") is not equal to ("loading")`, and `("0") is not equal to ("1")`. The current library was then restored and the identical test passed: **1 test, 0 failures**.

**Not verified:** running the unchanged A9 large/unknown/small preview test in the standalone bundle aborts during cleanup with **SIGABRT / `-[QLPreviewView deactivate]` → `ArchivePreviewSidebar.closePreviewView()`**. Initializing `NSApplication` in a temporary test bootstrap did not resolve it. No existing sidebar test or production cleanup behavior was altered. Full sidebar/AppKit rendering and the normal app-host suite remain unverified here; the aborted runs are not counted as passes.

**Final completed post-fix runs:** **24 distinct tests: 21 passed, 3 skipped, 0 failures** (23 drag tests plus the new solid-member test). This correction adds **3 Swift tests**, bringing the combined A1–A14/C1 additions to **18 Swift tests**. `git diff --check` passed. All earlier workspace changes were retained; no commit/stash or sibling-package edits were made. Raw logs and compiler/runner command arrays are in ignored `build/TierAVerification/Correction2/`.

## オーケストレータによる検証（2026-09-19、Fable 5.1 / Opus 5）

上の各節は Codex の作業記録で、Codex の sandbox では XCTest を実行できなかった。以下はオーケストレータが
ユーザーの Mac（macOS 27.2 / Xcode 27.0 / arm64）で実行した結果。環境: 11:5x 以降は画面がロックされており、
key window を要するテストと 3 本の UI ドライバー（`verify_ui_integration.py` / `verify_finder_interactions.py` /
`verify_preview_sidebar.py`）は実行できていない。`ExtractionDestination` を変更したため、これらは
ロック解除後に必ず実行する（[UI 回帰テスト](../ui-integration-testing.md)）。

### 今回の変更全体（KaitoFinder）

| 項目 | 内容 | 主な根拠 |
|---|---|---|
| 上限 | `ReaderOptions.kaitoFinder` で `maxEntrySize` / `maxTotalUncompressedSize` を解除。kaito CLI の既定上限では ZIP64 の 4 GiB+1 項目が `size 4294967297 exceeds limit 4294967296`、68 GiB の tar が `total uncompressed size` で開けなかった | `LargeArchiveTests` 5 件（4 GiB 全展開は `KAITOFINDER_LARGE_ENTRY_TESTS=1` で 1 件、成功） |
| テスト隔離 | テストプロセスがユーザーの autosave（並び順・列・ツールバー・ウインドウ位置）を汚染・依存していた。開始時に退避し各テスト前に消去、終了時に復元 | `AutosaveIsolationTests`、`ArchiveHiddenFilesTests` 単独実行の順序依存が解消 |
| A1–A14 | 上記各節 | 下記の実行結果 |
| C1 | clone 可否の判定を `getattrlist(VOL_CAP_INT_CLONE)` に変更。注入 closure による試行 clone をメインアクターで走らせない（`ArchiveEntryControlsTests` 2 件が主スレッドの gate で deadlock していた） | 下記 |
| 門番の追加 | GyoshukuKit の `UpdateGatekeeper.ambiguousEndRecord` を `ArchiveCapabilities.readOnlyReason` に追加（既存キー「このアーカイブは変更できません。」を再利用）。**Codex の利用上限のためオーケストレータが直接編集**した唯一のコード変更 | ビルド成功、`CompressionCapabilityTests` / `ArchiveErrorTextTests` 成功 |

### 実行結果

- 修正前ベースライン（全件）: 807 件、16 skip、失敗 4（`ArchiveHiddenFilesTests` の表示メニュー先頭 index 依存 1 件 + 集計）。
- 関連 21 クラスの選択実行（12:32 の新規ビルド、`nm` で `volumeSupportsCloning` を確認）: **454 件、6 skip、失敗 0**
  （skip はネイティブ保存ドライバー用 5 件と 4 GiB 全展開の gate 1 件）。
  修正前の同じ選択では `ArchiveEntryControlsTests` 2 件・`ScenarioDiskTests` 2 件が失敗していた
  （`("2") is not equal to ("1")`、`Gate.wait` の主スレッド assert と timeout、`/var` と `/private/var` の比較）。
- `Tools/tests/test_prepare_update.py`: 13 件成功。
- 全件実行: 下記「全件」を参照。

### 計測（ライブラリ側、Release、他の負荷なし）

| 対象 | 変更前 | 変更後 |
|---|---:|---:|
| 100,000 項目 stored ZIP の `ArchiveReader.reopen()` | 220 ms（全件再解析） | 0.0 ms（K9） |
| 256 MiB の tar.gz の `reopen()` | 再展開（open と同等） | 0.0 ms（K1） |
| 100,000 項目 ZIP の編集可否の probe（G2） | `ArchiveUpdater.open` 230 ms | `probe` 0.2〜2.5 ms |
| 128 MiB stored ZIP の同長改名 + commit（G1） | 全 record の読み書き（134 MB 読み） | 8.6 ms、読み取り 266 byte（`unzip -t` 成功） |
| 1 GiB AES-256 ZIP の復号 1 パス（参考） | 1.46 s | 変更なし |
| 1 GiB ZipCrypto ZIP の復号 1 パス（参考） | 7.21 s | 変更なし |

注意: G4 の防御（`ArchiveUpdater.open` での CD 全 record と KaitoKit の raw record の照合）により、100,000 項目 ZIP の
`ArchiveUpdater.open` は 230 ms → 465 ms になった。`ArchiveCapabilities.inspect` が文書オープンと編集後に
`ArchiveUpdater.open` を呼ぶため、大規模 ZIP のオープンは約 230 ms 遅くなる。`probe` に切り替える B1
（`specs/kf-tier-b-inspect.md`）は Codex の利用上限で未着手。

### 未実施・引き継ぎ

- 3 本の UI ドライバーと key window 依存テスト（画面ロックのため）。
- B1: `ArchiveCapabilities.inspect(reader:)` + `ArchiveUpdater.probe` への切り替え（文書オープンの 3 回解析 → 1 回）。
- A9/A14 のメッセージ文言（solid メンバーにも「大きなファイルです」が出る）と、キャッシュ済み項目の自動読み込み。
- README への追記: サイドバーの solid 制限、KaitoKit の一時展開の空き容量予約（1 GiB）。
- 暗号化項目の二重読み（検証 + 展開。AES 1.46 s/GiB、ZipCrypto 7.2 s/GiB）は方針判断として据え置き。

### オーケストレータによる追加修正（Codex 利用上限後、Fable/Opus が直接編集。いずれも最小限）

全件実行（12:38、画面ロック中）で 388 件中、key window 依存の 14 件（ドラッグ・保存パネルのアニメーション・
タブ・サイドバーのメニュー）のほかに、次の 2 件と 1 件のクラッシュが出た。

1. `ArchiveSaveAsTests.testCommittedOutputStillBecomesBackingFileAfterLateCancellation`（plain ZIP）が
   「対応していないフォーマットです。」で失敗。原因は GyoshukuKit G4 の CD walk（`ZipCentralDirectory.validate`）が
   entry ごとに `Task.checkCancellation()` を呼び、取消し済み Task で行う公開後の再オープン
   （`switchBackingFile` は「遅れて届いた取消しで成功を隠さない」ために `checksCancellation: false`）で
   `ArchiveUpdater.open` が失敗 → `ArchiveCapabilities.inspect` が unavailable を返していた。
   **修正（GyoshukuKit）**: walk から取消し検査を外す。open は KaitoKit の open と同様に取消しに依存しない
   （walk は `maxTotalMetadataSize` / `maxEntryCount` で有界）。`ZipUpdaterIntegrityTests` ほか 31 件成功。
2. `ArchiveCreationTests.testInvalidSourcesAreAllReportedWithoutCreatingOutput` が失敗
   （`missing-one.txt: POSIX 2: No such file or directory (2)`）。A4 の `ArchiveFailureReport` が 2 件でも
   同じ理由をまとめて先頭の名前しか出さず、既存の「全ての失敗ファイル名を報告する」期待を壊していた。
   **修正（KaitoFinder）**: 先頭 20 行は 1 件ずつ名前付きで列挙し、超過分だけを「…他 N 件（同じ理由: M 件）」で
   まとめる。A4 のテストの期待（総数 → 省略数）を合わせた。
3. `ArchivePreviewSidebarTests.testLargeAndUnknownPreviewsWaitForExplicitActionButSmallFilesLoadAutomatically`
   がテストプロセスごと abort（`-[QLPreviewView deactivate]` の assertion、crash report
   `KaitoFinder-2026-09-19-124410.ips`）。テストがウインドウに載せていない `ArchivePreviewSidebar` を使い、
   `QLPreviewView.close()` は window に属さない view で abort する。ウインドウ内（非表示でも）なら
   `previewItem` 設定直後の `close()` も成功することを使い捨てテストで確認した。製品では
   サイドバーは常にウインドウの分割ビュー内にあるため、**製品は変更せず**、テストを実ウインドウの
   サイドバーを使う形に書き直した（一時コピーの回収が親フォルダごと削除するため反復ごとに専用フォルダ）。
   `ArchivePreviewSidebarTests` 15 件中、ロック依存の 1 件を除き成功。

追加のビルド上の修正: `ArchiveCapabilities.readOnlyReason` に GyoshukuKit の `.ambiguousEndRecord` の case
（既存キー「このアーカイブは変更できません。」に理由を添える）。
4. K2（KaitoKit: 圧縮 tar の一時展開が Task の取消しを検査）により、`switchBackingFile` の
   「遅れて届いた取消しで成功を隠さない」再オープン（`checksCancellation: false`）が圧縮 tar で
   `CancellationError` になった。追加した `ArchiveSaveAsTests.testCommittedCompressedTarStillBecomesBackingFileAfterLateCancellation`
   （`.tgz`）が修正前に `caught error: "CancellationError()"` で失敗することを確認し、
   **修正（KaitoFinder）**: `openArchive(checksCancellation: false)` は取消し状態を継承しない
   `Task.detached` で `ArchiveSession` を構築する。`ArchiveSaveAsTests` / `ArchiveRewriteTests` /
   `ArchiveDocumentOpeningTests` / `ApplicationTerminationTests` 66 件、2 skip、失敗 0。
   同じ機構で、編集の取消しが遅れて届いた場合の圧縮 tar の再読込（`reloadAfterMutation`）は
   「変更は保存されましたが、アーカイブを読み直せませんでした」の経路に落ちる（保存自体は完了、既存の表示）。
5. K11（StuffIt X の補助 stream の遅延検証）は、アプリが補助 stream の metadata を読まないため
   アプリから見える挙動の変化はない（`grep -rn auxiliar KaitoFinder` に該当なし）。

### 全件実行（2 回目、12:5x、画面ロック中）

**832 件、19 skip、失敗 9 テストケース**（集計上は 16 failures / 7 unexpected = 例外送出）。クラッシュ・再起動なし。
9 件はすべて key window / パネル表示を要するもので、ロック解除済みのベースラインでは成功していた:
`ArchiveConflictUITests.testDropComparesBothContentsAndReplacesAsOneUndoableBatch`、
`ArchivePasswordUITests` の保存パネルのアニメーション 6 件（「シーンの状態遷移が時間切れ」「expired」）、
`ArchivePreviewSidebarTests.testMenuToolbarAndKeyboardToggleTheActiveArchive`（「無効なメニュー項目」）、
`ArchiveTabTests.testOpeningPreferenceChangesOnlyNewWindowsAndKeepsNativeTabCommands`（「シーンの状態遷移が時間切れ」）。
ロック解除後にこの 9 件と 3 本の UI ドライバーを再実行する。

### Release ビルドと起動スモーク（13:10）

- `xcodebuild -configuration Release … CODE_SIGN_IDENTITY=<Developer ID> DEVELOPMENT_TEAM=FQTM2788K5 build`
  （`build/ReviewReleaseDerivedData`）: 成功。自プロジェクト由来の warning 0（AppIntents metadata の注記のみ）。
- `codesign --verify --deep --strict`: valid on disk / satisfies its Designated Requirement。TeamIdentifier FQTM2788K5、hardened runtime。
- 実行ファイル SHA-256: `b242ce31bc03dfc33654905bba9b3cf43570b7ffc3447959e3bb9fa5b9e553b2`。
- 起動スモーク: 100,000 項目の ZIP を引数に `open -a` で起動、8 秒後に RSS 385 MB で生存（2026-09-16 の実測 401 MB と整合）、
  AppleScript の quit で正常終了。画面ロック中のためウインドウの目視は未実施。notarize と staple は未実施（配布時に §11.5 の手順）。

### ThreadSanitizer（13:3x、オーケストレータ）

K9 で reader が解析済み状態（COW 配列）を複製間で共有するようになったため、アプリの並行性の高い 10 クラス
（`ExtractionTests` / `ArchiveThumbnailTests` / `DragCopyOutTests` / `ArchivePreviewSidebarTests` / `LargeArchiveTests` /
`ArchivePasswordTests` / `ArchiveEditTests` / `ArchiveBatchExtractionTests` / `ScenarioConcurrencyTests` / `QuickLookOpenTests`）を
`-enableThreadSanitizer YES`（`build/ReviewTSanDerivedData`、3 package とも TSan で再ビルド）で実行した。
**233 件、1 skip、失敗 2、ThreadSanitizer の報告 0 件。** 失敗 2 件は (1) 画面ロック依存のメニュー検証、
(2) `DragCopyOutTests.testRegistrySweepsUncalledDragsAndPendingProviders` の weak 参照の解放タイミング
（2026-09-16 の sanitizer 記録で TSan 下の既知の失敗として記録済み、通常実行では成功）。
KaitoKit 側は ASan/UBSan の変異テスト（KaitoKit の記録を参照）で 520 変異・所見 0。

### UI ドライバーの試行（14:0x）

ロック解除の検知後に `python3 Tools/verify_ui_integration.py` を実行したが、ユーザーが Safari を前面で使用中だったため、
検証アプリが key window になれず 51 件中 12 件が失敗（「シーンの状態遷移が時間切れ」「無効なメニュー項目: クイックルック」、
ドラッグの `NSDragOperation(rawValue: 0)`）。記録: `build/UIIntegrationVerification/5e5b6289-b0a3-4998-825a-4f4e802112ec/`。
ドライバーは実マウス・キー入力を送るため、ユーザーの操作と同時には実行できない。**3 本のドライバーと key window 依存の 9 件は、
ロック解除のまま操作しない時間帯に順に実行する必要がある（未完了）。**

### UI ドライバーの再試行（14:3x、ロック解除かつ 3 分以上操作なしを検知して自動実行）

- `verify_ui_integration.py` の **commands フェーズ: 51 件、失敗 0**（記録: `f42c12bd-ec7b-4ad8-adfe-3506c0004d68/commands.log`）。
  画面ロックで失敗していた 9 件のうち 8 件（`ArchiveConflictUITests` の drop、`ArchivePasswordUITests` の保存パネル 6 件、
  `ArchiveTabTests` のタブコマンド）と、前面が必要な Quick Look・書庫間の実ドラッグがこのフェーズで成功した。
- 続く native-save フェーズの途中で Mac が自動ロックされ、native-save と残る 2 本のドライバー
  （`verify_finder_interactions.py` / `verify_preview_sidebar.py`）は「macOS is locked」で中断。
  `ArchivePreviewSidebarTests.testMenuToolbarAndKeyboardToggleTheActiveArchive` は `verify_preview_sidebar.py` の範囲で未実行。
- 残りは、自動ロックが働かない時間（操作せず、かつロックしない状態）に順に実行する必要がある。ドライバーは
  実マウス・キー入力を送るため、操作中には実行できない。

### `verify_ui_integration.py`（15:0x、ユーザーのシェルから実行）

**全フェーズ成功**: commands 51 件、native-save 5 件（実際の保存ボタン・上書き確認・名前欄の編集）、
履歴の記録・再起動後の再オープン・消去・消去後の再起動の 4 起動。
記録: `build/UIIntegrationVerification/00abfd2a-1c59-4752-8933-52aeb19ccefe/`。
残りは `verify_finder_interactions.py` と `verify_preview_sidebar.py`（サイドバーのメニュー検証 1 件を含む）。

### `verify_finder_interactions.py`（15:2x、ユーザーのシェルから実行）

**153 件、失敗 0**（実入力 10 件を含む Finder 風のクリック名称変更、書庫間・タブ間の実ドラッグ、関連回帰）。
記録: `build/FinderInteractionVerification/a6cca463-0b79-4cba-b91a-869a9e532ad3/`（`finder.log`、`finder.xcresult`、captures 2 枚）。
残りは `verify_preview_sidebar.py` のみ。

### `verify_preview_sidebar.py`（15:3x、ユーザーのシェルから実行）

**93 件、失敗 0、skip 0**（サイドバーのメニュー・ツールバー・キー操作を含む。ロック中に失敗していた
`testMenuToolbarAndKeyboardToggleTheActiveArchive` も成功）。実画面 9 枚（off / empty / image 明暗 / text / pdf / resized / minimum / hidden）。
記録: `build/PreviewVerification/cc7c40ca-f3b6-4783-91ec-5f67053b5333/`。

### UI 検証のまとめ

3 本のドライバーがすべて成功し、画面ロックで失敗していた 9 件も全て実 UI 経路で成功した。
これで `ExtractionDestination` の変更（A1/A2）に対して義務付けた UI 検証は完了。未了は B1（Codex の利用上限、
`Documentation/pending/2026-09-19-followups.md`）のみ。

## B1 — 編集可否を session の reader から導く（オーケストレータ実装、ユーザー指示、advisor と相談、15:2x〜）

**変更**
- GyoshukuKit: `ArchiveRewriter.open` の表現可能性の walk を `validateRepresentability(entries:format:)` に切り出し、
  `ArchiveRewriter.probe(entries:format:)` を公開（GyoshukuKit の記録・CHANGELOG を参照）。
- `ArchiveCapabilities.inspect(reader:url:password:format:)` を追加。ZIP は `ArchiveUpdater.probe(url:)`（終端の門番、
  reader を作らない）で entry 数を照合し、tar / 7z / LHA は reader の一覧に対して `ArchiveRewriter.probe` を行う。
  拒否の優先順（一時コピー → 形式 → 暗号化 → 門番 → 書き込み権限 → 表現可能性）と文言は従来どおり。
  従来の `inspect(url:format:password:)` は一度だけ開いて reader 版に委ね、明示された `format` を尊重する
  （`ArchiveRewriteTests.testTarWrapperDetectionUsesMagicInsteadOfExtension` の契約を維持）。
- `ArchiveSession` の init / `reloadAfterMutation` / `refreshCapabilities` は自身の reader を渡す（actor 内で所有したまま、
  `format` と `entries` だけを読む）。`hasEncryptedHeaders` はパスワード付き 7z だけの 1 回の open なので変更しない
  （identity が変異ごとに変わるためキャッシュは効かない）。
- `ReaderOptions.kaitoFinder` に DEBUG の open 回数カウンタ（GyoshukuKit 内部の open は含まない）。

**挙動の変化（意図したもの）**: G4 の中央ディレクトリの照合（`ArchiveUpdater.open`）は公開時だけ走る。終端の門番を通っても
照合に失敗する ZIP は、開いた時点では編集可と表示され、最初の編集で `invalidArchive` として拒否される。

**修正前に失敗することを確認したテスト**（`ArchiveCapabilityInspectionTests`、session の呼び出しだけを一時的に戻して実行）:
```text
XCTAssertEqual failed: ("2") is not equal to ("1") - document open must parse the archive once (session reader only)
XCTAssertLessThanOrEqual failed: ("3") is greater than ("2") - a mutation must not re-open the archive for capabilities
XCTAssertLessThan failed: ("6.995819 seconds") is not less than … - session init must cost about one parse, not three
```
修正後は 5 件（timing 1 件は `KAITOFINDER_SCALE_TIMING=1` で実行）成功。

**計測（Debug、100,000 項目 stored ZIP、各 3 回平均）**

| | `ArchiveReader.open` | `ArchiveSession(url:)` |
|---|---:|---:|
| B1 前（部分: session の呼出しだけを戻し、新しい url 版 inspect = 1 回の open + probe） | 1.14 s | 2.33 s |
| B1 後 | 1.14〜1.19 s | 1.18〜1.24 s |

B1 前の真の経路（session の open + inspect の open + `ArchiveUpdater.open` の解析と G4 の CD walk）は
Release のライブラリ単体の実測（open 230 ms、`ArchiveUpdater.open` 465 ms）から約 700 ms で、B1 後は約 235 ms の見込み。
編集後の再読込も同じ差になる。

**レビュー後の追加（B1 の diff に対する 3 レンズの敵対的レビュー、生存 4 件に対応）**
- url 版 `inspect` は従来の順序（形式・外側の圧縮の判定 → 書き込み権限 → open）を守り、書庫を必要になった時点で一度だけ開く。
  KaitoKit の `wrongPassword` も `passwordRequired` と同じく `.encrypted` に写す（従来は rewriter が `RewriterError.password` に写していた）。
- 書き直し形式では従来どおり表現可能性 → 暗号化の順で拒否し、原本が通常ファイル（symlink でない）であることを確かめる。
- 公開時にだけ分かる `UpdaterError.invalidArchive`（G4 の照合）は session の編集可否に反映し、以後の編集を最初から断る
  （`testPublishTimeCentralDirectoryRefusalIsRememberedByTheSession`: GyoshukuKit の integrity test と同じ細工 ZIP で、
  修正前は `XCTAssertFalse failed`（canEdit のまま）、修正後は成功、原本は不変）。
- timing の閾値を 1.5 倍に。url 版と reader 版の同値テストは委譲後は同語反復に近いことを記す（将来の分岐の検出用）。

**検証**: 関連 12 クラス 226 件（2 skip）失敗 0。**全件 838 件、18 skip、失敗 0**（画面ロック解除後の初の全件成功）。
GyoshukuKit: `ArchiveRewriterProbeTests` ほか 44 件成功、全件は下記。

### ドラッグ画像の修正（ユーザー報告、16:2x、オーケストレータ実装）

報告: 書庫内で多数のファイルを選択してドラッグすると、カーソルに付いてくる一覧の下側が崩れ、画面外にあった行の項目がおかしい。
原因: 既定のドラッグ画像は各行の `NSTableCellView` の `draggingImageComponents` から作られる。画面外の行のセルは
Auto Layout が配置される前に描かれ、アイコンと名前の位置・幅が不定になる。さらに `viewFor` を経由するため、
画面外の行のサムネイル生成が副作用として走っていた。
修正: `outlineView(_:draggingSession:willBeginAt:forItems:)` で pasteboard の項目ごとに
`imageComponentsProvider` を設定し、アイコン（生成済みのサムネイルか型アイコン）と名前だけの画像を
`ArchiveDragImage` で組み立てる（行の高さに合わせ、長い名前は 320 pt で省略）。複数項目は
`draggingFormation = .stack` で Finder と同じく重ねる。項目の順序は writer を返した行（`draggedNodes`）と同じ。
`ArchiveThumbnailProvider.cachedThumbnail(for:)` を追加し、ドラッグでは生成を始めない。
テスト: `ArchiveDragImageTests`（2 件: 構成要素の配置と描画された画素、長い名前の上限）、既存の実ドラッグ
`ArchiveDropIntegrationTests` 8 件・`ArchiveTabSpringLoadingTests` 4 件・`ArchiveConflictUITests` 4 件成功。
見た目（重ね表示と下側の崩れの解消）は Release ビルド（`build/ReviewReleaseDerivedData`、300 ファイルの fixture）で
ユーザーの目視確認を依頼。

### 最終の全件実行とコミット前の状態（16:3x〜17:0x）

- B1 適用後の全件: **839 件、18 skip、失敗 0**（16:2x、画面ロック解除後）。
- ドラッグ画像の修正と ZIP のパスワード編集の門番を加えた後の全件（16:35）は、`LayoutOverflowTests` の実行中に
  テストホストが終了して再起動（ユーザーが同じ Mac を操作中）。再実行（16:5x）は 842 件中 9 件が失敗したが、
  すべて実ドラッグと保存パネルのアニメーション（ユーザーが Terminal でコマンド入力中に key window を失う型）で、
  操作のない状態での再実行では `ArchiveDropIntegrationTests` 8 件・`ArchiveTabSpringLoadingTests` 4 件・
  `ArchivePasswordUITests` 11 件（単独）がすべて成功した。`LayoutOverflowTests` / `WelcomeWindowTests` 32 件も単独で成功。
- 最終コードに対する非 GUI の変更は B1 の後に「ドラッグ画像」「パスワード編集の門番」「probe のテスト」だけで、
  いずれも対象クラスの選択実行で確認済み。
- **コミット対象の木そのものでの全件実行（17:0x、ロック解除・操作なし、`build/ReviewDerivedData` の 16:31 ビルド、
  ソースはそれ以降未変更）: 842 件、18 skip、失敗 0**（500 秒）。
  ログ中の「No space left on device」と `grantAccessClaim reply is an error` は、それぞれディスク満杯と
  展開失敗を模擬するテストの期待どおりの出力。

## 初回リリース 0.1.0 (2)（ユーザー指示「テストが完了したら、コミットし、初回のリリースを行ってください」、17:1x〜）

手順は design §11.5 と software-updates.md のとおり。`build/` は gitignore のため、使った ExportOptions.plist をここに写す:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>FQTM2788K5</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
```

notarytool の資格情報はユーザーが `xcrun notarytool store-credentials KaitoFinder`（Apple ID + app 用パスワード）で
ログインキーチェーンに保存し、以後は `--keychain-profile KaitoFinder` で参照する。パスワードは記録しない。

### 実行結果（17:1x〜17:2x、すべてオーケストレータが実行）

| 手順 | 結果 |
|---|---|
| コミット | KaitoFinder `a834dac`（72 ファイル、0.1.0 build 2）。KaitoKit `74662cf`、GyoshukuKit `62d0855` は先にコミット済み |
| archive | `xcodebuild … -configuration Release archive`（Developer ID 識別子 `B7A1…EB48`、`build/ReleaseArchiveDerivedData`）: ARCHIVE SUCCEEDED |
| export | `-exportArchive … build/release/ExportOptions.plist`: EXPORT SUCCEEDED。Info.plist は CFBundleVersion 2 / 0.1.0 / LSMinimumSystemVersion 26.0 / SUFeedURL・SUPublicEDKey が期待どおり。`codesign --verify --deep --strict` 成功、本体・Sparkle.framework とも Developer ID Application (FQTM2788K5)、hardened runtime |
| notarize | `xcrun notarytool submit build/KaitoFinder.zip --keychain-profile KaitoFinder --wait`: id `abce3903-fce5-419f-8a0d-db7e2062d76f`、**Accepted**（`notarytool log`: issues null） |
| staple / Gatekeeper | `stapler staple` → validate 成功。`spctl -a -vv -t exec`: accepted、`source=Notarized Developer ID` |
| 起動スモーク | export した app を fixture 付きで起動、ウインドウ「drag-many.zip」を確認して正常終了 |
| 更新ファイル | `Tools/prepare_update.py --app build/export/KaitoFinder.app --sparkle-bin build/CompoundExtensionDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin --output build/updates/0.1.0 --notes Documentation/releases/0.1.0.md`: `KaitoFinder-0.1.0.zip`（7,315,001 byte、staple 後の app から ditto）と署名付き `appcast.xml`（version 2、enclosure は `releases/download/v0.1.0/…`、length 一致） |
| 最終 ZIP の再検証 | ZIP を展開し直した app で `stapler validate` / `codesign --verify --deep --strict` / `spctl` すべて成功（Notarized Developer ID） |
| push | KaitoKit `26b84ca..74662cf`、GyoshukuKit `e1f16ac..62d0855`、KaitoFinder `0e1131c..a834dac` を origin/main へ。tag `v0.1.0`（a834dac）を push |
| GitHub Release | `gh release create v0.1.0 --draft --verify-tag` に ZIP と appcast.xml を添付（サイズ確認済み）→ `gh release edit --draft=false --latest` で公開。`releases/latest` は v0.1.0 |
| フィード確認 | `curl -sIL …/releases/latest/download/appcast.xml`: 302 → 302 → 200。取得した本文はローカルの appcast.xml と byte 一致。enclosure URL は 302 → 200、content-length 7,315,001 |
| 実 Sparkle での確認 | `Tools/probe_software_update.swift` を一時 bundle（`com.shunnag.KaitoFinder.UpdateProbe.*`、本番の HTTPS フィード、署名要求あり）で実行: build 0 からは version 2 を検出（error 0）、build 2 からは `SUNoUpdateError`（1001、"You're up to date!"）。ダウンロード・インストールは行わない |

利用者側の配布物: https://github.com/shunnag/KaitoFinder/releases/tag/v0.1.0 。
次回以降は `--previous-appcast build/updates/0.1.0/appcast.xml` を渡し、build 番号を 2 より大きくする。
