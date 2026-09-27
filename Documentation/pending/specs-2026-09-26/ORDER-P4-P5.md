# P4・P5 の実装順・接点・受入計測（ORDER-P2-P3 の続き）

最終の仕様は次のとおり（scratchpad = `$SP`、以下 `SP`）:

- `specs/final-p45/P4.md`（P4-K・P4-G-a・P4-G-b・P4-A）
- `specs/final-p45/P5.md`（P5-K・P5-G・P5-A）
- 本書（P4・P5 の仕様では「ORDER45」と呼ぶ）

S0–S17 の順序と共通の設計は `specs/final-p2p3/ORDER-P2-P3.md`（以下「ORDER23」）のまま。本書は、まだ着手していない段の仕様へ先に入れる文（§1）と、S18 以降を定める。P4・P5 は ORDER23 §1–§2 の設計（二つの設定、`Mode.update(_:)` と `resolved(with:)`、R0、open だけで `requiresRewrite`、出力の契約と clone の helper、`ArchiveOutputProjection` の `.update` の意味、`CommitProgress`）をそのまま使い、新しい設定・注入・経路の分岐を作らない。

基準の commit（2026-09-25）:

- KaitoKit 24311ac（S6 = P1b-K）。作業ツリーは S12（P3-K 段階 A）。LHA と 7z の parser のファイル（`Formats/LHA/*`・`Formats/SevenZip/*`・`FormatDetector.swift`）は ba42ed8 と同一なので、仕様の行番号はそのまま使える。`ArchiveReader.swift` と `PasswordProvider.swift` は S6・S12・S14 で行がずれるので、関数名で読み替える。
- GyoshukuKit e907e1d（S4 = P1-G）。作業ツリーは S7（P1b-G。`ArchiveUpdater.swift`・`EncryptionPrimitives.swift` などが変わる）。LHA と 7z の writer のファイル（`LHAWriter`・`LHARecords`・`LH5Encoder`・`SevenZipWriter`・`SevenZipRecords`・`LZMA2ChunkPipeline`・`OrderedChunkPipeline`）は c0df9fb と同一。S7 以後に変わるファイルは関数名で読み替える。
- KaitoFinder db820b7（S5 = P1-A 段階 B）。作業ツリーは S5 の修正。`publish` などの行は S8・S13・S16 でずれるので、関数名で読み替える。

## 1. 着手前に既存の仕様へ入れる文

§1.1–§1.3 は、まだ着手していない段の仕様へ入れる（ORDER23 §5 と同じ扱い）。その段が既に着手済みなら、同じ内容をその段の Codex thread へ一つの修正として送る。commit 済みで入っていなければ、各項の「入れ損ねた場合」に従う。

### 1.1 S11（P2-G）の着手前に P2.md へ入れる: 形式に依らない出力の部品

TarUpdater の出力の部品を、最初から共有の形で作らせる。後から移すと、shipped の TarUpdater に手を入れることになる。LHAUpdater（P4-G-b）と SevenZipUpdater（P5-G）は、この部品を変えずに使う。7z が要る `generated` と `finalPatch` と一時ファイルもここで作る。P5-G が共有のファイルに手を入れずに済むようにするためである。

**P2.md の SCOPE に足す**: 新規 `Sources/GyoshukuKit/SplicedArchiveOutput.swift`（internal）。型の名前は変えてよいが、次の能力と形を持つこと。

```swift
/// 出力の segment。どの長さも計画の時点で決まる（実行中に後ろの位置は変わらない）。
enum SplicedSegment {
    /// snapshot（sequential mode では原本）の範囲。clone mode で出力位置が source の位置と同じなら書かない。V5 の対象。
    case source(Range<UInt64>)
    /// 実行時に作る短い byte（header など。P2 §G6 の「生成手順」）。
    case literal(length: UInt64, bytes: () throws -> Data)
    /// 実行時に作りながら書く長い byte（P5 の変換した pack、作り直した folder の写し）。
    /// write は sink へ順に書く。書いた長さの和が length と違えば UpdaterRouteError.outputVerificationFailed（GK の不具合）。
    /// V5 の対象ではない（形式の照合が確かめる）。
    case generated(length: UInt64, write: (SplicedSink) throws -> Void)
}

/// generated の書き込み先。copy engine（4 MiB の buffer、部分書き込み、取消し、writeObserver）を通る。
struct SplicedSink {
    func write(_ bytes: Data) throws
    /// 一時ファイル（makeScratch）などから範囲を写す。
    func copy(_ range: Range<UInt64>, from source: ZipUpdateSource) throws
}

struct SplicedCommitPlan {
    var prefix: [SplicedSegment]                          // [0, M')
    var appended: Range<UInt64>?                          // beginAppend の後に writer が書いた [P_add, appendedEnd)
    var terminal: Data                                    // 追加 block（無ければ M'）の直後に置く byte
    var finalLength: UInt64                               // M' + 追加の長さ + terminal.count。ftruncate の長さ
    var finalPatch: (offset: UInt64, bytes: Data)? = nil  // 1 回目の fsync の後に書き、もう一度 fsync する（7z の開始 header）
    var formatVerificationUnits: UInt64                   // verify が advance で進める量の和
}

enum SplicedCommitStrategy { case unchanged, inPlacePatch, appendOnly, splice, sequential, relocatedAppend }

/// output と同じ directory の `.gyoshuku-<tag>-<UUID>.<ext>`（O_EXCL、0600、(dev, ino) を記録）。
/// commit の終わり・discard・失敗で SplicedArchiveOutput が消す。再配置の spool もこれで作る。
final class SplicedScratchFile {
    var length: UInt64 { get }
    func append(_ bytes: Data) throws
    func source() throws -> ZipUpdateSource
}

final class SplicedArchiveOutput {
    /// 進捗に数える照合の読み取り（V5 と、形式が units に数えて pread する照合）を報告する。
    /// units に数えない小さな読み取りと、KaitoKit を通す照合の読み取りは報告しない。
    @TaskLocal static var verificationReadObserver: (@Sendable (UInt64, Int) -> Void)?
    /// snapshot は P1-G の ArchiveSourceSnapshot。sequential は clone を使わない（snapshot が原本を直接読む、または testingDisablesClone）。
    init(snapshot: ArchiveSourceSnapshot, output: URL, pathExtension: String, sequential: Bool)
    var isCloneMode: Bool { get }
    /// 最初の add。output を作る（P2 §G3「output の作成」1–5）。sequential mode では prefix を先に書く（P2 §G7）。
    /// output の記述子を dup し、offset を at に合わせた FileHandle（closeOnDealloc）を返す。writer はこれだけに書く。
    func beginAppend(at: UInt64, prefix: [SplicedSegment]) throws -> FileHandle
    func makeScratch(tag: String) throws -> SplicedScratchFile
    /// plan を実行したときの進捗の量。書く byte（clone mode で飛ばす source を除き、再配置の往復・terminal・finalPatch を含む）
    /// + V5 の読み取り（書く source の byte の 2 倍）+ formatVerificationUnits。
    func units(for plan: SplicedCommitPlan) -> UInt64
    /// P2 §G8 の順: output の作成（未作成なら）→ 再配置（M' != P_add、または sequential mode で prefix が最初の add の後に変わった）
    /// → segment の実行 → terminal → ftruncate(finalLength) → fsync → finalPatch → fsync → V5 → verify → close → 一時ファイルの削除。
    /// 変えない plan（prefix が原本全体の source 一つで、appended・terminal・finalPatch が無い）は、clone mode では何も書かず、
    /// sequential mode では全体を写す。書いた byte と V5 で読んだ byte を meter へ足す。verify は advance を合計 formatVerificationUnits だけ呼ぶ。
    func commit(_ plan: SplicedCommitPlan, meter: CommitProgressMeter,
                verify: (_ output: Int32, _ advance: (UInt64) throws -> Void) throws -> Void) throws -> SplicedCommitStrategy
    /// 失敗・取消し・破棄。自分の output と一時ファイルだけを、(dev, ino) が一致するときに消す（snapshot は updater が消す）。
    func discard()
}

/// ArchiveUpdater.CommitProgress の共通の契約（ORDER23 §1）を守る計量。ZIP の ZipCommitMeter は変えなくてよい。
final class CommitProgressMeter {
    init(total: UInt64, progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?)
    func start() throws                   // (0, total) を通知する
    func advance(_ count: UInt64) throws  // 単調。total を越える分は数えない。4 MiB 増えるごとに通知する
    func finish() throws                  // completed を total に揃え、(total, total) を一度通知する。total は変えない
}
```

**規則**（P2.md の §G3・§G7・§G8・§G9・§G10 に足す）:

- 形式が決めるのは、segment の列・terminal・finalPatch・形式の照合（tar の V1–V4、LHA の V1–V4、7z の V0・V1・V3・V3a）とその単位だけ。output の作成、clone の飛ばし、再配置、ftruncate、fsync、V5、一時ファイル、cleanup は部品が行う。
- 進捗: updater は `CommitProgressMeter` を作り、`start()` の後、部品の `commit` と自分の作業で `advance` し、最後に `finish()` を呼ぶ。tar と LHA の total は `units(for:)` そのもの（正確）。7z の total は、作り直しの符号化を含む上界（P5 §G3-5）で、`finish()` が残りを完了として数える。
- tar の V2 の単位は、V2 が読む byte（output と source の境界の header。2 × header 長の和）。V2 と V5 の読み取りは `verificationReadObserver` に報告する。P2 §G10 の `TarUpdater.verificationReadObserver` は、この observer にする。
- `TarUpdater` が使う segment は `source` と `literal` だけ。
- `literal` の `bytes()` の長さが `length` と違う場合も、`generated` と同じく `outputVerificationFailed`（GK の不具合）。
- copy engine: P1-G の `ZipCopyEngine` は自分の `ZipCommitMeter` を持つ（`init(descriptor:totalBytes:)`、`flush` が `meter.wrote` を呼ぶ）。部品が使うために、計量を `CommitProgressMeter` に差し替えられる init（か callback）を足す。ZIP の呼出しは `ZipCommitMeter` のままで、ZIP の出力 byte と試験は変えない。
- `units(for:)` は、sequential mode で `beginAppend` が書いた prefix が最終計画と同じなら、それを数えない（add の時に書いたため。再配置になるときは、書き直す量を数える）。

**P2.md の AC に足す**:

- TarUpdater は SplicedArchiveOutput を通して出力する。grep で、`TarUpdater.swift` に `fclonefileat`・`ftruncate`・`.gyoshuku-append`・V5 の memcmp が無いことを示す。AC-G11 の等式「total = writeObserver の合計 + verificationReadObserver の合計（V2・V5）」は成り立つ。
- 新規 `SplicedArchiveOutputTests`（tar を使わない合成の plan）で、次を確かめる。
  - clone mode で、位置の同じ source を書かない。
  - sequential mode で、beginAppend が prefix を先に書く。
  - 再配置が両 mode で成り立つ。
  - generated の長さが違うと `outputVerificationFailed` になり、何も残らない。
  - finalPatch が 1 回目の fsync の後に書かれる（書込みの観測の順）。
  - makeScratch の一時ファイルが commit・discard・失敗で消え、同じ名前の別 inode は消さない。
  - `units(for:)` が「writeObserver の合計 + verificationReadObserver の合計 + formatVerificationUnits」と一致する。
  - CommitProgressMeter が単調で、total を越えず、`finish` が total を変えずに completed を揃える（total == 0 を含む）。

**入れ損ねた場合**: P2-G が TarUpdater の中に出力の部品を持ったら、P2-G の Codex thread へ一つの修正として送る。P4-G-b（S20）で shipped の TarUpdater から切り出さない。S20 の着手の門で確かめる。

### 1.2 S13（P2-A）の着手前に P2.md §A3 へ入れる: `willOpenUpdater` の呼出し

- `rewriteBranch(format:)` は `willOpenUpdater` を呼ばない。`.rewrite(let format)` の case が、`try willOpenUpdater?()` の後に `rewriteBranch(format:)` を呼ぶ（今日の :564 の呼出しと同じ回数）。
- `.update` の枝は open の前に一度だけ呼ぶ。fallback で入る `rewriteBranch` はもう一度呼ばない。
- P2-A の fallback の AC に「`willOpenUpdater` が一度だけ呼ばれる」を足す。
- 入れ損ねた場合: P4-A（S21）で直す（P4 §A2）。

### 1.3 S16（P3-A）の着手前に P3-A.md へ入れる: 圧縮 tar の条件と probe の knob

- §A2 の枝の条件 `where format != .tar` を、`where [.tarGzip, .tarBzip2, .tarXZ].contains(format)` にする。
- §A3 の `reopen()` を渡す条件と、§A7 の `editNotice` の「圧縮 tar の `.update`」も、同じ三形式として書く（「`.update(f)` で `f != .tar`」の形にしない）。そうしないと、P4・P5 の `.update(.lha)`・`.update(.sevenZip)` が、圧縮 tar の枝と注意書きの規則に入る。
- PerformanceProbeTests に `KAITOFINDER_PROBE_ADDITION_PLACEMENT`（`end` が既定 / `beginning`）を足す。
  - `beginning` では、probe の session の設定の `additionPosition` を `.beginning` にし、`.updaterOpen` の要求と `.rewriterOpen` の禁止を反転する。
  - これで、ORDER23 §6.1 の「従来の設定での圧縮 tar」の行、P4 の「従来の設定の LHA」の行、P5 の 7z の従来の設定とパスワードの操作の基準を測れる。
- 入れ損ねた場合: P4-A（S21）で入れる（P4 の P4-A SCOPE）。

## 2. 仕様間でそろえた接点（両側で同一）

| 接点 | 提供 | 利用 | 決定 |
|---|---|---|---|
| `UpdaterRouteError { requiresRewrite(reason:), outputVerificationFailed(reason:) }`、`public typealias TarUpdaterError = UpdaterRouteError`（`UpdaterRouteError.swift`） | P4-G-b（S20） | P2-A・P3-A の既存の catch（変えない）、P4-A、P5-G、P5-A | case を足さない。requiresRewrite は open からだけ投げ、その時点で何も残っていない |
| `SplicedArchiveOutput`・`SplicedSegment`・`SplicedSink`・`SplicedCommitPlan`・`SplicedScratchFile`・`CommitProgressMeter`・`verificationReadObserver`（§1.1） | P2-G（S11） | TarUpdater、LHAUpdater（source・literal）、SevenZipUpdater（加えて generated・finalPatch・makeScratch） | P4-G-b・P5-G は変えない。変える必要が出たら止めて報告する |
| `ZipUpdateSource(duplicating: Int32)`（internal。dup した記述子を読むだけの `ByteSource`。fstat で通常ファイルを確かめる） | P4-G-b | LHA の V3(b)、7z の V1・V3・V3a | 出力をパスで開き直さない。`ZipUpdateSource.readObserver` の descriptor で copy の読み取りと区別する |
| `beginAppend` の FileHandle に書く writer: `LHAWriter(output:url:identity:threads:encoder:)`・`endMembers()`・`ArchiveWriter.endLHAMembers()` / `SevenZipWriter(…, startPosition:)`・`endEntries()`・`ArchiveWriter` の 7z の追記用 factory・`endSevenZipEntries()` | P4-G-a・P4-G-b / P5-G | 各 updater | writer は updater の記述子を持たない（dup）。`prepareAppend(at:existingPaths:)`・`replaceExistingPaths` は既存のまま |
| `ArchiveSourceSnapshot`（P1-G）、`ArchiveRewriter.validateRepresentability`（internal）・`ArchiveWriter.addDirectory(_:modificationDate:ownerIDs:)`（internal）・`EditPathReservations` の規則（P2-G） | P1-G・P2-G | LHAUpdater、SevenZipUpdater | 二重に実装しない |
| `@_spi(LHARawLayout)`: `ArchiveReader.lhaRawLayout() throws -> LHAArchiveLayout?`、`LHAMemberLayout`・`LHAArchiveTerminator`・`LHATrailingBytes` | P4-K（S19） | P4-G-b の `LHALayout.swift`（と必要なら `LHAAppendedMemberCheck.swift`）だけ | option は無い（常に記録し、公開する entry あたり +16 B 以内）。recovery・分割巻では nil。KF は import しない |
| `@_spi(SevenZipEditLayout)`: `ReaderOptions.recordsSevenZipEditLayout`（既定 false）、`sevenZipEditingSnapshot()`、`sevenZipDecryptedPackedStream(folder:packedInput:)`、`SevenZipEdit*` の型 | P5-K（S23） | P5-G の SPI を使うファイルだけ、P5-A の `ArchiveReaderOptions.swift`（option を立てるだけ） | option が false なら今と同じ。KF は全ての open で立てる（P3-A の `recordsTarEditLayout` と同じ場所） |
| `LHAUpdater.open(url:output:options:)`・`rewriteReason(reader:) -> String?` | P4-G-b | P4-A | TarUpdater と同じ寿命・出力の契約・clone の規則 |
| `SevenZipUpdater.open(url:password:output:options:)`・`assess(reader:) -> SevenZipAssessment?`、`protocol ArchiveReencrypting`（`ArchiveUpdater` も適合） | P5-G（S24） | P5-A | |
| 評価（`CompressedTarUpdater.assess`・`LHAUpdater.rewriteReason`・`SevenZipUpdater.assess`）と capability の stored property（`compressedTarAssessment`・`lhaRewriteReason`・`sevenZipAssessment`。init の引数、既定 nil） | P3-G・P4-G-b・P5-G | P3-A・P4-A・P5-A | 注意書きと、7z のパスワードの操作の経路（`canReencrypt`）だけに使う。編集の経路は open の判定で決める |
| `ArchiveCapabilities.Mode.update(.lha)`・`.update(.sevenZip)`、`resolved(with:)` | P2-A（仕組み）、P4-A・P5-A（inspect） | – | 単一ファイルだけ。分割セットは `.rewrite` のまま（P12） |
| publish の `.update(.lha)`・`.update(.sevenZip)` の枝（§3.2 の形）と `rewriteBranch(format:)`（`willOpenUpdater` を呼ばない、§1.2） | P4-A・P5-A | – | open だけを `requiresRewrite` で囲む。mutate を二度呼ばない |
| `ArchiveOutputProjection` の `.update(.lha)`・`.update(.sevenZip)`、`sevenZipEncryption: Bool?` | P4-A・P5-A | – | P2-A §A4 の `.update` の意味（生存 entry を元の順、名前だけ改名後、種類と size は元のまま、追加は末尾に呼出し順、並び順の照合）をそのまま広げる。hard link の規則は当たらない |
| `ArchiveSaveReplayPlan.replay` の予約の順「削除 → 改名 → 暗号化の予約 → 追加 → フォルダ」と `(editor as? any ArchiveReencrypting)` | P5-A | 全形式 | ZIP の出力は変わらない（`ArchiveUpdater` は順序に依らない）。tar・LHA は暗号化の予約を持たない |
| `editNotice(options:onSave:)` の規則（§3.3） | P3-A、P4-A・P5-A が一つずつ足す | – | 新しい文言は P5-A の 1 キーだけ（了承が要る） |
| probe の knob `KAITOFINDER_PROBE_ADDITION_PLACEMENT`、`KAITOFINDER_PROBE_ENCRYPTION=7z`、`PROBE-7Z` 行、direct の LHA・7z の updater | §1.3（P3-A か P4-A）、P4-A、P5-A | §6 の受入計測 | TSV の既存の列の意味は変えない |

## 3. ORDER23 §2 の P4・P5 への当てはめ

### 3.1 設定・mode・R0

- `writerOptions(for:)` は、7z と LHA に `additionPlacement` だけを写す（ORDER23 §2-2）。`carriedTarOwnerIDs` は tar 系だけ。
- inspect は、単一ファイルの LHA に `.update(.lha)`（P4-A）、7z に `.update(.sevenZip)`（P5-A）を返す。門番（`ArchiveRewriter.probe` など）は今日どおりで、編集できる書庫の範囲は変わらない。
- publish のたびに `mode.resolved(with: options)` を求める。`.beginning` は `.rewrite(.lha)` / `.rewrite(.sevenZip)` になる（7z のパスワードの操作も同じ）。
- LHAUpdater と SevenZipUpdater は、`additionPlacement == .beginning` を受けたら open で `requiresRewrite("additionPlacement")` を投げる（R0 / S0）。分割巻の名前は R7 / S1。
- nil 以外の `ownerIDs` は `WriterError.unsupportedOption("ownerIDs")`。日付付きの `addDirectory` は実装する。replay は tar 系以外に ownerIDs を渡さない。

### 3.2 publish の枝（P4-A と P5-A で同じ形）

```swift
case .update(.lha):                       // P5-A は .update(.sevenZip)、SevenZipUpdater.open(url:password:output:options:)
    outputFormat = .lha
    work = directory.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: .lha))  // "archive.lzh" / "archive.7z"
    try willOpenUpdater?()                // この枝で一度だけ
    var updater: LHAUpdater?
    do {
        updater = try ArchiveStageDiagnostics.measure(.updaterOpen) {
            try LHAUpdater.open(url: archive, output: work, options: options)
        }
    } catch UpdaterRouteError.requiresRewrite(let reason) {
        didFallBackToRewriteForTesting?(reason)          // P2-A の DEBUG hook
    }
    if let updater {
        publishedMode = mode
        try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
        try ArchiveImportPlan.checkCancellation(progress)
        progress.totalUnitCount += 1000                  // 1000 単位を足すのはここだけ
        do {
            try ArchiveStageDiagnostics.measure(.commit) { try updater.commit(progress: /* P1b の CommitProgress → Progress の写し */) }
        } catch UpdaterRouteError.outputVerificationFailed(_) { throw ArchivePublicationError.verificationFailed }
        try preserveAttributes(from: archive, to: work, includingCreationDate: true)
    } else {
        publishedMode = .rewrite(.lha)
        try rewriteBranch(format: .lha)                  // willOpenUpdater を呼ばない（§1.2）。lstat(work) が ENOENT であることを確かめてから
    }
```

- 呼出側（`append`・`createFolder`・`edit`・`savePending`・7z の `updatePassword`）は、`.update(.lha)` / `.update(.sevenZip)` で 1000 単位を足さず、`commitProgress` を渡さない。ZIP の `.inPlace` は P1b のまま。
- LHA と 7z の publish は `sessionReader` を渡さない（nil）。session の reader の `reopen()` を呼ばない。updater は URL から自分の snapshot を開いて解析する（reader の再利用は後続の課題）。
- `outputVerificationFailed` の写しは P2-A と同じ。S5 の診断（`ArchiveVerificationFailure`）に updater の自己照合を表す case があれば、P2-A と同じものを使う。

### 3.3 注意書き（`editNotice(options:onSave:)` の全体の規則）

`resolved = mode?.resolved(with: options)` について、上から最初に当たるもの:

| resolved | 条件 | 注意書き |
|---|---|---|
| `.rewrite(f)` | 元の mode が `.update(.tar)` でない | 既存の「編集する / 保存するとアーカイブ全体を再圧縮します」（P3-A） |
| `.update(f)`、f は `.tarGzip`・`.tarBzip2`・`.tarXZ` | P3-A の規則（`compressedTarAssessment`） | 既存のキー / 「最初の編集で / 最初の保存で…」 |
| `.update(.lha)` | `lhaRewriteReason != nil` | 既存のキー（P4-A） |
| `.update(.sevenZip)` | `sevenZipAssessment == nil` か `updatable == false` | 既存のキー（P5-A） |
| `.update(.sevenZip)` | `hasSolidFolders` | 新しいキー「ソリッドブロック内の項目を削除すると、そのブロックを再圧縮します」（P5-A。利用者の了承が無ければこの行を置かない） |
| それ以外（`.inPlace`、`.update(.tar)`、上に当たらない `.update`） | – | nil |

`reloadAfterMutation` の capability の再検査も同じ inspect を通るので、構造が変われば注意書きも変わる（LHA の R10 (b) の書庫は、最初の書き直しの後に消える）。

## 4. 実装順と依存

| 段 | リポジトリ / 仕様 | 前提（commit 済み） | 並行してよい実装 | 終わりの条件 |
|---|---|---|---|---|
| §1 | オーケストレータ | – | 実装中の段 | §1.1 を S11、§1.2 を S13、§1.3 を S16 の着手前に入れる |
| Step 0-P4 | オーケストレータ | S14（KaitoKit 0.12.0） | S15–S17 | P4 §0.3 の fixture と golden（S14 の KaitoKit で build した `lhadump`、`TZ=Asia/Tokyo`）を `SP/p4/` に凍結する |
| S18 | GyoshukuKit / P4-G-a | S17（GyoshukuKit 0.8.0 の release の commit） | S19 | P4-G-a の AC。KF の全件試験を三つ組（KK: S14、GK: S18、KF: S16）で回す。commit |
| S19 | KaitoKit / P4-K | S17（KaitoKit 0.12.0 = S14）、Step 0-P4 | S18 | P4-K の AC。commit |
| **B-P4** | オーケストレータ | S18 | – | 三つ組（KK: S14、GK: S18、KF: S16）で P0b を採る（100k 全形式、payload 256 MiB）。LHA の rewriter の行には、既に S18 の並列が入っている |
| S20 | GyoshukuKit / P4-G-b | S18・S19 | S23 の準備 | P4-G-b の AC。commit |
| S21 | KaitoFinder / P4-A | S16・S20 | S23 | P4-A の AC。P0b を B-P4 と比べる。commit。この計測（KK: S19、GK: S20、KF: S21）を **B-P5** に兼ねる |
| S22 | オーケストレータ / release | S21 | S23・S24 | KaitoKit 0.13.0（S19 の commit から release の branch を切る。S23 を含めない）→ GyoshukuKit 0.9.0（`from: "0.13.0"`。S20 の commit から切る）→ KaitoFinder の release notes |
| Step 0-P5 | オーケストレータ | – | どの段とも | P5 の Step 0 の fixture と期待値を `SP/p5/` に凍結する |
| S23 | KaitoKit / P5-K | S19、Step 0-P5 | S20・S21 | P5-K の AC。commit |
| S24 | GyoshukuKit / P5-G | S20・S23 | S25 の準備（fixture の取り込み） | P5-G の AC。commit |
| S25 | KaitoFinder / P5-A | S21・S24、P5 §A5 の文言の了承（無ければ了承が無い場合の形） | – | P5-A の AC。P0b を B-P5 と比べる。commit |
| S26 | オーケストレータ / release | S25 | – | KaitoKit 0.14.0 → GyoshukuKit 0.10.0（`from: "0.14.0"`）→ KaitoFinder の release notes |

一つのリポジトリで同時に動く Codex は一つだけ。

- KaitoKit の順: S2 → S6 → (P1c) → S12 → S14 → S19 → S23
- GyoshukuKit の順: S4 → S7 → S10 → S11 → S15 → S18 → S20 → S24
- KaitoFinder の順: S3 → S5 → S8 → (P1c) → S13 → S16 → S21 → S25

**着手の門**:

- S20: 次がすべて commit 済みであること。無ければ始めずに報告する。
  - S11 の部品: §1.1 の能力を持つ `SplicedArchiveOutput`（`generated`・`finalPatch`・`makeScratch`・`units(for:)`・`CommitProgressMeter` を含む）、internal の `ArchiveRewriter.validateRepresentability`、`EditPathReservations` の規則、internal の `ArchiveWriter.addDirectory(_:modificationDate:ownerIDs:)`。
  - S19 の SPI が P4 §0.2 の名前であること。
- S21: GK の API（P4 §0.2）が本書の名前で commit されていること。P2-A・P3-A の `publish` の枝・`rewriteBranch(format:)`・`editNotice` があること。§1.2・§1.3 が入っていなければ、P4-A がそれを行う。
- S24: S23 の SPI が P5 §0.2 の名前であること。S20 の `UpdaterRouteError` と `ZipUpdateSource(duplicating:)` があること。S20 の門の部品（§1.1）がそのままであること。
- S25: GK の API（P5 §0.2）と KaitoKit の SPI が本書の名前で commit されていること。S21 が §3.2・§3.3 の形であること。

**検証の窓**: ORDER23 §3 と同じ。オーケストレータの検証（全件の `swift test`、xcodebuild、P0b、ベンチ）は、各段の commit から作った三つ組の worktree で行う。Codex が編集中の作業ツリーは使わない。基準との比較は同じ機械・同じビルド設定・負荷の平均 4 未満で行い、`uptime` を記録する。

## 5. 版

| release | 中身 | 条件 |
|---|---|---|
| KaitoKit 0.13.0 / GyoshukuKit 0.9.0（S22） | P4-K（`@_spi(LHARawLayout)` の追加だけ）/ P4-G-a・P4-G-b（`from: "0.13.0"`） | S21 の受け入れの後。P5 の KaitoKit 部分はまとめない |
| KaitoKit 0.14.0 / GyoshukuKit 0.10.0（S26） | P5-K（`@_spi(SevenZipEditLayout)`）/ P5-G（`from: "0.14.0"`） | S25 の受け入れの後 |
| KaitoFinder | P4 は S22 の後、P5 は S26 の後。release notes に既定の変更を書く（P4 §P4-A、P5 §P5-A の「release notes に書く変更」） | 利用者が判断する |

## 6. 受入計測

### 6.1 P0b の段（KaitoFinder、`SP/v2/run_probes.sh` と同じ設定、-O・wholemodule の Debug、ms）

- 行の名前は `PROBE-TSV` の `format/fixture/mode/operation/stage`。fixture は `entries`（1 byte × N 件、N = `PROBE_ENTRIES`）と `payload`（256 MiB の 64 件 + 1,000 件）、mode は `immediate` / `deferred`。
- operation は `delete_start`・`delete_end`・`rename_same_length`・`rename_different_length`・`rename_folder`・`new_folder`・`add_file`・`replace_file`（immediate）、`save_five_changes`・`save_rename_only`（deferred）、`open`、パスワードの `password_{set,change,remove}_*`・`save_password_change_*_rename`。
- P4 の行は **B-P4** と、P5 の行は **B-P5** と比べる。比較は段ごとの join（P2 の VERIFICATION と同じ awk と join）。「従来の設定」の行は `KAITOFINDER_PROBE_ADDITION_PLACEMENT=beginning` で測る。
- P0b の数値は参考の現状（P1-A の前）。

| 行 | P0b（参考） | 合格条件 | 段 |
|---|---|---|---|
| `lha/entries/*/*/updater_open`（100k） | `rewriter_open` 802 | ≦ B-P4 の `rewriter_open` × 1.25 | P4 |
| `lha/payload/*/*/updater_open` | `rewriter_open` 9.8 | ≦ B-P4 の `rewriter_open` + 10 | P4 |
| `lha/entries/immediate/{delete_end,rename_same_length,add_file,new_folder}/commit`（100k） | 1,659–1,727 | ≦ 50 | P4 |
| `lha/entries/immediate/{delete_start,rename_different_length,rename_folder,replace_file}/commit`（100k） | 1,724 前後 | ≦ 250 | P4 |
| `lha/entries/deferred/{save_five_changes,save_rename_only}/commit`（100k） | – | ≦ 300 | P4 |
| `lha/payload/immediate/{delete_end,rename_same_length,add_file,new_folder}/commit` | 5,560–5,644 | ≦ 60 | P4 |
| `lha/payload/immediate/{delete_start,replace_file,rename_different_length}/commit` | 5,560 前後 | ≦ 800 | P4 |
| `lha/payload/immediate/rename_folder/commit`・`lha/payload/deferred/save_five_changes/commit` | 5,644 | ≦ 900 | P4 |
| `lha/entries/immediate/*/total`（100k） | 4,007–4,247 | ≦ B-P4 の同じ行 × 0.7 | P4 |
| `lha/payload/immediate/{delete_end,rename_same_length,add_file,new_folder}/total` | 5,592–5,710 | ≦ 200 | P4 |
| `lha/payload/` の他の immediate と deferred の `total` | 5,592–5,995 | ≦ 1,100 | P4 |
| `lha/entries/*/*/{verification_open,entry_comparison,capability_probe}`（100k） | 408、70、388 | ≦ B-P4 + 10 % | P4 |
| `written_bytes`: `lha/payload/immediate/delete_start` / `delete_end` | 338 / 338 MB | ≦ 出力 + 16 MB / ≦ 4 MB | P4 |
| stage の有無（lha） | – | `updater_open` があり、`rewriter_open`・`work_copy`・`reload_open` が無い。fallback では `updater_open` と `rewriter_open` が一度ずつ | P4 |
| 従来の設定の lha、他の全形式の `total` | – | B-P4 ± 10 %（B-P4 は S18 を含むので、LHA の rewriter の並列化は現れない） | P4 |
| `7z/entries/immediate/*/total`（100k） | 5,078–5,523 | ≦ 2,000 | P5 |
| `7z/entries/deferred/{save_five_changes,save_rename_only}/total`（100k） | 6,429 | ≦ 2,800 | P5 |
| `7z/entries/*/*/updater_open`（100k） | `rewriter_open` 372–384 | ≦ B-P5 の `rewriter_open` + 80 | P5 |
| `7z/entries/immediate/{rename_same_length,rename_different_length,rename_folder,new_folder,delete_end}/commit`（100k） | 3,648–4,246 | ≦ 500 | P5 |
| `7z/payload/immediate/{delete_end,rename_same_length,rename_different_length,rename_folder,new_folder,add_file}/total` | 11,011–11,392 | ≦ 400 | P5 |
| `7z/payload/immediate/{delete_start,replace_file}/total` | 11,114 / 11,011 | ≦ 1,000 | P5 |
| `7z/payload/deferred/save_five_changes/total` | 11,461 | ≦ 1,200 | P5 |
| `written_bytes`: `7z/payload/immediate/delete_start` | 136 MB | ≦ 出力 + 16 MB | P5 |
| `7z/entries/*/*/{verification_open,entry_comparison}`（100k） | 201–209、72–79 | ≦ B-P5 + 10 % | P5 |
| `7z/entries/*/*/capability_probe`（100k） | 170–175 | ≦ B-P5 + 60 | P5 |
| `7z/payload/immediate/password_{set,change,remove}_*/commit`（AES の payload） | – | ≦ 1,500 | P5 |
| `7z/payload/immediate/password_*` の `total − password_verification` | 基準: 同じ S25 の build で `KAITOFINDER_PROBE_ADDITION_PLACEMENT=beginning`（`.rewrite(.sevenZip)`、全体の再圧縮 ≈ 11 s） | ≦ 2,500 | P5 |
| stage の有無（7z） | – | `updater_open` があり、`rewriter_open` が無い（従来の設定の行を除く） | P5 |
| `7z/*/immediate/open/total`（option の費用） | – | ≦ B-P5 × 1.10 | P5 |
| 従来の設定の 7z、他の全形式（zip・tar 系・lha）の `total` | – | B-P5 ± 10 % | P5 |

7zz 製の単一 solid の書庫の 1 件削除（solid の作り直し）は閾値を置かず、時間と `rewriter_open` + `commit` との比を報告する（P5 の AC-G15 と受入計測）。

### 6.2 ライブラリ単体（各仕様の基準の worktree と比べる）

| 計測 | 仕様 | 合格条件 |
|---|---|---|
| `gyoshuku-bench lha`（threads 8） | P4 AC-Ga4 | small ≦ 3.0 s、headers ≦ 0.35 s、text256 ≦ 1.6 s、最大常駐メモリ ≦ 120 MiB。四つの corpus の出力が threads 1/2/4/8/16 で S15 と `cmp` で一致 |
| `LHA-SCALE`（100k × 1 KiB、release） | P4 AC-Gb11 | open ≦ rewriter の open × 1.25。commit は、先頭の削除 ≦ 150 ms、末尾の削除・同じ長さの改名・追加 ≦ 20 ms |
| `kaito bench`（LHA の open） | P4 AC-K5 | ≦ S14 × 1.02。k100 の最大常駐メモリ ≦ S14 + 2 MB |
| `7Z-LAYOUT`（option on / off） | P5 AC-K8 | open ≦ off × 1.10。RSS の増分 ≦ 128 B / 件 |
| `7Z-SCALE`（release） | P5 AC-G15 | 表のとおり（`g_real` の改名・末尾の削除・追加 ≦ 50 ms、`g_k100` の open ≦ 700 ms など） |

どの計測も、合格条件を満たさなければ TSV・`uptime`・`sample` を添えて報告し、閾値は下げない。方針 1 の照合（LHA の V3・V5、7z の V1–V3a）が原因の超過は、その時間を分けて示す。外すかどうかは、方針 1 の変更として利用者に諮る。

## 7. 調停で変えたこと（反証レビュー反映版の P4・P5 に対して）

1. **出力の部品の最終の形**（§1.1）: P4 の案の `commit(prefix:appended:terminal:finalLength:…)` は、7z の header（追加 block の後ろ）と開始 header を表せなかった。P5 の案は、実行中に長さが決まる segment を足すとしていたが、その場合は後ろの位置・clone の飛ばし・再配置の判断が実行中に変わる。さらに clone mode で、作り直した folder が大きくなると、add の時に書いた追加 block を上書きする（P5 の案では扱っていなかった）。
   - 決定: 部品は「どの長さも計画の時点で決まる」形に保つ。7z の作り直しは、先に一時ファイル（`makeScratch`）へ符号化して長さを確定し、`generated` で写す（P5 §G5）。
   - 費用: 作り直した folder の圧縮後の byte を一度余分に書いて読む（7zz 製の 81 MB の solid なら数十 ms。作り直しの約 11 s に比べて小さい）。
   - `generated`・`finalPatch`・`makeScratch`・`CommitProgressMeter` は P2-G が作る。P5-G は共有のファイルを変えない。
2. **進捗の計量**: P1-G の `ZipCommitMeter.finish` は、completed が total に満たないと total を completed に縮めて通知する。これは「total は最初の通知から変えない」に反する。共有の `CommitProgressMeter` は、completed を total に揃える（ZIP は total が正確なので変えなくてよい）。
3. **照合の読み取りの観測**: `SplicedArchiveOutput.verificationReadObserver` 一つにした。V2 の単位は V2 が読む byte（2 × header 長）にし、P4 AC-Gb7 の等式が観測と一致するようにした。
4. **`ZipUpdateSource(duplicating:)`**: P5 が作るとしていたものを P4-G-b（最初の利用者）で作り、P5 は使うだけにした。
5. **KF の枝**: P4 の `rewriteBranch(format:callsWillOpenUpdater:)` をやめ、P2-A の段階で `rewriteBranch` が `willOpenUpdater` を呼ばない形にした（§1.2）。P5-A の枝も同じ形にした。
6. **圧縮 tar の条件と probe の knob**: P4-A・P5-A の「P3-A の条件を改める」を、S16 の前に P3-A へ入れる形にした（§1.3）。入れ損ねた場合は P4-A が行い、P5-A は確かめるだけにする。「従来の設定」の行を測る knob が、どの仕様にも無かったので足した。
7. **段と版**: P5 の段を S23–S26 にした。B-P4 の KaitoKit を S14（P4 の案の「S17」は release の段で、KaitoKit の commit ではない）、B-P5 を S21 の計測と兼ねるものにした。P4 の「P5 の KaitoKit 部分をまとめてよい」はやめた（S22 が S23 を待つことになるため）。
8. **P5 の 7z のパスワードの probe**: `ProbeArchiveEncryption` は ZIP の型で、fixture に `precondition(encryption == nil || format == .zip)` がある。P5-A の SCOPE に、7z を受ける形への改めを明記した。B-P5 にはこの probe が無いので、基準は S25 の build の従来の設定で採る。
9. **行番号の基準**: KaitoKit は 24311ac、GyoshukuKit は e907e1d（S7 の後は関数名）にそろえた。

## 8. オーケストレータが受け入れ時に見る点

1. **§1 の文**: S11・S13・S16 の着手前に入れる。入れ損ねたときの扱いは各項のとおり。S20 と S24 の着手の門で、部品が §1.1 の能力を持つことを確かめる。
2. **7z の作り直しの一時ファイル**（§7-1）: 方針 7（作業ファイル 1 つへ直接書く）の例外で、作り直した folder の圧縮後の byte だけが対象になる。P5 の AC-G15 と受入計測で、一時ファイルの書き込み時間を分けて報告させる。
3. **SFX**: LHA（L1）も 7z（S3）も rewriter へ戻り、stub を落とした書庫を元の名前（`.exe`）で公開する。今日と同じだが、SFX を読み取り専用にする選択肢を利用者に諮る。
4. **新しい文言**: P5-A の「ソリッドブロック内の項目を削除すると…」は S25 の前に利用者の了承を得る。
5. **7z の AES に認証が無い**: GK は変換する AES の folder ごとに先頭 64 KiB まで確かめ、KF は編集前に全ての暗号化 entry を復号する。GK 単体で残る穴は、AES + Copy の 64 KiB を越える entry だけ（P5 のリスク 2）。
6. **LHA の名前の文字コード**: R10 (b) で、非 ASCII の名前を持ち書庫全体の文字コードが推定されない書庫は、最初の編集で全体を書き直す。ASCII の名前だけの書庫に珍しい漢字の名前を足すと化けて `verificationFailed` になるのは、今日の rewriter と同じ既存の問題（P4 のリスク 2）。
7. **advisor**: P4・P5 の反証レビューは、advisor が使えず二人目の目を通っていない。本書の調停は advisor に諮った。受け入れの時の advisor の相談は、CLAUDE.md の規則どおりに行う。
