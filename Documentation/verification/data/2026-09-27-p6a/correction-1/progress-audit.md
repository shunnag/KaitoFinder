# S39 correction 1 — progress assertion audit

Command: `rg -n 'completedUnitCount|totalUnitCount' KaitoFinderTests`.

Before correction: 154 matching lines in 39 files. Each match was reviewed in its test/caller context. Only the five reported expectations need migration; no additional stale item-count assertions were found. Counts below include constructors, observations and assignments, not just assertions.

| File under KaitoFinderTests | Matching lines | Assessment |
| --- | ---: | --- |
| `ArchiveBatchExtractionTests.swift` | 5 | Batch extraction counts archives (1, 2, 3); generic completion is unchanged. |
| `ArchiveBatchExtractionUITests.swift` | 4 | Batch extraction total and synthetic 10/3 label fixture; no write ledger. |
| `ArchiveCreationTests.swift` | 3 | Already migrated byte completion and publication boundary. |
| `ArchiveCreationUITests.swift` | 1 | Synthetic Progress(totalUnitCount: 2) fixture. |
| `ArchiveEditTests.swift` | 2 | Zero before rejected plan validation; generic successful completion. |
| `ArchiveImportSafetyTests.swift` | 3 | Corrected new-archive work-file checkpoint. The other two zeros precede the first addition credit and remain valid. |
| `ArchivePasswordEditingTests.swift` | 10 | Already migrated byte completion, publication boundary, monotonic samples and fallback reset; 300 is injected commit progress. |
| `ArchiveRewriteTests.swift` | 3 | Already migrated byte completion, first commit credit and publication boundary. |
| `ArchiveWriteProgressTests.swift` | 17 | Explicit byte-ledger budgets, slot transitions, reset, overflow and KVO behavior. |
| `ByteProgressIntegrationTests.swift` | 4 | Explicit byte-ledger completion and publication boundaries. |
| `CompressedTarDeferredSaveTests.swift` | 4 | Generic session completion; entries + 2 applies to direct publish/replay with ledger nil. |
| `CompressedTarPublishTests.swift` | 1 | Generic successful completion. |
| `CompressedTarVerificationFailureTests.swift` | 2 | Single-folder mutation retains one counted unit; >1 triggers cancellation in commit. |
| `CompressionCapabilityTests.swift` | 1 | Materialization/extraction Progress(totalUnitCount: 1) input. |
| `DeferredSaveDocumentTests.swift` | 6 | The pre-commit 1 is one counted rename; reset, injected 300 and final byte completion remain valid. |
| `DeferredSplitSaveTests.swift` | 4 | Split producer uses ledger nil; its 2/1002/6 budgets are unchanged. |
| `DragCopyOutTests.swift` | 6 | Extraction progress inputs; completed 5 is the five bytes in hello, alongside fileCompletedCount == 1. |
| `DragInTests.swift` | 4 | Corrected the four item-count assumptions identified by the orchestrator. |
| `ExtractionPerformanceProbeTests.swift` | 1 | Generic extraction completion. |
| `ExtractionProgressSheetTests.swift` | 4 | Synthetic indeterminate/determinate progress fixture (0, 8/2, -1). |
| `ExtractionTests.swift` | 11 | Extraction byte budgets (12/40, 1005), deliberate unknown/overflow item fallback and progress inputs. |
| `LHAUpdateDeferredSaveTests.swift` | 1 | Generic successful completion. |
| `LHAUpdateEditTests.swift` | 2 | Generic successful completion. |
| `LHAUpdateFallbackTests.swift` | 7 | Direct ledger-nil publish/replay entries + 1, manual stub increment and generic completion. |
| `LHAUpdateVerificationFailureTests.swift` | 2 | Direct ledger-nil publish keeps the legacy 1001 budget. |
| `LayoutOverflowTests.swift` | 3 | Synthetic progress fixture (1000/345) checks the fallback label. |
| `M6bReviewTests.swift` | 3 | Split producer counts removals and carried entries with ledger nil. |
| `ParallelExtractionTests.swift` | 5 | Extraction byte budgets (250, 251, 301) and extraction cancellation threshold >21. |
| `QuickLookOpenTests.swift` | 3 | Materialization/extraction Progress(totalUnitCount: 1) inputs. |
| `ScenarioBatchTests.swift` | 1 | Completed 30 counts extracted archives in the batch service. |
| `SevenZipUpdateDeferredSaveTests.swift` | 2 | Generic successful completion. |
| `SevenZipUpdateEditTests.swift` | 1 | Generic successful completion. |
| `SevenZipUpdatePasswordTests.swift` | 5 | Already migrated completion; direct ledger-nil publish also checks generic completion. |
| `SevenZipUpdateRoutingTests.swift` | 6 | Direct ledger-nil publish/replay entries + 1, manual stub increment and generic completion. |
| `SevenZipUpdateVerificationFailureTests.swift` | 3 | Direct ledger-nil publish keeps the legacy 1001 budget; cancellation input. |
| `Support/ArchiveReencryptionTestSupport.swift` | 2 | Split password lifecycle keeps its ledger-nil 5/1001 budgets. |
| `Support/ReferenceArchiveSaveReplayPlan.swift` | 4 | Item increments in the ledger-free reference implementation for replay equivalence. |
| `TarUpdateEditTests.swift` | 7 | Generic completion; direct ledger-nil publish/replay keeps entries + 2 and legacy 1001. |
| `WelcomeWindowTests.swift` | 1 | Synthetic Progress(totalUnitCount: 1) sheet fixture. |
