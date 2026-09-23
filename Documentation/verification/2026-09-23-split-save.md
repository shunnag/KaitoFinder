# M5 split-save implementation and verification handoff

Implemented on `feature/split-archive-editing`, without committing or changing either sibling library.
This record describes local verification. Hosted XCTest execution and the integration review belong to the orchestrator.

## Behavior and integration

On-save documents edit numbered byte-split 7z, tar, tar.gz, tar.bz2, tar.xz, LHA and ZIP sets. Native split ZIP
remains read-only. Immediate editing and the single-file publication guard remain protected; only the requested
immediate-mode refusal wording changes. Password, representability, every-member permissions and parent permissions
remain editing gates. M4 pending reads use the assembled reader and staged additions.

`ArchiveSplitWorkProducer.produce(source:workURL:mode:password:options:plan:progress:verifyAssembledInput:)`
produces W independently of the output stem, naming scheme and schedule. `ArchiveVolumeInput` captures/verifies
the source set. Rewriters, including the tar-owner-preserving path, call the publication's
`verifyAssembledInput(rewriter.volumeSet)` before replay. ZIP uses the shared streaming copier with member fd/path,
identity and applicable hash checks before and after copying; it then updates the joined W. Only an updater
structural refusal (gatekeeper, invalid archive or non-relocatable entry) selects the ZIP rewriter fallback, with a user notice. W and the published set are reopened and
their normalized entry-name multisets are checked against the replay plan.

The document itself is always the split publisher's coordination presenter. The injected coordinator timeout test
withholds the completion callback and verifies failure before S5. Coordination remains outside the uncancellable
publication boundary; the document's critical-section lease continues through clearing pending state and applying
the change-count token. File URL is kept/resynchronized to the document's original gate spelling, and successful
saves use the new gate's mtime.

| M2 result | Document result |
| --- | --- |
| `committed(cleanupFailed: nil)` | Success; reload, clear pending/staging/undo, apply token and new mtime. |
| `committed(cleanupFailed: warning)` | Success and clean, with a cleanup notice. A reload failure likewise reports the existing saved-but-reopen notice. |
| `rolledBack` | Failure; prove every restored member, re-anchor the reader/identity without advancing generation, and retain pending edits and dirty state. Save retry and Save As remain available. Offer Finder for any retained staging. |
| `rollbackIncomplete`, `publishedReaderFailed`, `publishedVerificationPending`, `unresolvedPublication`, simulated interrupted publication | Failure; retain pending/dirty state, disable editing until reopened, and offer Finder for staging. |
| `ownerAlive` | Retry message; no disk changes, pending retained, editing remains available. |
| Coordination timeout / other pre-S5 failure | Failure with original volumes untouched and pending retained. |
| More than 128 volumes | Size sheet before begin where predictable; otherwise discard preparation, remember a replacement size for the next Save. Never begin twice in one save. |

Uniform sets keep S. Uneven sets offer original lengths (i < n keeps Li, thereafter max of the last two), the most
common size (larger wins ties), one `.001`, or a custom KB/MB/GB size of at least 64 KiB. The choice is remembered
for the document and recorded on publication. Cancel yields a user-cancelled save, including close/quit saves.
FAT/exFAT, network and provider/sync hazards request consent before begin, once per document after acceptance;
Cancel is the default button. Non-APFS ZIP preparation also accounts for the joined work file and updater copies.

APFS/HFS+ gates receive `com.shunnag.KaitoFinder.volume-layout` (stem, width, schedule); every published member
receives `com.shunnag.KaitoFinder.volume-set` (UUID, generation, index, count, whole-W SHA-256). A singleton restores
its schedule when reopened. Conflicting markers disable editing while preserving reading; unmarked external
volumes are not subjected to marker comparisons.

On `usesAppleDouble` file systems, neither KaitoFinder marker xattr is written. Quarantine and other attributes
already carried by the source volumes are still written to the output members; unmarked members acquire no marker
sidecars. An app-owned, flock-protected atomic `volume-metadata.json` caches layout, set identity and carried attributes
under volume UUID + relative gate path + gate inode + gate size + SHA-256 of the first/last 64 KiB. Legacy/stale cache
records are ignored. Cache writes follow durable `done`; failures are warnings, never prerequisites for commit or
proved rollback. Quarantine is present on the volumes independently of this cache. Cache writes prune oldest entries
to remain below the 16 MiB read limit. A consistently renamed or duplicated native set is not mixed; stale layout
names are ignored and membership checks compare UUID/generation/count/index among the actual assembled members.

`ArchiveDocumentController.openDocument` first reuses a matching live document (even with a temporarily absent gate).
Only then does it discover same-stem unresolved journals. `ArchiveDocument.read(from:)` shares that discovery.
Live staging ownership is skipped. Invalid but attributable journals still offer recovery/Finder. A `done` journal,
or an `abandoned` journal with the complete old set proved at the final names and an absent next member, does not
block opening. AppKit's synchronous recovery entry starts asynchronous recovery and returns false immediately;
the delegate entry uses the same worker and completes its callback after reopening. Cleanup-only failures return
a recovered result with retained cleanup, while unproved live data still holds its backup. Held documents suppress
the window-key external-change check and disable Save As until recovery.

## Changed files

Paths below are relative to the repository root; the five new implementation files and two new test files are marked.

| Area | Files |
| --- | --- |
| Document/save/open | `KaitoFinder/Documents/ArchiveDocument.swift`, `ArchiveDocumentController.swift`, **new** `ArchiveVolumeOpenRecovery.swift` |
| Capabilities/session/results | `KaitoFinder/Model/ArchiveCapabilities.swift`, `ArchiveSession.swift`, `ArchiveSetIdentity.swift`, `ArchiveVolumeLayout.swift`, **new** `ArchiveSplitSave.swift` |
| W production and publication | **new** `KaitoFinder/Import/ArchiveSplitWorkProducer.swift`; `ArchiveDeferredTarWriter.swift`, `ArchiveSaveReplayPlan.swift`, `VolumePlan.swift`, `VolumePublishCriticalSection.swift`, `VolumePublishOperations.swift`, `VolumeSetPublisher.swift`, `VolumeSplitter.swift` |
| Metadata and recovery | **new** `KaitoFinder/Persistence/ArchiveVolumeMetadata.swift`; `VolumePublishFileSystem.swift`, `VolumePublishJournal.swift`, `VolumePublishRecovery.swift`, `VolumePublishRecoveryQueue.swift`, `VolumePublishTransaction.swift` |
| UI and wording | **new** `KaitoFinder/UI/ArchiveSplitSaveSheet.swift`; `ArchiveWindowController.swift`; `KaitoFinder/Resources/Localizable.xcstrings` |
| Tests | **new** `KaitoFinderTests/DeferredSplitSaveTests.swift`, **new** `DeferredSplitSaveInteropTests.swift`; `DeferredSaveDocumentTests.swift`, `ArchiveSplitVolumeTests.swift`, `ArchiveDocumentControllerTests.swift`, `WordingAcceptanceTests.swift` |
| Documentation | `README.md`, `Documentation/design.md`, this new record |

## Added tests

`DeferredSplitSaveTests` has 15 tests: the seven-format add/delete/rename matrix, second-save no-op and a further edit
using a freshly fetched node, growth from three volumes and shrink from five using actual W length (including a full
last ZIP volume), singleton schedule reopening, all four uneven choices and cancel,
hazard refusal/acceptance and once-per-document consent, presenter timeout before S5, external `.003` changes,
proved rollback and retry, encrypted split refusal, committed cleanup versus held verification, S7 crash
and controller recovery discovery, mixed native xattrs, M4 extraction, ZIP fallback notice, and FAT32 no-sidecar
publication with singleton reopen/rollback/reopen/grow. Matrix assertions compare all concatenated volumes to the
captured W, content, schedule, next-name absence, cleanup/index state, disposed originals where Trash succeeds,
document cleanliness, gate URL and mtime.

`DeferredSplitSaveInteropTests` has 5 tests: real `7zz a -v16k` for 7z/tar and Info-ZIP byte-split ZIP, `7zz t` without
tail warnings and `7zz l` volume count after editing, different-stem W production and source rejection before replay,
real native split ZIP refusal, busy/max-count preflight, and any-member permission/immediate-mode refusal.
Command-dependent tests `XCTSkip` if either `/opt/homebrew/bin/7zz` or `/usr/bin/zip` is unavailable. The FAT32 test
uses the existing `KFPUBLISH` (9 ASCII characters) disk label and registers detach in teardown; the helper also detaches
on initialization failure/deinit.

Existing deferred split reservation coverage now expects dirty pending changes with unchanged volume bytes.
Immediate refusal assertions use the new text. Wording coverage adds all 26 new keys in all 26 languages.

## Local verification and remaining execution

- `xcrun swiftc -parse` on all 29 changed/new Swift files: passed.
- Complete application module and SIL generation against the real local KaitoKit/GyoshukuKit build products: passed.
- Complete test-target SIL generation against that application module and real XCTest: passed.
- Compiler flags include Swift 6, complete strict concurrency, MainActor default isolation,
  `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`, targeting arm64 macOS 26. No API stubs were used.
- Catalog validation: 379 keys / 9,854 translated values, including 26 new keys × 26 languages; ordered format
  specifiers, nonempty translated values, Japanese style/new-placeholder spacing, Spanish compressed-archive
  vocabulary, and applicable German/French/ellipsis/sentence-ending rules passed.
- `git diff --check`: passed. Existing SDK `_SwiftifyImport` warnings and an existing `AnyClass?` inference warning
  in `ArchiveDocumentControllerTests` remain; no new compile errors or concurrency diagnostics.

No `xcodebuild`, hosted XCTest execution, UI/manual consent exercise, real interop execution or image mounting was
performed in this implementation turn. The orchestrator still needs build-for-testing, the two new test classes,
M2/M3/M4 regressions and WordingAcceptanceTests, the full suite, and one integration review. M6 immediate editing/
split Save As and M7 native split ZIP editing remain outside this change.

## Orchestrator targeted run — correction round 1

Reviewed every XCTest error in the supplied `scratchpad/m5-targeted.log`: 4 controller diagnostics, 23 split-save
diagnostics and 4 interop diagnostics. The orchestrator reports the existing M0–M4/M2, wording and termination
classes passing. The corrections below have not yet been rerun in the hosted target.

| Failure | Classification and correction |
| --- | --- |
| Old controller refusal text | Stale expectations for numbered sets. Native split ZIP also exposed an app wording defect: both URL/reader capability inspection and session publication refusals now use `nativeSplitArchive`, with the existing “ZIP本来の分割アーカイブは変更できません。” in either mode. No new localization keys. |
| `/var` versus `/private/var` assertions | The fixture's target-equivalence check was too literal, and the app really did change the document URL: save's defer assigned `layout.gateURL`, which KaitoKit had standardized. Save now captures and restores the document's original URL. Tests compare resolved target URLs and separately assert that each save preserves the exact original document/source URL spelling. |
| Second Save stale-selection / later reservations archive-changed | App defect caused by that reassignment. The exact-URL save guard rejected the next save; location synchronization treated the spelling change as a forbidden split-set move. Preserving the original URL fixes both paths. |
| Suspected stale identity or pending generation | The session already reloads after `publish()` returns, after S11/commit/cleanup, through its unchanged source URL. It recaptures all members and the next name; pending reset plus display installs the new generation. New assertions check the session identity against the published identity and fresh capture, volume lengths/count/next name, advanced generation and rebased editor after every successful fixture save. The seven-format test now also edits a newly fetched node after the no-op second save. |
| Identical printed modification dates | **Application defect, corrected after integration review.** Epoch-first `Date` construction introduced a 1-ULP difference that AppKit treated as an external modification. Use reference-date arithmetic, identical to Foundation; tests again require exact equality with FileManager. The earlier “test precision mismatch” conclusion was incorrect. |
| Busy test throws `setChanged` at owner begin | Test setup defect before the busy scenario starts: parent was canonical `/private/var`, layout members were `/var`. The owner now uses `publicationLayout()` and its parent, matching the production path; teardown always cancels it. |
| tar growth gives four volumes rather than five | Incorrect hard-coded test count. Growth and shrink now use `ceil(actual W length / S)`, assert a real increase/decrease, and verify the entire published filename set plus absence of every retired tail. |

Round-1 source changes: `ArchiveDocument.swift`, `ArchiveCapabilities.swift`, `ArchiveSession.swift`;
tests: `ArchiveDocumentControllerTests.swift`, `ArchiveSplitVolumeTests.swift`, `DeferredSplitSaveTests.swift`,
`DeferredSplitSaveInteropTests.swift`; documentation: `design.md` and this record.

Round-1 local verification: `xcrun swiftc -parse` passed for all 30 changed/new Swift files; the complete app module,
app SIL and test SIL passed with the strict Swift 6 flags above against real library modules; `git diff --check`
passed. No hosted XCTest rerun, `xcodebuild`, commit, branch switch or Codex/companion launch was performed.

## M5 integration corrections applied alongside uncommitted M6

The user reports the M6 split Save As/immediate/deferred/interoperability/edit/undo/creation/wording classes passing
in the orchestrator. Three controller expectations were stale. `ArchiveDocumentControllerTests` now calls the
uniform set editable and irreversible, checks disabled undo, retains the native split ZIP wording, and adds the
uneven-set refusal. The test with “ReadOnly” in its name was renamed.

All paths still use the same `ArchiveSplitWorkProducer`, split pipeline and M2 publisher. No parallel implementation,
commit, branch switch, sibling-library edit or Codex/companion launch was introduced.

Paths in this table are relative to `KaitoFinder/`; test names are in `KaitoFinderTests/SplitSaveCorrectionTests.swift`
unless another class is given. Each behavioral regression assertion targets the pre-correction failure described
in the review; hosted XCTest red/green execution remains for the orchestrator. The standalone Foundation timestamp probe below independently reproduces and verifies item 1.

| Item | Change locations and behavior | Regression coverage | Not done |
| --- | --- | --- | --- |
| 1 — exact mtime | `Model/ArchiveSetIdentity.swift` supplies reference-date arithmetic to `ArchiveSplitSave.swift`; `Documents/ArchiveDocument.swift` reads Foundation's date when switching after Save As. Original URL spelling is preserved. | `testPublishedDateExactlyMatchesFoundationAcrossNanoseconds`; restored exact `DeferredSplitSaveFixture.assertSaved`; immediate retry and both-mode `ArchiveSplitSaveAsTests` exact-date assertions. | No AppKit second-save automation run locally. |
| 2 — AppKit recovery | `Documents/ArchiveVolumeOpenRecovery.swift` implements both recovery entries through one asynchronous flow; sync returns false and reopens on completion. File/Open Recent, Finder, welcome/window drop use the common controller/read error. | `testAppKitSynchronousAndDelegateRecoveryEntriesRecoverThenReopen` invokes the bridged NSError's NSObject methods from the actual SDK declaration. | GUI entry points not manually exercised locally. |
| 3 — rollback/held | `Import/VolumeSetPublisher.swift` proves old members; `Model/ArchiveSplitSave.swift`, `ArchiveSession.swift` re-anchor reader/identity without advancing the pending generation. `ArchiveDocument.swift` adopts the proved rollback timestamp and skips external-change checks while held; `UI/ArchiveWindowController.swift` disables held Save As. | `DeferredSplitSaveTests.testProvenRollbackKeepsPendingAndCanRetryWithoutReopening`; `testProvenRollbackRetainsGenerationAndAllowsSaveAsOnFAT`; `testHeldWindowKeyCheckDoesNotPresentExternalChangeOrAllowSaveAs`; immediate rollback retry test. | Held edits cannot be exported while the underlying set is unproved; Save As is explicitly disabled. |
| 4 — errors/FAT32 | `Import/VolumePlan.swift` exhaustively localizes every `VolumePublishError`; `UI/ArchiveErrorText.swift` uses those messages, including preflight errors. `ArchiveDocument.swift` checks the FAT work limit before schedule/consent/work and reports the real space requirement. M2's shared begin rejects FAT work length >= UInt32.max for Save As too. | `testAllPublisherErrorsHaveActionableLocalizedDescriptions`; `testFATWorkLimitRefusesBeforeWritingWithSpecificMessage`; new wording acceptance coverage. | Chosen permitted alternative: clear early refusal. No work-file relocation to the startup disk. |
| 5 — quarantine | `Import/VolumeSplitter.swift` omits only KaitoFinder's markers, retaining source xattrs and the set's quarantine on AppleDouble volumes. Save As uses the same splitter and source-quarantine rule. | `testAppleDoubleQuarantineSurvivesDeferredImmediateAndSplitSaveAs` on FAT32/exFAT; `testAppleDoubleOnlyCopiesAttributesToMatchingOldMembers`; existing clean-source no-sidecar tests retained. | SMB mount test not run locally. |
| 6 — rename/duplicate | `Persistence/ArchiveVolumeMetadata.swift` ignores stale layout names; mixed detection uses member UUID/generation/count/index, not paths or cross-directory uniqueness. | `testRenamedAndDuplicatedNativeSetsRemainEditableIncludingSingletons` covers both editing modes and multi/single-volume sets; existing mixed-marker refusal remains. | None. |
| 7 — cache identity | `Persistence/ArchiveVolumeMetadata.swift` matches volume UUID/path/inode/size/first-and-last-64-KiB hash; old or stale records are ignored. | `testMetadataCacheRejectsReusedInodeAndSameSizeDifferentGateBytes` retains inode, size and coarse FAT mtime while replacing sampled payload bytes; stale schedule/mixed refusal must disappear. | Uses deterministic same-inode replacement rather than depending on allocator timing. |
| 8 — cache after commit | `VolumeSetPublisher.swift`, `Persistence/VolumePublishTransaction.swift`, `VolumePublishRecovery.swift` persist the cache only after commit/verified rollback and treat write failures as warnings. Cache corruption/size cannot gate completion. `ArchiveCreationController.swift`, `ArchiveSplitSave.swift`, `ArchiveDocument.swift`, `ArchiveWindowController.swift` carry the warning through Save As. | `testMetadataWriteFailureCannotHoldCommitRecoveryOrRollback`; `testSplitSaveAsMetadataFailureSucceedsAndReportsWarningInBothModes`. | None. |
| 9 — structural ZIP refusal | `Import/ArchiveSplitWorkProducer.swift` uses its existing rewrite/validation path for updater structural refusals; source-changed/state/index errors still fail. | `testZIPStructuralRefusalUsesValidatedRewriteInBothModes` modifies only the local/CD descriptor flag agreement and checks real updater refusal, contents and notice. | Single-file M3 gatekeeping remains unchanged. |
| 10 — folder move | `Model/ArchiveSession.swift` proves every member and absent next name at the new parent, opens a replacement reader and preserves generation/schedule. `ArchiveDocument.swift` and immediate Save As synchronize to the document's moved URL. | `testContainingFolderMoveAllowsSaveRevertAndSaveAs` covers Save/Revert/Save As and immediate editing. | Individual member renames while a document is open are not treated as a containing-folder move. |
| 11 — live document/owner | `Documents/ArchiveDocumentController.swift` performs exact/canonical set lookup first, including a missing gate; discovery skips a live staging owner. Reusing a window does not add another controller. | `testAlreadyOpenSavingAndHeldSetsReuseDocumentBeforeDiscovery`. | None. |
| 12 — cleanup only | `Persistence/VolumePublishRecovery.swift` returns recovered-with-kept-cleanup after a proved forward/backward result, including cleanup exceptions. Discovery ignores a proved restored set; the open flow reports retained cleanup after opening. Unproved/missing/corrupt live sets still HOLD backups. | `testCleanupOnlyForwardAndBackwardRecoveryDoesNotBlockOpening`; existing M2 missing/corrupt-live-copy protection retained; FAT recovery expectation updated for recovered-with-kept-cleanup. | Cleanup retries through the existing recovery queue/next publication; no new scheduler. |
| 13 — inconsistent journal | `Documents/ArchiveVolumeOpenRecovery.swift` offers recovery using the parsed gate name rather than propagating raw validation errors or trusting invalid journal paths. | `testInconsistentSameStemJournalOffersRecoveryInsteadOfRawError`. | None. |
| 14 — documentation | This record, `Documentation/design.md` and the M6 verification record reflect the corrected date, rollback, metadata/quarantine and opening behavior. | Covered by the associated regression assertions above and static diff review. | None. |

Seven new strings have all 26 translations; two obsolete reopen-after-proven-rollback strings were retired. No new
format specifiers were introduced. Spanish uses “archivo comprimido” for archive wording. The save-panel accessory
layout is unchanged. Disk-image tests use the existing 9-character `KFPUBLISH` label and register detach in teardown.
Command-dependent interop skips remain unchanged.

Local verification for the correction round: full application module/SIL and full test-source SIL compile with Swift 6,
complete strict concurrency, MainActor default isolation and NonisolatedNonsendingByDefault, using real local
KaitoKit/GyoshukuKit modules and the installed SDK. Parse passed for all 31 changed/new Swift files. Catalog checks passed for 395 keys × 26 translations, including format order, Japanese placeholder spacing and the applicable wording rules. `git diff --check` passed.
A standalone probe on 129 real-file nanosecond timestamps found 92 exact-equality mismatches with the old epoch-first formula and zero with the corrected formula (`/private/tmp/kf-m5-date-probe`).
The correction round adds 17 regression methods in `SplitSaveCorrectionTests`, one uneven-opening test and one wording test, and strengthens the existing date/rollback/recovery assertions.
No xcodebuild or hosted/runtime XCTest, disk mounting, interop commands or manual GUI run was performed locally.
Temporary pre-correction source snapshots are in `/private/tmp/kf-m5-corrections-baseline`; compiler logs/scripts
are in `/private/tmp/kf-m6-check`, and catalog verification is `/private/tmp/kf-m5-catalog.py`.
