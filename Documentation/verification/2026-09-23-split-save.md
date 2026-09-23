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
gatekeeper refusal selects the ZIP rewriter fallback, with a user notice. W and the published set are reopened and
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
| `rolledBack` | Failure; retain pending edits and dirty state. Scope 4(e) requires reopening before further editing even when restoration is proved. Offer Finder for any retained staging. |
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

On `usesAppleDouble` file systems, neither marker xattr is written. Carried xattrs also stay off the output members
so publication cannot create `._*` siblings. An app-owned `volume-metadata.json`, protected by flock and atomic,
fsynced JSON replacement, stores layout, set identity and carried attributes under volume UUID + relative gate path
+ gate inode. Sessions recover quarantine from that store. Journals carry the new and previous metadata: forward
recovery persists it before `done`, and proved rollback rekeys the old record when FAT/SMB rename changes its inode.

`ArchiveDocumentController.openDocument` discovers unresolved same-stem journals before normalizing a member to
its gate. `ArchiveDocument.read(from:)` performs the same read-only discovery and throws a recoverable error.
Opening `.003` while `.001` is in staging therefore offers “中断した保存を完了して開く”. Recovery runs asynchronously
on the existing serial recovery queue, then reopens the gate. HELD offers Finder; an active owner gives a retry message.

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
proved rollback/read-only reopening, encrypted split refusal, committed cleanup versus held verification, S7 crash
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
| Identical printed modification dates | Test precision mismatch. The app still obtains seconds and nanoseconds from the new published gate's `st_mtimespec` identity. Tests compare those integers exactly and the document Date to a fresh `lstat` timestamp within 1 microsecond. |
| Busy test throws `setChanged` at owner begin | Test setup defect before the busy scenario starts: parent was canonical `/private/var`, layout members were `/var`. The owner now uses `publicationLayout()` and its parent, matching the production path; teardown always cancels it. |
| tar growth gives four volumes rather than five | Incorrect hard-coded test count. Growth and shrink now use `ceil(actual W length / S)`, assert a real increase/decrease, and verify the entire published filename set plus absence of every retired tail. |

Round-1 source changes: `ArchiveDocument.swift`, `ArchiveCapabilities.swift`, `ArchiveSession.swift`;
tests: `ArchiveDocumentControllerTests.swift`, `ArchiveSplitVolumeTests.swift`, `DeferredSplitSaveTests.swift`,
`DeferredSplitSaveInteropTests.swift`; documentation: `design.md` and this record.

Round-1 local verification: `xcrun swiftc -parse` passed for all 30 changed/new Swift files; the complete app module,
app SIL and test SIL passed with the strict Swift 6 flags above against real library modules; `git diff --check`
passed. No hosted XCTest rerun, `xcodebuild`, commit, branch switch or Codex/companion launch was performed.
