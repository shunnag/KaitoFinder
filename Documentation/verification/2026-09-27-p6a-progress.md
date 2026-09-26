# S39 / P6-A — write progress (2026-09-27)

## Scope and isolation

S39 only, starting at KaitoFinder `b191380` on `feature/2026-09-24-review` in the canonical working tree.
No commit. P7 and the Step 0-P7 gate were not started. Read P6-A / AC-A1–A12, the P6 common API contract,
ORDER-P6-P13 §2 / §3.4, the S38–S41 prompt, and the read-only S38 verification record before implementation.
No AGENTS.md was found in the checkout or its parent paths.

The required publish branches, `rewriteBranch(format:)`, replay arguments and reservation order,
and `reloadAfterMutation(advancing:)` are present. The complete test-editor inventory is
`DeferredSavePlanEquivalenceTests.StubEditor` and `DeferredSaveAttributeTests.RecordingEditor`;
both keep the protocol's default progress implementations.

Both `build/s39-p6a` and `build/s39-p6a-final` contain independent `git archive` exports of:

- KaitoKit `823ad460faab055b6b7051da10583480785e8f68`.
- GyoshukuKit `b9da4bc1e152d5b02be5c306f05654c032030b9e`.
- KaitoFinder `b191380`, overlaid with this working tree's product/test/project/tool files.

No live sibling checkout was built or modified. The ledger calls the public
`maximumPendingInputBytes(for:)`; it does not duplicate the S38 bounds. In particular, tar.xz includes
P14's packing and light blocks (20 MiB at one thread, 139,001,856 bytes at eight threads).

## Implementation and release-note text

Imports, ordinary saves, creation, conversion, deletion, rename/move, new folders and password edits
now map GK's per-call byte ratios into a single write-progress ledger. Large files and commit work can
advance the progress bar while the item label continues to count items. Each session tolerates changing
totals, clamps over-reports, and leaves one unit for verification/publication. Cancellation callbacks run
before the existing publication boundary; publication completion cannot throw.

Replay keeps removal → rename → encryption reservation → addition → folder order and preserves its
ledger-free API/owner-ID dispatch. Additions are closed and drained before commit. Non-relocatable ZIP
fallback resets the ledger and item counts before the rewrite attempt. Conversion accounts for pending
additions before newly imported items and excludes omitted root-directory records from its output count.

The ledger's state uses `Mutex`; Progress/KVO updates and DEBUG hooks run outside it. Zero increments do
not write Progress. Small-file completion does not repeat the byte update already supplied by GK.
An additional DEBUG lifecycle hook supplies exact begin/reset/publication endpoints to the requested
`PROBE-PROGRESS` timing row. It is internal and does not add an application setting or alternate write route.

The S33 occupancy arguments, editor order, name-index changes and advancement calls are unchanged.
Split producers/pipelines/publication and their progress budgets are unchanged. `ArchiveReencryptionProgress`
is unchanged and is now used in product code only by `ArchiveSplitWorkProducer`; ledger-free `publish`
callers retain the old updater budget through a local compatibility callback.

No strings, defaults keys, controls, menus, published release notes or
`Documentation/pending/2026-09-24-large-archive-edit-plan.md` changed. The preceding text is the release-note
draft for the orchestrator.

## Verification commands and limitations

The scripts, complete compiler argv, compiled-source hashes, exit codes and logs are in each isolated
build directory. The direct compiler harness uses the exported sibling sources and an existing Sparkle
framework from `build/Review0924Opt/Build/Products/Debug`; it does not resolve a live sibling package.
All direct builds target arm64 macOS 26 with Swift 6. Product and test builds use DEBUG, testability,
MainActor default isolation, NonisolatedNonsendingByDefault and InferIsolatedConformances, matching the
previous S25 harness. These are functional, unoptimized runs, not performance acceptance.

```sh
python3 build/s39-p6a/build.py --prepare KaitoKit GyoshukuKit
python3 build/s39-p6a/build.py --sync app
python3 build/s39-p6a/build.py --sync test
python3 build/s39-p6a/build.py --sync app test
python3 build/s39-p6a/build.py --sync test
python3 build/s39-p6a/package-resources.py
python3 build/s39-p6a/run-tests.py ArchiveWriteProgressTests ByteProgressIntegrationTests
python3 build/s39-p6a-final/build.py --prepare --sync
python3 build/s39-p6a-final/package-resources.py
python3 build/s39-p6a-final/typecheck.py
```

The second test compile failed on an async call inside an XCTest autoclosure in the new many-file probe.
It was corrected by awaiting the entries before asserting; the following test compile passed.
The initial new-test run passed 7 ledger tests and 9 integration tests. A final run adds conversion with
pending edits/root records and uses a nonempty 7z drain for the original-preservation cancellation case.

One Xcode build-for-testing attempt ran against the first isolated project:

```sh
xcodebuild -project build/s39-p6a/KaitoFinder/KaitoFinder.xcodeproj -scheme KaitoFinder \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build/s39-p6a/DerivedData \
  -clonedSourcePackagesDirPath build/Review0924Opt/SourcePackages \
  -disableAutomaticPackageResolution build-for-testing
```

It failed during package resolution because the sandbox denied writes to the user Clang module and
SwiftPM manifest caches. It ran no tests (`build/s39-p6a/xcodebuild.log`). A direct XCTest run is not a
claim that the full Xcode suite passed. Native save-panel XPC and application-host cases that cannot
finish in this harness must be run by the orchestrator. Frontmost UI cases remain in the existing
`Tools/verify_ui_integration.py` selections and require an idle, unlocked Mac. No UI-test expectation was
relaxed to accommodate this environment. Existing hdiutil helpers already throw XCTSkip on failure;
real volume acceptance belongs to the orchestrator.

## Final results

The final product/test snapshot byte-matches the canonical Swift files. Both pinned dependencies,
all 108 product Swift files and all 160 test Swift files compile; the non-DEBUG product typecheck exits 0.
`git diff --check` passes. Both live sibling status outputs and all protected-path diffs are empty.
The S33 advancement call lines and the split producer/reencryption progress files match HEAD.

The final new tests are **17 passed, 0 failed**: ArchiveWriteProgressTests (7) and
ByteProgressIntegrationTests (10). Across the two candidate layouts, counting each case's latest result
once, the direct harness reports **424 passed, 6 skipped, 7 failed, 12 interrupted**. This is not the full
Xcode suite: some classes aborted before reaching all their cases. Complete results, including the
failed/aborted attempts and baseline reproductions, are in
[runs.tsv](data/2026-09-27-p6a/runs.tsv),
[run-commands.json](data/2026-09-27-p6a/run-commands.json),
[cases.tsv](data/2026-09-27-p6a/cases.tsv), and
[summary.json](data/2026-09-27-p6a/summary.json).
The run ledger includes exact selectors, environment, exit status, log path and SHA-256.

| Acceptance | Result |
|---|---|
| AC-A1 | Passed: all budget rows, threads 1/8, changing/zero/over-reported totals, slot transitions, cancellation/reset, item keys, reentrant read hook, small-item KVO counts and saturated metadata arithmetic |
| AC-A2 | Passed: 64 MiB random additions through ZIP/tar/tar.gz/LHA/7z, asserted routes, ≥12 addition credits, monotonic bounded completion and 1/1 item |
| AC-A3 | Passed: 32 MiB tar.gz carry + 16 MiB addition, owner reset, both placements; end addition has two fully credited one-unit events, commit has ≥6 credits |
| AC-A4 | Passed: 200 × 1 MiB stored ZIP delete/move and tar delete, ≥10 commit credits and edit-only item totals |
| AC-A5 | Passed: ZIP/tar.xz creation, 12/12 items; unchanged 20-entry conversion; additional pending-replay offset and omitted-root conversion checks |
| AC-A6 | Passed: ZIP/tar staged 16 MiB + empty additions, rename/folder, 4/4 items; both specified fallback tests assert exactly one reset |
| AC-A7 | Passed: addition's second credit, nonempty 7z drain, updater/rewriter commit cancellation preserve original identity/digest, undo and work cleanup; new-archive drain cancellation cleans output. Existing no-alert and didProcess tests passed unchanged |
| AC-A8 | Passed: cancelling Progress and the current Task after rename still returns success and completes the ledger |
| AC-A9–A10 | Not measured for acceptance; functional probe smoke only, below |
| AC-A11 | Specified assertions migrated; all relevant progress/fallback cases passed, including the S25 7z password test |
| AC-A12 | Resource diff empty, 49 wording cases passed; full Xcode/app-host acceptance remains pending |

The first focused selection was exactly the 22 classes listed in P6-A's command (including the two
new classes, which ran first), plus SevenZipUpdatePasswordTests, SevenZipUpdateRoutingTests,
LHAUpdateFallbackTests and CompressedTarDeferredSaveTests. Final-source checks reran the new tests,
creation/rewrite, tar/LHA/7z compatibility branches, replay/name-index equivalence, both fallback reset
tests and individual remaining password/deferred/undo cases. The exact final selection is also saved in
`build/s39-p6a-final/focused-selections.json`.

Remaining harness results were investigated without changing the product or weakening tests:

- **Three failed cases and one interrupted case reproduce on untouched `b191380` with the same
  exported KK/GK binaries.** The two undo cases are
  `testTwelveAppendsKeepTenSlotsAndDeleteOldestFiles` (replacement-directory cleanup) and
  `testSlotsStayOutsideArchiveParentDirectory` (Foundation puts its replacement directory beside the
  archive). The split cases are `testCommittedCleanupWarningIsSuccessAndHeldVerificationKeepsPending`
  (save failure) and `testCrashS7MemberOpenOffersRecoveryBeforeMissingGateNormalization`
  (same gate assertion then signal 10). Baseline product/test compilation succeeded; all 265 baseline
  Swift source files were compared to `git show b191380`. No S39 changes were overlaid. Logs/argv are
  under `build/s39-p6a-baseline`, and the four baseline runs are included in runs.tsv but excluded from
  the candidate totals above.
- **Four failed app-host cases:** ArchiveUndoStackTests' edit-menu shortcut test cannot find the
  application's main menu. Three WordingAcceptanceTests require Bundle.main's 26 localizations or
  RecentDocumentsMenu nib; direct xctest's main bundle is Xcode's tool directory. The catalog/style
  checks themselves passed. These tests were not modified.
- **Eleven other interruptions:** nine native Save As/panel cases exit 69 with ClientCallsAuxiliary /
  HostCallsAuxiliary XPC connection errors; the password-menu test aborts with signal 6, and the
  unsupported-clone confirmation test with signal 5. The case ledger names every one. The split
  interruption above brings the total to twelve. No timeout was silently counted as a pass.
- **Six skips:** TarUpdateEditTests' three disk-image cases and SplitSavePassTests' three disk-image
  cases skip when hdiutil fails. The orchestrator must exercise the actual volumes.

Both probe smoke tests passed (unoptimized DEBUG, no speed claim):

```sh
env KAITOFINDER_PERFORMANCE_PROBES=1 KAITOFINDER_PROBE_ENTRIES=1 \
  KAITOFINDER_PROBE_ADD_FILES=120 KAITOFINDER_PROBE_PAYLOAD_MIB=1 \
  KAITOFINDER_PROBE_FORMATS=zip,tar,tar.gz,7z,lha \
  python3 build/s39-p6a/run-tests.py PerformanceProbeTests/testManyFileAdditionsAndCreationWhenEnabled
env KAITOFINDER_PERFORMANCE_PROBES=1 KAITOFINDER_PROBE_ENTRIES=20 \
  KAITOFINDER_PROBE_PAYLOAD_MIB=1 KAITOFINDER_PROBE_FORMATS=zip,tar,tar.gz,tar.bz2,tar.xz,7z,lha \
  KAITO_TEST_TIMEOUT=600 \
  python3 build/s39-p6a/run-tests.py PerformanceProbeTests/testArchiveEditsWhenEnabled
```

The first produced all ten add_many/create_many rows; the second exercised all seven formats and
produced 112 immediate-operation rows, including 14 delete_start rows (entries and payload).
All 122 progress rows, including tail_ms, are saved in
[probe-progress.tsv](data/2026-09-27-p6a/probe-progress.tsv).

## Changed test expectations

Only the P6-A AC-A11 cases and S25's corresponding 7z password count were migrated:

- ArchiveRewriteTests: item-total assertions use fileTotalCount; carry cancellation uses the first
  commit credit and asserts that completion stays at that slot's start. Publication still requires total − 1.
- ArchiveCreationTests: the total label counts imported/output entries; completion still equals total.
- ArchiveEditTests: one new folder counts as one item; byte completion still equals total.
- ArchivePasswordEditingTests: updater/password matrices and rewrite routes count one item, remain
  monotonic and complete. The explicit commit/cancellation test now exercises the ledger. Fallback
  observes exactly one nonzero → zero reset before successful completion.
- DeferredSaveDocumentTests: deferred encryption counts its edit items and asserts one reset only for fallback.
- SevenZipUpdatePasswordTests: S25's fixed 1001 expectation becomes one item plus full byte completion,
  as required for the same password operation. Route, content and encryption assertions remain intact.

Ledger-free transaction tests keep their earlier progress assertions. NameIndexEquivalenceTests,
DeferredSavePlanEquivalenceTests, DeferredSaveAttributeTests, the import cancellation/no-alert case,
and the didProcess conflict tests were not edited.

## Performance handoff

`PerformanceProbeTests.testManyFileAdditionsAndCreationWhenEnabled` adds `add_many` and `create_many`.
`KAITOFINDER_PROBE_ADD_FILES` defaults to zero; generated paths are `d%03d/s%d/f%06d.txt`, using seed
20260926, 202–4,002-byte word text and fixed atime/mtime via `touch -t 202609260000`. The files are created
outside the measured operations. `add_many` starts with one archive member. Creation measures mutate
(add plus finishAdditions) and total. Existing PROBE-TSV column meanings are unchanged.

PROBE-PROGRESS reports credit count, distinct completion values, maximum gap from begin through the
last credit, and the tail through didPublish. The selected format list is shared with the existing probes.

[many-baseline.patch](data/2026-09-27-p6a/many-baseline.patch) contains only the many-file test/configuration
changes for B-P6 (`b191380`); `git apply --check` against exported original test files passed. It omits
the new ledger hooks and requires only total for baseline creation, whose mutate span did not exist.
Apply it only to the isolated B-P6 KF export. Both baseline and final use the same KK/GK pins above.

AC-A9 (100k/payload totals ±5%, delete_start distinct completion ≥8, tail reporting) and AC-A10
(50k add/create ≤ baseline ×1.05) remain orchestrator measurements: optimized Debug, alternating
baseline/final, warm-up discarded, load averages below four. No speed acceptance or throttling decision
is inferred from the functional probe smoke runs. Step 0-P7 remains a separate gate after S39 acceptance.

## S39 correction 1

The orchestrator reported that the normal Xcode test host, using isolated GK `b9da4bc` / KK `823ad46`,
passed build-for-testing and 291 tests across 14 related classes. Its 1,687-test full-suite run, made
while the screen was locked, also exposed five stale progress expectations in addition to GUI failures.
Those results precede this correction and were supplied by the orchestrator, not run in this correction.

**The spec's AC-A11 table omitted these five tests.** Per the correction instruction, they extend that
table and follow its rule: “assert を消さず、同じ時点の同じ命題を新しい単位で書く”. Only the following test
expectations and their observation helper changed; all original cancellation/error, archive bytes,
generation, cleanup and publication assertions remain.

- `DragInTests.testCancellationPartwayPreservesOriginalBytesAndGeneration` and
  `testFailureAfterFirstItemLeavesOriginalUntouched`: assert `fileCompletedCount == 1` after stopping.
  The existing ledger credit hook records byte completion; samples, including initial zero and final
  completion, must be monotonic. Every credit and the final value must be at most its total. Final
  completion must equal the last credit in the first addition's slot.
- `DragInTests.testCancellationAfterStagedCommitStillLeavesOriginalUntouched` and
  `testFailureAfterStagedCommitStillLeavesOriginalUntouched`: assert `fileCompletedCount == 1` and
  `completedUnitCount == totalUnitCount - 1`, preserving the uncounted publication unit at `willPublish`.
- `ArchiveImportSafetyTests.testNewArchivePanelCancellationStopsSingleFileCompression`: at the same
  work-file appearance checkpoint, assert `fileCompletedCount == 0` and
  `completedUnitCount < totalUnitCount`. The file can have processed bytes without having finished.

The whole-tree search was `rg -n 'completedUnitCount|totalUnitCount' KaitoFinderTests`: **154 matching
lines in 39 files before correction**. Every match was reviewed in context; no additional stale
item-count assertions were found. The [file-by-file audit](data/2026-09-27-p6a/correction-1/progress-audit.md)
lists all 39 files and the reason each expectation remains valid; the
[raw search](data/2026-09-27-p6a/correction-1/progress-audit-before.txt) preserves the original line numbers.
In particular, the other two ArchiveImportSafetyTests zeros occur before the first addition credit;
DeferredSaveDocumentTests' pre-commit one is a counted rename. Direct ledger-nil publish/replay tests,
split archive budgets, extraction/batch counts, synthetic UI fixtures and explicit byte budgets keep
their existing units.

Correction verification used `build/s39-p6a-correction-1`. The test module was rebuilt from all 160
current test sources against the existing `build/s39-p6a-final` app/framework and pinned dependency
products. Before reuse, all 280 exported dependency source files were compared with their `git archive`
contents, compiled Swift-source hashes were checked, and all compiled app sources were compared with
the canonical working tree: zero mismatches. No live sibling checkout was built. The build succeeded;
its warnings concern unchanged code. Compiler argv, source hashes and helper scripts remain in the
correction build directory; [reuse checks](data/2026-09-27-p6a/correction-1/reuse-checks.json),
[compiler output](data/2026-09-27-p6a/correction-1/test-build.log) and
[test argv, environment, exit codes and results](data/2026-09-27-p6a/correction-1/test-results.json)
are recorded with the individual test logs.

Exactly these build/test commands ran for this correction:

```sh
python3 build/s39-p6a-correction-1/build-tests.py
python3 build/s39-p6a-correction-1/run-tests.py \
  DragInTests/testCancellationPartwayPreservesOriginalBytesAndGeneration \
  DragInTests/testFailureAfterFirstItemLeavesOriginalUntouched \
  DragInTests/testCancellationAfterStagedCommitStillLeavesOriginalUntouched \
  DragInTests/testFailureAfterStagedCommitStillLeavesOriginalUntouched \
  ArchiveImportSafetyTests/testNewArchivePanelCancellationStopsSingleFileCompression
```

The four DragIn selections each passed (exit 0): **4 passed, 0 failed, 0 skipped**.
The ArchiveImportSafety selection started, then exited **69** with `ClientCallsAuxiliary` /
`HostCallsAuxiliary` XPC connection errors and no completed test result. It is **not verified** by this
run and needs the normal Xcode test host; its log is
[here](data/2026-09-27-p6a/correction-1/005-ArchiveImportSafetyTests-testNewArchivePanelCancellationStopsSingleFileCompression.log).
The wrapper exits 0 independently of the child test exits; the results above use the child exits.
No full suite, Xcode build-for-testing, performance probes or volume tests were rerun for this correction.

`git diff --check` and correction-scope/hash checks passed. Product code is unchanged from the incoming
S39 tree; no product bug was identified. No commit, sibling edit, published release-note edit, plan
document edit or P7 work was made.

## オーケストレータの検証（通常の Xcode test host、2026-09-27）

隔離の三つ組（GyoshukuKit b9da4bc・KaitoKit 823ad46 は `git archive`、KaitoFinder は作業ツリー）。

| 実行 | 結果 |
|---|---|
| build-for-testing | 成功 |
| 関係する 14 クラス（ArchiveWriteProgress・ByteProgressIntegration・ArchiveCreation・ArchiveEdit・ArchivePasswordEditing・ArchiveRewrite・DeferredSaveDocument・SevenZipUpdatePassword・ArchiveImportConflict・SevenZipUpdateEdit・TarUpdateEdit・DeferredSplitSave・LHAUpdateDeferredSave・WordingAcceptance） | 291 件、失敗 0 |
| 全件（画面ロック中） | 1,687 件、skip 38、失敗 31（予期しないもの 11）。S39 による失敗は、仕様の AC-A11 の表に漏れていた `DragInTests` の 4 件と `ArchiveImportSafetyTests.testNewArchivePanelCancellationStopsSingleFileCompression`（項目数の進捗を期待していた）。ほかは画面ロックと host が前面でないことによる GUI の失敗 |
| correction 1 の後（試験だけの修正。製品は検証した build と byte 一致） | DragIn・ArchiveImportSafety・QuickLookOpen・ArchiveWriteProgress・ByteProgressIntegration は失敗 0。`ArchivePasswordUITests` の 8 件は画面ロック中に失敗したが、S39 の前の build（786ec4c）でも同じ条件で同じ 8 件が失敗した |

性能の受入計測（AC-A9・AC-A10）は `many-baseline.patch` を当てた B-P6（b191380）と交互に採り、この節の後に追記する。
