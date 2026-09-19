# 引き継ぎ仕様（2026-09-19 のリリースレビュー）

**B1 は 2026-09-19 15:2x にオーケストレータが実装した**（ユーザーの指示、advisor と相談）。
記録は `../verification/2026-09-19-release-review.md`。以下の B1 節は実装時の仕様として残す。

Codex の利用上限は 2026-09-21 20:32 JST に解除。実装は Codex、検証はオーケストレータ（design §11.1 の標準手順）。

## B1 — 編集可否の判定を既存 reader から導く（文書オープンの 3 回解析 → 1 回）


Repository: /Users/nagash/Github/KaitoFinder. Depends on GyoshukuKit `ArchiveUpdater.probe(url:)` (spec G2, landed in
../GyoshukuKit) — read its doc comment and tests first. Do not commit.

Evidence: ArchiveCapabilities.inspect(url:format:password:) (KaitoFinder/Model/ArchiveCapabilities.swift) re-opens the
archive with ArchiveReader.open for ZIP (a full central-directory parse) and then ArchiveUpdater.open (another full
parse inside GyoshukuKit); for tar/7z/LHA it calls ArchiveRewriter.open which is another full parse + O(entries)
representability walk. ArchiveSession.init, reloadAfterMutation (after every edit) and refreshCapabilities (every
accepted password) all call it. Measured: one open of a 100k-entry ZIP = 0.33 s; document open pays three.

Change:
1. Add `ArchiveCapabilities.inspect(reader: ArchiveReader, url: URL, password: String?)` that uses `reader.format` and
   `reader.entries` (encrypted check) and performs only the cheap gatekeeping: ZIP → `ArchiveUpdater.probe(url:)` and
   compare its entryCount with `reader.entries.count` (mismatch → the same refusal `open` would give: check what
   ArchiveUpdater.open throws for the count mismatch and mirror it); tar/7z/LHA → keep FormatDetector.detect and the
   rewriter representability check but WITHOUT a second parse: if ArchiveRewriter has (or G2 added) an entry point that
   accepts an existing reader or a representability check over `[ArchiveEntry]`, use it; otherwise memoise the rewriter
   probe result per (sourceIdentity, passwordRevision) in ArchiveSession so it runs once per generation, and say so.
2. ArchiveSession.init, reloadAfterMutation and refreshCapabilities pass their freshly opened reader; keep the
   url-based `inspect(url:format:password:)` for callers that have no reader (grep them; e.g. LargeArchiveTests uses it —
   keep it working, implemented on top of the reader-based one).
3. Cache `hasEncryptedHeaders` per source identity + password so reloadAfterMutation does not re-open a 7z a second time
   when identity and password are unchanged.
Tests: a DEBUG-only static counter on the app's ReaderOptions factory call sites is not possible (KaitoKit opens), so
count via a test hook in ArchiveReaderOptions (e.g. `ReaderOptions.kaitoFinder` increments a `nonisolated(unsafe)`
DEBUG counter) — assert `ArchiveSession(url:)` on a ZIP performs exactly 1 factory call (today 2 + the updater's
internal open which is not counted: state that), and `createFolder` performs ≤ 2 after publish (the publish
verification open + the reload). Also a timing test on the 100k fixture (Release only, skip in Debug): session init <
1.5 × bare open. All ArchiveRewriteTests / ArchiveEditTests / ArchivePasswordEditingTests / CompressionCapabilityTests /
ScenarioExternalChangeTests must stay green (they encode every refusal reason).
Docs: verification record entry with the before/after open timings at 100k and 500k entries (build with the Python
zipfile method from 2026-09-16-scale.md; the orchestrator runs the measurement).

### GyoshukuKit 側の追加（B1 の tar / 7z / LHA 部分に必要）
`ArchiveRewriter.open(url:…)` の表現可能性の walk（名前の正規化、entry 種別、hard link の参照、日時の表現範囲、
LHA の CP932/32 bit サイズ、正規化名の衝突）は `reader.entries` と `format` だけに依存する。
これを `static func validateRepresentability(entries: [ArchiveEntry], format: ArchiveFormat) throws -> (names, hardLinkTargets, dataTargets)`
に切り出し、`open` と新しい `ArchiveRewriter.probe(entries:format:)` の両方から呼ぶ。圧縮 tar では `open(url:)` が
内側の tar をもう一度一時展開するため（K1 の記録）、この probe が無いと B1 の効果が出ない。

### 現状のコスト（B1 の動機）
100,000 項目 stored ZIP の `ArchiveReader.open` は 230 ms。文書オープンで session / inspect / updater の 3 回、
編集後も同じ回数。G4 の防御（`ArchiveUpdater.open` の CD walk）で `ArchiveUpdater.open` は 465 ms になり、
100,000 項目で約 230 ms、500,000 項目では約 1.2 s の一時的な遅延がオープン・編集ごとに加わる（データ破損防止の門番
のために受け入れた回帰）。B1 で inspect が `probe`（0.2〜2.5 ms）を使えば解消する。

## サイドバーの文言（A9/A14）
「大きなファイルです。プレビューを表示するには読み込みが必要です。」が solid メンバーにも表示される。
このキーは 2026-09-19 に追加したもので、両方を覆う文（例:「このファイルの読み込みには時間がかかる可能性があります。
プレビューを表示するには読み込みが必要です。」）へ 26 言語とも差し替える。`materialization.cachedItem(for:)` が
ある項目は閾値に関わらず自動表示してよい。

## 検証（ロック解除後）
`python3 Tools/verify_ui_integration.py`、`python3 Tools/verify_finder_interactions.py`、`python3 Tools/verify_preview_sidebar.py`、
および key window 依存の 9 件（`ArchiveConflictUITests` 1、`ArchivePasswordUITests` 6、`ArchivePreviewSidebarTests` 1、`ArchiveTabTests` 1）。
