# P6–P13 と P1d の実装順・接点・受入計測（ORDER-P4-P5 の続き、2026-09-26）

最終の仕様（`SP` = `/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad`）:

- `specs/final-p613/P6-P7.md`（P6-G・P6-A・P7-G・P7-A）
- `specs/final-p613/P8-P9-P10.md`（P8・P9・P10-a・P10-b）
- `specs/final-p613/P11.md`（P11-K。英語。Codex には P11.md だけを渡す。本書と `map-results.json` は出自の規則で読ませない）
- `specs/final-p613/P12-P13-P1d.md`（P12-0・P12-1・P13・P1d-G・P1d-A0・P1d-A）
- 本書（各仕様では「ORDER-P6-P13」と呼ぶ）

反証レビューの記録と根拠の計測は `specs/final-p8-p10/P8-P9-P10.reviewed.md`・`specs/P11-K-reviewed.md`・
`specs/P12-P13-P1d-reviewed.md`・`specs/p67/*-draft.md` に残す（P6・P7 の指摘 F1–F12・M1–M19 は P6-P7.md と本書に反映済み）。
S0–S26 の順序と共通の設計は ORDER23（`specs/final-p2p3/ORDER-P2-P3.md`）と ORDER45（`specs/final-p45/ORDER-P4-P5.md`）のまま。
本書は、着手前に既存の仕様・順序へ入れる文（§1）と、S27 以降（§3）を定める。P14 は仕様が未作成（§3.8）。

## 0. 状態と段の番号

### 0.1 状態（2026-09-26 01:50 ごろ）

- KaitoKit: 73c1b9f = S12（P3-K 段階 A）。作業ツリーで S14（P3-K 段階 B）の Codex が動いている。
- GyoshukuKit: efdb651 = S11（P2-G）、9fb6ee2 = S10。作業ツリーで S11 の修正 1（FAT32・exFAT の inode。`specs/S11-c1.md`）の Codex が動いている。
- KaitoFinder: e49ecf5 = P1b-A。作業ツリーで S13（P2-A）と修正 1（`specs/S13-c1.md`）の Codex が動いている。
- 読み替え: P8-P9-P10 の草案の「S11 は進行中」は誤り（S11 は commit 済みで、修正 1 が進行中）。P6-P7 の「GK の HEAD は efdb651 = S11」が正しい。
  どの仕様も行番号は起草時の commit で書いてあり、着手時は関数名で読み替える。名前が無ければ止めて報告する。

### 0.2 段の番号（旧い名前との対応）

| 段 | リポジトリ / 仕様 | 反証レビュー時の名前 |
|---|---|---|
| S27 | KaitoFinder / P9 | S13-P9 |
| S28 | KaitoFinder / P13 | P13 |
| S29 | KaitoFinder / P12-0（計測だけ） | P12-0 |
| S30 | KaitoFinder / P12-1 | P12-1 |
| S31 | GyoshukuKit / P1d-G | S15a |
| S32 | KaitoFinder / P1d-A0（計測だけ） | S16a-0 |
| S33 | KaitoFinder / P1d-A | S16a |
| S34 | KaitoFinder / P8 | S-P8 |
| S35 | KaitoFinder / P10-a | S-P10a |
| S36 | KaitoFinder / P10-b | S-P10b |
| S37 | KaitoKit / P11-K（3 回の round） | S27（P11 の版） |
| S38 | GyoshukuKit / P6-G | S27（P6・P7 の版） |
| S39 | KaitoFinder / P6-A | S28 |
| Step 0-P7 | オーケストレータ | Step 0-P7 |
| S40 | GyoshukuKit / P7-G | S29 |
| S41 | KaitoFinder / P7-A | S30 |
| S42 | オーケストレータ / release（KaitoKit 0.14.1） | P11 の「0.14.1」 |
| S43 | オーケストレータ / release（GyoshukuKit 0.11.0） | S31 の一部 |
| S44 | オーケストレータ / release（GyoshukuKit 0.12.0） | S31 の一部 |

最終の仕様は新しい番号だけを使う（旧い名前はこの表とレビューの記録にだけ残る）。番号は見込みの開始順で、依存は §3 の表が決める。

## 1. 着手前に既存の仕様・順序へ入れる文

ORDER45 §1 と同じ扱い: まだ着手していない段の仕様・順序へ先に入れる。その段が着手済みなら、同じ内容をその段の Codex thread へ一つの修正として送る。

1. **隔離の規則の範囲**: §3.2 の規則は、S27 以降の段と、それらが本線の段と時間が重なる場合に当てる。ORDER23・ORDER45 が既に許している
   本線どうしの重なり（S12・S14 ∥ S13、S18 ∥ S19、S21 ∥ S23、2026-09-26 の S14 ∥ S11 の修正 1 ∥ S13 の修正 1。どれも下流が編集中の
   `../KaitoKit` を build しうる）は今までどおりとする: 受け入れの検証は三つ組の worktree で行い（ORDER23 §3）、兄弟が build できないときは
   Codex がそう報告し、上流の commit の後にやり直す。これらにも規則を当てるなら、上流の段（S19・S23）を専用の worktree（S37 と同じ形）で行う。
2. **ORDER23 §3 の B-P3 と ORDER45 §4 の B-P4・B-P5**: §3.5 の定義に置き換える（KF は「比べる段の直前の KF の commit」）。
   B-P4 の KF は S16 ではなく、S21 の直前（S33 か S34）。改めないと、S21 の ZIP の行が P1d の改善で B-P4 ± 10 % を外れる。
3. **S21 の起動前（S27 の後）**: `specs/final-p45/P4.md:1049` の「`writerOptions(for: .lha)` は、P2-A のとおり `WriterOptions(additionPlacement:)`
   だけを持つ」を「`additionPlacement` と、設定が 0 でなければ `compressionThreads`（P9、S27）を持つ」に改める。ORDER45 §3.1（:165）と
   ORDER23 §2-2（:67）の「7z・LHA は `additionPlacement` だけを写す」も「`additionPlacement` と `compressionThreads`（0 以外のとき）を写す」に改める。
   P4-G-a（S18）は `options.resolvedCompressionThreads` を LHA の writer に渡すので、設定がそのまま効く。
4. **S21・S25 の起動前（S33 の後）**: P4-A・P5-A の probe の変更は、保存の行の trace の要件を P1d-A §A7 の規則に合わせる:
   `.representabilityDifferential` を必須、`.planKeys` は禁止、`.validateRepresentability`・`.representabilityProbe` は保存に使った mode が
   `.rewrite(_)` のときだけ必須。LHA・7z の保存の行もこれに従う（`.updaterOpen` と `.rewriterOpen` の要件は P4-A・P5-A のまま）。
5. **S17（release）**: S17 は S31 を待たない。S17 の開始の時点で S31 が受け入れ済みで GyoshukuKit の開発の branch へ merge 済みなら
   GyoshukuKit 0.8.0 に含め、そうでなければ S22 の 0.9.0 に含める。S31 の merge は、どちらの場合も S18 の開始前に行う。
6. **計画書**（`Documentation/pending/2026-09-24-large-archive-edit-plan.md`）: P1d の行（「50 万件の ZIP の編集に残る全件の名前表の作り直し
   を無くす。GyoshukuKit・KaitoFinder」）を P1c の後に足す。オーケストレータが S31 か S33 の commit で入れる。

## 2. 仕様間でそろえた接点（両側で同一）

| 接点 | 提供 | 利用 | 決定 |
|---|---|---|---|
| `ArchiveEditing.add(contentsOf:as:ownerIDs:progress:)`、`ArchiveWriter.add(contentsOf:as:progress:)` | S38 §0.5・§G1 | S39（即時の取込み・replay・新規作成） | session は呼出しごと。total は writer の lstat（directory は事前の走査）。数えるのは writer へ渡した byte。**既定の実装は投げない**: (0, 0) → ownerIDs が nil なら `add(contentsOf:as:)`、あれば `add(contentsOf:as:ownerIDs:)` → (0, 0) |
| `ArchiveEditing.finishAdditions(progress:)`（既定は (0, 0) を二度）、`ArchiveWriter.finishAdditions(progress:)` | S38 §G3 | S39 の `publish` の各枝と新規作成 | 出力の byte を変えない。以後の追加は invalidState。**instance を failed にしない** |
| `ArchiveEditing.readsAdditionsDuringCommit`（既定 false） | S38 §G4 | S39 の予算（§A3） | rewriter の `.end` だけ true |
| `ArchiveRewriter.commit(progress:didCarry:)` | S38 §G4 | S39 の `rewriteBranch`、既存の書庫からの新規作成 | total = C + A + D。`didCarry` は今日と同じ |
| `WriterOptions.maximumPendingInputBytes(for:)` | S38 §G3 | S39 の予算、S38 の rewriter の D | 機械と options だけで決まる。`resolvedCompressionThreads` を通るので、S27 の設定の並列数がそのまま効く。P14 が block を options にしたら、その値から求める |
| `ArchiveUpdater.CommitProgress` の共通の契約 | P1-G D8（ORDER23 §1） | S38・S39・S40・S41 の全ての session | 型を増やさない。KF は通知ごとの比だけを写し、total が一定だと仮定しない（`ZipCommitMeter.finish` は最後に (c, c) を通知しうる。ZipCopyEngine.swift:17-19） |
| `ArchiveAddition`・`ArchiveAdditionEvent`・`ArchiveAdditionError`、`ArchiveEditing.add(_:events:)`（既定は項目ごとの API を順に）、`ArchiveWriter.add(_:events:)` | S40 §G1 | S41（即時の取込み・新規作成・replay） | 出力は、項目ごとの API を同じ順に呼んだものと byte 一致。`WriterError` に case を足さない |
| `ArchiveWriter` の名前の検査（addEntry から切り出した internal の関数、例 `reserveEntryName(_:directory:)`）と internal の `existingPathCheck` | S31 §G4 | S38（追加を閉じた状態の検査を関数の前に置く）、S40（一括の呼出側の段が同じ関数を同じ順に呼ぶ） | 名前の検査は一か所だけ。一括でも S31 の走査の回数・budget（4）・例外は項目ごとの API と同じ（S40 AC-G1・AC-G3） |
| 試験用の乱数: 既存の `ArchiveUpdater.testingRandomBytes`（ArchiveUpdater.swift:29）、`SevenZipAESEncryptor.testingIV` | P1b（既存）、S24（P5-G の SCOPE） | S38 §G7（ZipCrypto の 11 byte、7z AES の IV）、S40 AC-G1 | 新しい TaskLocal を足さない。S24 に `testingIV` が無いときだけ、P5-G の定義で S38 が足す。TaskLocal は呼出側の thread で読むか、仕事の作成時に capture する |
| KF の台帳 `ArchiveWriteProgress`、`publish(…, ledger:)`、`replay(…, ledger:, additionBase:)` | S39 | S41 | 分割の生産は `ledger: nil`（進捗の総量を変えない） |
| `ArchiveSession.reloadAfterMutation(advancing: ArchiveNameIndexChange?)` | S33 §A4 | S39、S41 | `appended` は editor へ渡した順（即時は `plan.items` の順、保存は追加の後にフォルダ）。S39 は台帳を足しても順と advance の条件を変えない。S41 は `[ArchiveAddition]` を同じ順に作る。`NameIndexEquivalenceTests` が両段で変更なしで通る |
| `ArchiveSaveReplayPlan` の変遷 | S13（`preservingOwnerIDs:`）→ S33（`init(baseOccupancy:)`、使う index だけの `baseKeys` の memo）→ S25（予約の順「削除 → 改名 → 暗号化の予約 → 追加 → フォルダ」と `ArchiveReencrypting`）→ S39（`ledger:`・`additionBase:`）→ S41（追加とフォルダを一つの一括） | 各段 | 後の段は前の段の引数と順を保つ。`DeferredSavePlanEquivalenceTests`・`DeferredSaveAttributeTests`・`NameIndexEquivalenceTests` が各段で通る |
| `ArchiveStageDiagnostics.Stage` の追加 | S13（1 行）、S29（`split_*` の 11 段）、S32（`plan_build`・`plan_validation`・`name_index_build`・`name_index_advance`・`representability_differential`）、S34（`filter_request`・`filter_compute`・`filter_swap`）。S39 は `.mutate` を新規作成でも測る | P0b と各段の probe | case は末尾に足し、既存の case は名前で読む。`PROBE-TSV` の既存の列の意味は変えない |
| `PerformanceProbeTests` の knob と行 | S16（`PROBE-SPLICE`、`KAITOFINDER_PROBE_ADDITION_PLACEMENT`）、S29（`testSplitSavesWhenEnabled`、`KAITOFINDER_PROBE_SPLIT_VOLUME_MIB`）、S32（`KAITOFINDER_PROBE_WARM_INDEX`）、S33（`probeDeferred` の trace の要件）、S34（`testSearchFilterWhenEnabled`、`PROBE-SEARCH`）、S21・S25（LHA・7z の行）、S39（`PROBE-PROGRESS`、`KAITOFINDER_PROBE_ADD_FILES` の add_many・create_many） | 各段の受入計測 | 既定（knob なし）の動作は P0b のまま。S21・S25 の保存の行は §1-4 の規則に従う |
| `ArchivePreferences.compressionThreads` と `writerOptions(for:)` の写し、`ArchiveHardware.automaticCompressionThreads` | S27 | S21（LHA）、S25（7z）、S38・S40（上界と `prefetchConcurrency`）、P1c の確認の worker 数 | 0 = 自動（`compressionThreads == nil`）。KF の自動値は GK の `resolvedCompressionThreads` の式の写しで、GK の式が変わったら S27 の grep で気付く（GK は internal のまま） |
| `ExtractionPath.NameSyntax`、`ExtractionDestination(…, nameSyntax:)`、`ArchivePendingReadSnapshot(…, nameSyntax:)`（既定の値なし） | S28 | S33（`ArchiveDocument` の install の呼出しを変える。S28 の `init(deferredBase:)` の `nameSyntax:` はそのまま） | 一つの書庫では一つの syntax。`.posix` は `reader.format == .tar` だけ |
| `requestedFilterQuery`／`filterQuery`、`requestedShowsHiddenFiles`／`showsHiddenFiles`、`cancelFilterWork()`、`reloadFilteredEntries(…, applying:)` | S34 | S35（`displayedRoot` は `reloadFilteredEntries` の collapse の後にだけ代入する） | 適用中の値と要求した値を分ける。`setFilterQuery("")` は同期 |
| `VolumePublishOperations.didRecheckStamps`・`allowsStampRecheck` | S30 | KF の試験だけ | 既定 true。journal の schema を変えない |
| `TestProcessSetup.autosaveKeys`・`AutosaveIsolationTests` | S13（既存の変更） | S27（`ArchiveCompressionThreads`）、S35（`ArchiveFolderOpening`）、S36（`ArchiveListIconSize`・`ArchiveListTextSize`・`NSWindow Frame ArchiveViewOptions`） | 振る舞いを変える新しい key は全て足す |
| 文言（`Localizable.xcstrings`、26 言語、`WordingAcceptanceTests`） | S16（2 キー）、S25（1 キー、了承）、S27（4 キー、testJapaneseStyle の許可一覧 1 件）、S34（1 キー）、S35（7 キーと `GoMenu.xcstrings` の 1 キー、最上位のメニューの一覧）、S36（12 キー） | – | ja の値は key と同じ。書式の指定子の順序を全言語で一致させる。S28–S33・S38–S41 は文言を足さない |
| gyoshuku-bench の `--mode recursive\|items`・`--progress`（S38）と `batch`（S40） | S38・S40 | Step 0-P7、AC | `items` は公開の `addDirectory(_:)` を使う（日付は現在時刻。byte の比較には使わない） |
| KaitoKit の zstd の復号 | S37 | – | 接点なし。GyoshukuKit・KaitoFinder は S42 の merge の後の `../KaitoKit` で受け取る |

## 3. 実装順と依存

### 3.1 段の表

| 段 | リポジトリ / 仕様 | 前提（commit 済み） | 置き場所 | 作業場所（§3.2） | 終わりの条件 |
|---|---|---|---|---|---|
| S27 | KaitoFinder / P9 | S13 | S13 の後の最初の空き（S14・S11 の修正・S15 の実行中） | 三つ組 A | P9 の AC-1–8。commit |
| S28 | KaitoFinder / P13 | S13 | S16 の前の空き（S27 の後） | 三つ組 A | P13 の AC1–10。FAT/exFAT の実測を検証記録へ。commit |
| S29 | KaitoFinder / P12-0 | S13 | S16 の前の空き（S28 の後） | 三つ組 A | AC0-1–0-3。commit。B-P12 を採る |
| S30 | KaitoFinder / P12-1 | S29、B-P12 | S29 の直後（間に KF の段を入れない） | 三つ組 A | AC1–AC10。commit |
| S16 | KaitoFinder / P3-A（ORDER23） | S13・S15（と S27–S30 のうち始めたもの） | – | KaitoFinder の作業ツリー | ORDER23 のまま。P0b は §3.5 の B-P3 と比べる |
| S31 | GyoshukuKit / P1d-G | S15 | S15 の後・S18 の前（S16 と並行） | GyoshukuKit-p1d の worktree | AG1–AG5。KF の全件（KK S14、GK S31、KF S16）。branch に commit、S18 の開始前に merge（§1-5） |
| S32 | KaitoFinder / P1d-A0 | S16 | S16 の後の空き | 三つ組 B | AA0。commit。B-P1d を採る |
| S33 | KaitoFinder / P1d-A | S32、B-P1d、S31 の merge、決定 3 の了承（無ければ了承の無い形） | S32 の直後（間に KF の段を入れない） | 三つ組 B | AA1–AA9。commit |
| S34 | KaitoFinder / P8 | S16 | S16 と S21 の間の空き（§3.3） | 三つ組 B | AC1–10（AC-M は B-P8 と比べる）。commit |
| S21 | KaitoFinder / P4-A（ORDER45） | S16・S20（と S32–S34 のうち始めたもの） | – | KaitoFinder の作業ツリー（S23 との重なりは §1-1） | ORDER45 のまま。P0b は §3.5 の B-P4 と比べる |
| S35 | KaitoFinder / P10-a | S34、利用者の了承（§6-1） | S21 と S25 の間の空き。間に合わなければ S25 と S39 の間 | 三つ組 C | AC-a1–a9。commit |
| S36 | KaitoFinder / P10-b | S35 | S35 の直後 | 三つ組 C | AC-b1–b10。commit |
| S25 | KaitoFinder / P5-A（ORDER45） | S21・S24（と S35・S36 のうち始めたもの） | – | KaitoFinder の作業ツリー | ORDER45 のまま。P0b は §3.5 の B-P5 と比べる |
| S37 | KaitoKit / P11-K | S23 | S23 の後（S24・S25・S35–S41 と並行） | KaitoKit-p11 の worktree | 3 回の round と G1・G2・最終の門（P11 §ACCEPTANCE）。branch に commit |
| S38 | GyoshukuKit / P6-G | S24 の commit と S25 の受け入れ（S24 の thread へ修正を送る見込みが無い） | S25 の後 | GyoshukuKit の作業ツリー | AC-G1–G10。commit |
| S39 | KaitoFinder / P6-A | S25・S38 | S38 の後 | S40 と重なるなら三つ組 D、でなければ KaitoFinder の作業ツリー | AC-A1–A12。P0b と add_many・create_many を B-P6 と比べる。commit |
| Step 0-P7 | オーケストレータ | S38 | S39 と並行 | S38 の commit の worktree | §3.7 の計測と門。B-P7 を採る |
| S40 | GyoshukuKit / P7-G | S38、Step 0-P7 の門を通過 | S39 と並行してよい（S39 が三つ組 D のときだけ） | GyoshukuKit の作業ツリー | AC-G1–G8。commit |
| S41 | KaitoFinder / P7-A | S39・S40、§3.5 の B-P7A | – | KaitoFinder の作業ツリー | AC-A1–A6。commit |
| S42 | オーケストレータ / release | S26、S37 の最終の門 | – | – | KaitoKit-p11 の branch を KaitoKit の開発の branch へ merge し、0.14.1 を tag する（§3.2 の merge の時期） |
| S43 | オーケストレータ / release | S39 の受け入れ | – | – | GyoshukuKit 0.11.0（P6-G）→ KaitoFinder の release notes。P6 と P7 を一度に出すなら S44 にまとめる |
| S44 | オーケストレータ / release | S41 の受け入れ | – | – | GyoshukuKit 0.12.0（P7-G）→ KaitoFinder の release notes |

一つのリポジトリで同時に動く Codex は一つだけ（専用の worktree の段も数える。S31 は GK の S15 と S18 の間、S37 は KK の S23 の後で、
どちらも同じリポジトリの他の段と重ならない）。

- KaitoKit の順: S2 → S6 → (P1c) → S12 → S14 → S19 → S23 → S37（KaitoKit-p11）
- GyoshukuKit の順: S4 → S7 → S10 → S11（修正 1）→ S15 → S31（GyoshukuKit-p1d）→ S18 → S20 → S24 → S38 → S40
- KaitoFinder の順: S3 → S5 → S8 → (P1c) → S13 → {S27 → S28 → S29 → S30} → S16 → {S32 → S33、S34} → S21 → {S35 → S36} → S25 → S39 → S41
  （{} は空きを埋める段。§3.3）

P6・P7 を P3–P5 の前へ入れない理由: どちらも `ArchiveWriter`・`ArchiveRewriter`・`ArchiveEditing` と全ての updater の add の経路を変える。
S11–S24 がそれらを作り、また変えているので、先に入れると固まった仕様（P3–P5）に後から手を入れることになる。

### 3.2 作業場所（隔離の規則）

- 下流は上流を build する: KaitoFinder は `../GyoshukuKit`・`../KaitoKit` を relativePath で参照し（project.pbxproj:406-412）、
  GyoshukuKit は兄弟の `../KaitoKit` があればそれを使う（Package.swift:14-18）。
- **規則**: Codex は、別の Codex が編集中の上流の作業ツリーを build しない。次のどちらかで満たす。
  - (a) 上流の段を専用の worktree で行う。S31 は `/Users/nagash/GitHub/GyoshukuKit-p1d`（S15 の commit から branch
    `feature/2026-09-26-p1d-names`）、S37 は `/Users/nagash/GitHub/KaitoKit-p11`（S23 の commit から。P11 §1）。canonical の checkout は commit のまま。
  - (b) 下流の段を三つ組の worktree で行う: `SP/p613/triple-S<nn>/{KaitoKit,GyoshukuKit,KaitoFinder}`。KaitoKit・GyoshukuKit は
    `git worktree add --detach <commit>`、KaitoFinder は `git worktree add -b p613/S<nn> <KaitoFinder の HEAD>`。Codex は
    `--cwd SP/p613/triple-S<nn>/KaitoFinder --prompt-file <仕様>` で起動する（sandbox は cwd の下にだけ書ける）。commit の後、
    `/Users/nagash/Github/KaitoFinder` で `git merge --ff-only p613/S<nn>` し、三つ組を消す（次の空きの段は merge の後の HEAD から切る）。
- 三つ組の固定:
  - **A**（S27–S30）: KaitoKit = S14 の commit（まだ無ければ S12 = 73c1b9f）、GyoshukuKit = S11 の修正 1 の commit（まだ無ければ efdb651）。
    その段の受け入れの検証も同じ組で行う。
  - **B**（S32–S34）: KaitoKit = S14、GyoshukuKit = S31 を merge した commit（S17 の release の commit があればそれ）。
  - **C**（S35・S36）: その時点で commit 済みの最新の組（S21 の後なら KK S19 / S23、GK S20 / S24。S25 の後なら KK S23、GK S24）。
  - **D**（S39 が S40 と重なるとき）: KaitoKit = S39 の計測と同じ commit、GyoshukuKit = S38。
- 本線の段（S16・S21・S25）と S38・S40・S41 は canonical の作業ツリーで行う。本線どうしの既存の重なりは §1-1。
- **merge の時期**: (a) の branch を canonical へ入れるのは、その checkout を build する下流の Codex が動いていない時だけ。
  S31 は S16 の commit の後・S18 の開始前（S17 に含めるなら S17 の前）。S37 は S42（GyoshukuKit・KaitoFinder の段の間）。
- 検証（オーケストレータ）は今どおり、各段の commit から作った三つ組の worktree で行う。Codex が編集中の作業ツリーは使わない。
  画面のロックと古い bundle の注意は memory の xcodebuild-verification-pitfalls に従う。

### 3.3 空きを埋める段の規則

- KaitoFinder の空き: S13 → S16（S15 の commit まで）、S16 → S21（S20 の commit まで）、S21 → S25（S24 の commit まで）、
  S25 → S39（S38 の commit まで）。
- 空きの段は表の順に始める。次の本線の段の前提が commit されたら、走っている空きの段をその commit で終え（途中で止めない）、
  本線の段を先にする。始めていない空きの段は、順を変えずに次の空きへ送る。
- 続けて行う組: S29 → S30（B-P12）、S32 → S33（B-P1d）、S35 → S36。間に KF の他の段を入れない。入れた場合は、基準をその直前の commit で採り直す。
- S16 → S21 の空きの順: 送られた段（S27–S30 の残り）→ S32 → S33 → S34。S16 の commit の時点で S33 の前提（S31 の merge、決定 3 の了承）が
  揃う見込みが無ければ、S34 を S32 の前に行う（S32 と S33 を続けるため）。
- S34（P8）は S16 の前に入れない（P3-A と同じ `preferencesDidChange(_:)` と `PerformanceProbeTests` を変えるため）。
- S35 が了承待ちなら、S21 → S25 の空きは使わず、S25 → S39 の空きで行う。

### 3.4 着手の門

- **S27**: S13 の commit。P2-A の `writerOptions(for:)`（switch の形）と設定画面の「圧縮」タブがあること。
- **S28**: S13 の commit。`ArchivePendingReadSnapshot` の二つの init、`ExtractionDestination`、`ArchiveIncomingFiles.receive(progress:format:)` が P13 の前提どおり。
- **S29**: S13 の commit。`ArchiveStageDiagnostics.Stage`（S13 の形）と `DeferredSplitSaveFixture`。
- **S30**: S29 の commit と B-P12。
- **S31**: GyoshukuKit の S15 の commit。`ArchiveUpdater`・`ArchiveWriter.addEntry`・`prepareAppend`・`replaceExistingPaths`・`EditPathReservations`・
  `testingRandomBytes` が P1d-G の前提の名前であること。
- **S32**: S16 の commit。
- **S33**: S32 の commit、B-P1d、S31 の merge、決定 3 の了承（§6-2。了承が無ければ P1d-A §A5 の「保存の前の検査」を外した形で起動する）。
- **S34**: S16 の commit（`preferencesDidChange` に P3-A の注意書きの再計算がある）。
- **S35**: S34 の commit、利用者の了承（§6-1）。**S36**: S35 の commit。
- **S37**: S23 の commit。P11 §1 の start gate（worktree が clean、`Codecs/Zstd` と zstd の試験が 73c1b9f と同じ）と `inbox/zstd` の SHA-256。
- **S38**:
  - S24 の commit に次があること。名前が違えばそれに従い、無ければ始めずに報告する:
    - efdb651 で確かめ済み: `CommitProgressMeter`（`init(total:progress:)`・`start`・`advance`・`finish`。SplicedArchiveOutput.swift:34-60）、
      `ArchiveOwnerIDs`、`DiskSignature`、`ArchiveWriter` の internal の `add(contentsOf:as:ownerIDs:expected:)`（:142-149）と
      `addDirectory(_:modificationDate:ownerIDs:)`（:160-166）、`TarUpdater.commit(progress:)`、`ArchiveUpdater.testingRandomBytes`（:29）。
    - S31: addEntry の名前の検査の internal の関数と `existingPathCheck`（関数が無ければ、S38 が addEntry からこの形に切り出してから使う。
      挙動は変えない）。
    - S24 で確かめる: `CompressedTarUpdater`・`LHAUpdater`・`SevenZipUpdater` の `commit(progress:)`、`SevenZipAESEncryptor.testingIV`
      （無ければ P6-G §G7 で足す）。
- **S39**: S38 の API が P6 §0.5 の名前で commit 済み。P2-A・P3-A・P4-A・P5-A の `publish` の枝、`rewriteBranch(format:)`、`replay` の引数
  （`sourcePassword:`・`preservingOwnerIDs:`、P5-A の順）、S33 の `reloadAfterMutation(advancing:)` があること。KF の試験の `ArchiveEditing` の
  試験用の editor を grep で全部挙げること（e49ecf5: `DeferredSavePlanEquivalenceTests.StubEditor`。S13: `DeferredSaveAttributeTests.RecordingEditor`。
  S16–S36 の追加分）。
- **Step 0-P7**: S38 の commit。
- **S40**: S38 の commit と Step 0-P7 の門。S31 の名前の検査の関数。
- **S41**: S40 の API が P7 §G1 の名前で commit 済み。S39 の台帳（`ArchiveWriteProgress`）と add_many・create_many の probe。B-P7A。

### 3.5 基準の三つ組

- **一般の規則**: 基準の KaitoFinder は、比べる段の直前の KaitoFinder の commit（空きの段を含む）。GyoshukuKit・KaitoKit は、比べる段の
  受け入れの三つ組から「比べる変更」だけを除いたもの。KaitoKit と GyoshukuKit は両側で同じ commit を使う（S42 の merge を片側だけに入れない）。
- 同じ機械・同じビルド設定で測り、負荷の平均が 4 未満のときだけ数え（開始と終わりに `uptime` を記録）、各計測の最初の 1 回は捨てる
  （cache が冷えた 1 回目は openscale で 4.24 s、warm では 0.90 s だった）。
- 各段の基準:

| 基準 | 使う段 | KaitoKit | GyoshukuKit | KaitoFinder |
|---|---|---|---|---|
| B-P3 | S16 | S6（ORDER23 のまま） | S11 | S16 の直前の commit（S13 か、S27–S30 の最後）。S27–S30 が一つも入らなければ、S13 で採った B-P3 をそのまま使う |
| B-P12 | S30 | 三つ組 A | 三つ組 A | S29 |
| B-P1d-G | S31（AG5） | canonical（S14） | S15 の commit + 足した probe の操作の差分 | – |
| B-P1d | S33 | S14 | S15（commit の worktree） | S33 の直前（S32 を含む） |
| B-P8 | S34 | 三つ組 B | 三つ組 B | S34 の直前 + probe の差分（P8 §D9） |
| B-P4 | S21 | S14 | S18（S31 を含む） | S21 の直前（S33 か S34）。ORDER45 §4 の「KF: S16」を改める |
| B-P5 | S25 | S19 | S20 | S21（ORDER45 のまま S21 の計測を兼ねる）。S35・S36 が S21 と S25 の間に入ったら、KF = S36 で採り直す |
| B-P11 | S37 | 基底の commit（S23）から build した `kaito-before`（P11 V0） | – | – |
| B-P6G | S38 | S38 の計測と同じ commit | S24 | – |
| B-P6 | S39 | S39 の計測と同じ commit | S38 | S39 の直前 + add_many・create_many の試験の差分（P6 §A6） |
| B-P7 | Step 0-P7・S40 | 同上 | S38 | – |
| B-P7A | S41 | 同上 | S38 | S39 |

- 空きの段 S27–S30 は P0b の行を変えない見込み（S27 は設定が既定 0 なら options が同じ、S28 は展開と変換だけ、S29–S30 は分割巻の公開だけで、
  P0b に分割の行は無い）。S16 の P0b の比較で ±10 % を外れる行があれば、S13 だけの B-P3 と比べて空きの段の寄与を切り分けてから P3-A を判定する。

### 3.6 リポジトリをまたぐ並行の早見

| 走っている段 | 同時に走ってよい段 |
|---|---|
| S14（KK）・S11 の修正 1 / S15（GK） | S27–S30（三つ組 A） |
| S16（KF） | S31（GyoshukuKit-p1d） |
| S18・S19・S20（GK・KK） | S32–S34（三つ組 B） |
| S23・S24（KK・GK） | S21（ORDER45 のまま。§1-1）、S35・S36（三つ組 C） |
| S24・S25・S38–S41 | S37（KaitoKit-p11） |
| S38（GK） | S35・S36 の残り（三つ組 C）、Step 0-P7 の準備 |
| S40（GK） | S39（三つ組 D のときだけ） |

### 3.7 Step 0-P7（オーケストレータ、S40 の前）

暫定の計測（P7 §0.2）は負荷の平均 5.5–7.7 のときに採ったので、基準にしない。次の条件で採り直す。

0. **corpus を固定する**:
   - `$SP/corpus/small` は make-corpora.sh の出力ではない（551 directory の三階層、5 万件、202–4,002 byte、平均 2.1 KB）。
   - この corpus を基準の corpus とし、`SP/p67/corpus-small.manifest` に `find small -type f | LC_ALL=C sort | xargs stat -f '%N %z' | shasum -a 256`
     の値と、件数・byte の和・directory の数を記録する。以後の全ての計測で manifest と一致することを確かめる。
1. **run.sh の計測**: S38 の GyoshukuKit から worktree を作る。`Benchmarks/run.sh "$SP/corpus" 'zip,tgz,tbz,txz,7z,lha' small --references --mode recursive`
   と `--mode items` を、交互に 1 + 3 回（最初は捨てる）。同じ回ごとに、run.sh の外で
   `cd "$SP/corpus" && /usr/bin/time -l 7zz a -tzip -mx5 -mmt=8 -bd -bso0 -bsp0 "$out" small` も測る。各行の `wall_s`・`user_s`・`peak_rss_mib` を記録する（B-P7）。
2. **sample**: `gyoshuku-bench zip` と `tgz` の small（recursive）を `sample`（1 ms、2 s）し、呼出側の thread の内訳を
   `SP/p613/p67/caller-breakdown.sh <sample>` で採る。
3. **openscale**: `SP/p613/p67/openscale SP/p613/p67/paths.txt N` を、N = 1・2・4・8 で各 1 + 3 回（最初は捨てる）、中央値を採る。
4. **門**: 次を全て満たせば S40 を始める。満たさなければ始めずに、表と `sample` を添えて利用者に報告する。
   - zip small の呼出側の thread が 90 % 以上 busy（葉が `__psynch_cvwait`・`__psynch_mutexwait`・`__workq_kernreturn`・`__ulock_wait`・
     `mach_msg*`・`semaphore_wait*` でない sample の割合。caller-breakdown.sh の `busy`。暫定値は 1,647 のうち待ち 31 で約 98 %）。
   - `(__open + read + fstat + close) / 呼出側の sample の数` が 0.30 以上（`open`（libc の wrapper）の行は足さない。暫定値は
     (594 + 38 + 27 + 13) / 1,647 = 0.41）。
   - openscale の最良の本数の wall が 1 本の 0.6 倍以下。最良の本数を `prefetchConcurrency` の上限にする（P7 §G3 の値を置き換える。
     warm の採り直しは 4 本で 0.31 / 0.89 = 0.35）。
5. **B-P7A**（S41 の着手前）: 三つ組（KK: S39 と同じ、GK: S38、KF: S39）で、add_many と create_many
   （`TEST_RUNNER_KAITOFINDER_PROBE_ADD_FILES=50000`、zip・tar.gz・tar・7z・lha）を 1 + 3 回採り、段ごと（`mutate`・`commit`・`total`）に記録する。
   zip の add_many の `mutate` が、同じ corpus の `gyoshuku-bench zip --mode items` の wall の 1.5 倍を超えたら（KF の費用が支配的）、
   P7-A AC-A5 の閾値の見直しを利用者に報告してから S41 を始める。

### 3.8 P14（仕様未作成）

- GyoshukuKit の tar.xz の block の大きさ（計画の P14 行）。本書では段の番号を与えない。仕様を作るときの入力: S15 の区切りの配置、
  ORDER23 §6.1 の `rename_folder` の記録、S38 の `maximumPendingInputBytes(for: .tarXZ)` と P6 AC-G4（上界であること）、
  S27 の記憶の見積り（`30 + 135 × t` MiB、LZMA2 の 16 MiB の片に依る）。
- 置き場所の目安: GyoshukuKit の列の S40 の後。S38 より前に置くなら、P6-G の上界の式を P14 の値から求める。

## 4. 版

| release | 中身 | 条件 |
|---|---|---|
| S17: KaitoKit 0.12.0 / GyoshukuKit 0.8.0（ORDER23） | P3-K / P3-G G2。S31 は §1-5 の条件のときだけ含める | S16 の受け入れの後 |
| S22: KaitoKit 0.13.0 / GyoshukuKit 0.9.0（ORDER45） | P4-K / P4-G。S31 が 0.8.0 に入らなかったら含める | S21 の受け入れの後 |
| S26: KaitoKit 0.14.0 / GyoshukuKit 0.10.0（ORDER45） | P5-K / P5-G | S25 の受け入れの後 |
| S42: KaitoKit 0.14.1 | P11-K（API の変更なし。GyoshukuKit の `from: "0.14.0"` が受ける。GyoshukuKit の release は要らない） | S26 と S37 の最終の門の後 |
| S43: GyoshukuKit 0.11.0 | P6-G（KaitoKit の `from:` は 0.14.0 のまま） | S39 の受け入れの後 |
| S44: GyoshukuKit 0.12.0 | P7-G（S43 を出していなければ 0.11.0 として P6-G と一緒に出してよい） | S41 の受け入れの後 |
| KaitoFinder | 各段の release notes（`Documentation/releases/`）: P9 新しい設定（既定は自動で今と同じ）、P13 tar の `\` をただの文字として展開する（動作の変更）、P12 分割巻の保存が速い、P1d 50 万件の ZIP の編集と保存時の保存が速い、P8 大きな書庫の検索が止まらない、P10-a フォルダのダブルクリック・⌘↓・⌘O でフォルダに移動（既定の変更。設定で戻せる）、P10-b ⌘J の表示オプション、P11 zstd の展開が速い（`../KaitoKit` が S42 の commit のとき）、P6 進捗が byte で進み「n / N 項目」が常に項目数、P7 小さなファイル多数の取込み・作成が速い（一括の経路で、追加元の変化の文言の path が追加元の path に揃う。1 MiB を越えるファイルは今日のまま） | 利用者が判断する |

出力の byte・格納順・経路の選び方の既定を変える段は無い（P10-a の操作の既定と P13 の展開の名前だけが利用者に見える変更）。

## 5. 受入計測のまとめ

測るのはオーケストレータ。静かな機械の時間は全段で共有なので、一度に一つの計測だけを行い、§3.5 の条件（負荷の平均 4 未満、`uptime`、
最初の 1 回を捨てる）を満たした回だけを数える。どの計測も、合格条件を満たさなければ TSV・`uptime`・`sample` を添えて報告し、閾値は下げない。
方針 1 の照合が原因の超過は、その時間を分けて示す。

| 段 | 計測 | 基準 | 合格条件 |
|---|---|---|---|
| S27 | 設定 1 と 4 の出力の byte 一致（ZIP・tar.gz・tar.bz2 level 1）、7z（text256）の作成時間（1・2・8・16） | – | 一致。時間は閾値なしで記録 |
| S28 | fixture A の展開の名前の一覧と bsdtar の一覧、FAT/exFAT の実測 | – | 一覧が一致。FAT/exFAT では出力 root の外に書かない（拒否でも置換でもよい。結果を記録） |
| S30 | 分割の probe（zip・tar.gz、256 MiB、32 MiB の巻、`add_file`・`delete_end`・`save_rename`） | B-P12 | `total` ≤ B-P12 − 0.7 ×（`split_work_validation` + `split_metadata_digest` + `split_staged_recheck` + `split_placed_recheck`）。recheck ≤ 5 ms、digest ≤ 1 ms、`split_work_validation` が無い、`split_input_copy` ≤ B-P12、他の段 ± 10 % |
| S31 | `ZIP-SCALE`（500k）の `add_file`・`new_folder`・`rename_same_length`・`replace_file`・`rename_1000` | B-P1d-G | `mutate` ≤ 40 ms（replace は 60 ms）、`rename_1000` ≤ × 1.15、`open`・`commit` ± 10 % |
| S33 | P0b（zip 500k・100k、`WARM_INDEX=1`）、tar・tar.gz 100k、payload | B-P1d | AA5–AA9（例: 500k の追加・改名の `mutate` ≤ 同じ実行の delete_start + 50 ms、save_five_changes の `total` ≤ B-P1d − 2,600 ms、他の形式 ≤ × 1.10） |
| S34 | `PROBE-SEARCH`（100k・500k、ASCII・日本語） | B-P8 | M1 `filter_compute` 100k ≤ 25 ms・500k ≤ 120 ms、M1b 同じ、M2 `filter_request` ≤ 5 ms、M3 `filter_swap` 100k ≤ 15・500k ≤ 30 ms、M4 用意した filter の display ≤ 15 / 30 ms、M5 日本語 ≤ × 1.1、M6 ≤ 同期 × 1.3、M7 ± 15 % |
| S16・S21・S25 | P0b（ORDER23 §6.1・ORDER45 §6.1） | §3.5 の B-P3・B-P4・B-P5 | ORDER23・ORDER45 のまま |
| S35 | 500k（5,000 フォルダ）の移動・戻る・⌘↑ の main の時間 | – | 各 50 ms 以下 |
| S37 | `kaito bench`（交互の中央値、7 回以上） | B-P11 | G1: text ≤ 0.80、r0text ≤ 0.74、text1 ≤ 0.84。G2: 最終 + 0.01。最終: text・r0text・text1 ≤ 0.70、headers・small ≤ 0.85、small-zstd.zip ≤ 0.55、headers-zstd.zip ≤ 0.65、random・text19・textlong ≤ 1.05、RSS ≤ + 1 MiB、12,000 の変異で crash・hang・sanitizer 0 |
| S38 | gyoshuku-bench 全形式 × 全 corpus（progress なし、recursive）、`--progress`、scale probe | B-P6G / 同じ build | `wall_s` ≤ × 1.03。`--progress` は text・random ± 2 %、small・headers ≤ × 1.25（報告）。scale probe ≤ × 1.05 |
| S39 | P0b の `total`（100k 全形式、payload 256 MiB）、add_many・create_many の `total`（5 万件）、`PROBE-PROGRESS` | B-P6 | ± 5 %、≤ × 1.05、payload の `delete_start` の `distinct_completed` ≥ 8（`tail_ms` を報告） |
| Step 0-P7 | busy、open の割合、openscale | – | §3.7-4 |
| S40 | gyoshuku-bench small `--mode batch`、`items`・`recursive`（全形式・全 corpus） | B-P7（同じ回の 7zz） | zip ≤ 1.30 s かつ ≤ 7zz × 0.85、tgz ≤ 1.30 s、他 ≤ B-P7 recursive × 1.03。`items`・`recursive` ≤ × 1.03、RSS ≤ + 32 MiB、`__open` ≤ 5 % |
| S41 | add_many・create_many の `mutate`、P0b の `total` | B-P7A | zip ≤ × 0.6、tar.gz ≤ × 0.75、他 ≤ × 1.03。`total` の短縮 ≥ `mutate` の短縮 × 0.8。P0b ± 5 % |

絶対値の閾値（S34 の ms、S40 の 1.30 s、S35 の 50 ms）は、それぞれの仕様が固定した corpus と fixture（§3.7-0 の manifest など）に対するもの。

## 6. 利用者に諮る点（まとめて一度に諮ってよい）

1. **P10（S35 の門）**: フォルダのダブルクリック・⌘↓・⌘O の既定を「その場で展開」から「フォルダに移動」へ変えること（了承が無ければ既定を
   `.expand` にして同じ仕様で実装する）、移動した先でも状態欄が書庫全体の件数のままでよいこと、新しい文言（P10-a の 7 キーと「移動」メニューの
   題 `GoMenu.xcstrings` の 1 語、P10-b の 12 キー）。
2. **P1d-A の決定 3（S33 の門）**: 保存時モードの保存の前の全件の表現可能性の検査を、予約の時と同じ差分の検査に置き換える（P1 の
   「保存時モードの全体検査は残して安くする」を改める）。了承が無ければ P1d-A §A5 の「保存の前の検査」だけを外して入れる。
3. **P8・P9 の文言**: P8 の `検索しています…`、P9 の 4 キー（`圧縮の並列数:` ほか）と testJapaneseStyle の許可一覧への 1 件。計画の項目
   そのものの UI なので仕様の文言で実装し、了承を待たずに S27・S34 を始める。一覧は #1 と一緒に示す。
4. **P13**: cpio・ar・xar・ISO の `\` もただの文字にするか（今は tar 系だけ）。S28 の FAT/exFAT の実測の後、展開先が apfs・hfs 以外のときだけ
   従来の分け方に戻すか。変換の名前の検査を保存パネルの確定時に行うか（任意）。
5. **P12**: 分割セットの `.update`（P12-B。仕様は未作成）を別の段にするか。分割の公開前の照合で ZIP の local header まで読むか（約 +0.45 s、目的と逆向き）。
6. **P1d**: `TarUpdater`・`CompressedTarUpdater` にも `LiveNameCheck` を入れるか（S15 の commit の後に判断）。
7. **P8 の範囲外**: 全件一致の検索語で一致した全フォルダを展開する費用（500k で `display()` 5.2–5.4 s）を直す段。検索の見え方が変わる。
8. **P11 の範囲外**（P11 §0.5）: 5 万件の tar の解析（`TarReader.init` が open の 43 %）と、`EntryStream` の不要な CRC-32。
9. **Step 0-P7 の門を満たさないとき**: P7 を始めずに報告する（P7 の利得が小さくなる）。
10. **P5-A の文言**（ORDER45 のまま、S25 の前）。

## 7. オーケストレータが受け入れ時に見る点

1. **隔離**（§3.2）: 各段の起動の前に、その段が build する上流の checkout を別の Codex が編集していないことを確かめる。三つ組の branch は
   ff で入れ、canonical の KaitoFinder に他の変更が無いことを先に確かめる。
2. **公開の境界**（S39）: KF の台帳の callback が throw するのは GK の callback の中だけ。`didPublishForTesting` で取り消しても成功が返ること（P6 AC-A8）。
3. **予算の比**（P6 §A3）: `max_gap_ms` が目立つ行があれば、その行の式だけを直す。`tail_ms`（公開前の最後の credit から公開まで）は報告する。
4. **名前の検査の一か所**（S31・S38・S40）: addEntry の名前の検査が internal の関数一つにあり、一括の経路が写しを持たないことを grep で確かめる。
5. **advance の正しさ**（S33・S39・S41）: `NameIndexEquivalenceTests` と AA2 が各段で変更なしで通ること。S39・S41 の diff が `ArchiveNameIndexChange` の
   順を変えていないこと。
6. **P12 の D1**（S30）: APFS で stamp を内容の証明に使う変更は、分割巻の公開の中核（4 回の反証レビューの対象）に触れるので、受け入れの時に
   反証レビューを一回通す。
7. **P13 の traversal の証明**（S28）: P13 §A-4 の証明を検証記録に写し、敵対的な ZIP・tar の試験が変更なしで通ることを確かめる。
8. **P11 の出自**（S37）: Codex に P11.md だけを渡し、`$SCR/p613/prof/ref*.c` と `map-results.json` と本書を渡さない。各 round の後に門を測ってから
   同じ thread を再開する。
9. **Step 0-P7**: open の並列の伸びが足りなければ P7 を始めない。
10. **試験の書換え**（S39）: P6-A の AC-A11 の表のとおりに書き換え、assert を消していないことを diff で確かめる。
11. **GUI**（S35・S36）: 実のキー入力と `Tools/verify_ui_integration.py` は、画面のロックが無く Mac が空いているときに行う。最終の GUI の確認は利用者に依頼する。
12. **advisor**: 本書の調停は advisor に一度諮った（P6・P7・P8–P10・P12–P1d の反証レビューは advisor の timeout で二人目の目を通っていない）。
    受け入れの時の相談は CLAUDE.md の規則どおりに行う。

## 8. 調停で変えたこと（反証レビュー後の各仕様に対して）

1. **段の番号**: 四つのレビューがそれぞれ S27 を使っていた（P6-G と P11-K）。見込みの開始順で S27–S44 に振り直し、仕様の中の名前を改めた（§0.2）。
2. **隔離の規則**: P6・P7 のレビューの F1（KF が編集途中の GK を compile する）と P11 の worktree の決定を、全ての段の規則にした（§3.2）。
   空きの段（S27–S30・S32–S36）は三つ組の worktree、S31 は GyoshukuKit-p1d の worktree（P1d の仕様は計測の固定だけを書いていた）。
   本線どうしの既存の重なり（S18 ∥ S19、S21 ∥ S23 など）は今までどおりとし、§1-1 に記録した。
3. **P8 の置き場所**: S16 の前後どちらでもよいとしていたのを、S16 の後に固定した（P3-A と同じ関数・試験のファイルを変えるため。D6 の分岐が一つになる）。
4. **基準**: KF を「比べる段の直前の commit」に一般化し、B-P3・B-P4・B-P5 を改めた（§3.5。B-P4 は P1d の仕様の指摘をこの形にした）。
5. **P6-G §G7**: 新しい TaskLocal を足す案をやめ、既存の `ArchiveUpdater.testingRandomBytes`（ZipCrypto）と S24 の `testingIV`（7z AES）を使う。
6. **名前の検査の一か所**: P1d-G に、addEntry の名前の検査を internal の関数に切り出すことを足し、P6-G は閉じた状態の検査をその前に置き、P7-G の
   一括の経路はそれを呼ぶ。P7-G の AC に、S31 の budget を越える一括の一致と、走査で見つかる重複の帰属を足した。
7. **P6 の他の段との関係**: P12・P13・P9 は P6 より前に入るので、P6 の記述を「先に入った形を保つ」に改めた。P6-A と P7-A に、S33 の advance の順を
   保つ制約と `NameIndexEquivalenceTests` を足した。
8. **P1d-G の版**: 「S17 より前に commit できれば 0.8.0」を、S17 は S31 を待たないという明確な条件にした（§1-5）。
9. **P11**: 段を S37、release を S42 にし、merge は GyoshukuKit・KaitoFinder の Codex の段の間に行う規則を足した。
10. **P9 と P4・P5**: `writerOptions(for:)` の 7z・LHA の記述を S21 の前に改める（§1-3）。
11. **P1d-A の probe の規則**: S21・S25 の LHA・7z の保存の行にも当てる（§1-4）。
12. **状態の記述**: P8-P9-P10 の「S11 は進行中」を改めた（§0.1）。
13. **P6・P7 の順序の文書**: P6・P7 の改訂版に含まれていた順序・接点・Step 0・版・受入計測を本書へ移し、P6-P7.md には指示だけを残した。
14. **P12-P13-P1d**: レビューの印「（改）」と草稿からの変更一覧を仕様から外した（レビュー版のファイルに残る）。
