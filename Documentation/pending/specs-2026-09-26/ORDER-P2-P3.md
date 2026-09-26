# P2・P3 の実装順・接点・受入計測（ORDER-final の続き）

最終の仕様は次のとおり（scratchpad = `/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad`）:

- `specs/final-p2p3/P2.md`（P2-G と P2-A）
- `specs/final-p2p3/P3-K.md`
- `specs/final-p2p3/P3-G.md`（G1 と G2）
- `specs/final-p2p3/P3-A.md`
- 本書

P1 の順序（S0–S9）は `specs/ORDER-final.md` のまま。本書は S4 の着手前の修正（§5）と、S10 以降を定める。

## 1. 仕様間でそろえた接点（両側で同一）

| 接点 | 提供 | 利用 | 決定 |
|---|---|---|---|
| `ArchiveOwnerIDs { user, group: UInt32 }`、`ArchiveEditing.add(contentsOf:as:ownerIDs:)`、`addDirectory(_:modificationDate:ownerIDs:)`、既定の実装（値の指定があれば `unsupportedOption`） | P2-G §0.2 | P2-A（replay、試験の `StubEditor`）、P3-G（`CompressedTarUpdater` が両方を実装）、P4・P5 の updater | ownerIDs が nil でなければ preserveOwnerIDs に関係なく使う。`TarOwnerEditing` と `owners:` の tuple は作らない。P3-G の API に `addDirectory(_:modificationDate:ownerIDs:)` が欠けていたので足した（無いと保存時モードの replay が既定の実装で失敗する） |
| `WriterOptions.additionPlacement: AdditionPlacement { end, beginning }`（既定 `.end`）、`carriedTarOwnerIDs: CarriedOwnerIDs { keep, reset }`（既定 `.keep`）、`preserveOwnerIDs` はディスクから追加する項目だけ | P2-G | P2-A の `writerOptions(for:)`、全 updater の R0 | §2 の共通の設計 |
| `TarUpdaterError.requiresRewrite(reason:)` / `.outputVerificationFailed(reason:)`。requiresRewrite は open からだけ | P2-G | P2-A、P3-G、P3-A | 名前は P2・P3 で変えない。P4 の着手時に形式に依らない名前へ改め、`typealias` で互換を保つ |
| `TarUpdater.open(url:output:options:)` | P2-G | P2-A | 原本の記述子から clone（§5 と同じ helper） |
| `CompressedTarUpdater.open(reader: sending ArchiveReader, output:, format:, options:)`、`assess(reader:) -> CompressedTarAssessment?`、`commit(progress:) -> CompressedTarCommitResult`（`strategy`・`output: OutputIdentity`・`segments: [CompressedTarOutputSegment]`・統計） | P3-G D9 | P3-A | `url:` を取らない（GK はパスを開かない）。`makeReader`・`openCompressedTar` は作らない |
| `ArchiveUpdater.CommitProgress { completedBytes, totalBytes }` の共通の契約 | P1-G D8 | P1b、P2-G、P3-G → KF の写し | total は計画の後に確定。単調で、最後に completed == total（0 もあり得る）。throw は取消し。書いた量に比例する照合の読み取りも含める。KF は比だけを写す |
| 出力の契約（output は新規、親は呼出側、一時ファイルは output の隣、commit 後は 0600・fsync・close、自分の inode だけを消す）と clone の helper | P1-G D7（§5 で改める） | P2-G（clone も共有）、P3-G（出力の契約だけ。O_EXCL の新規ファイル） | clone は記述子から `fclonefileat`。flags の検査と解除。ENOTSUP / EXDEV のときだけ直接読む |
| copy engine（4 MiB、部分書き込み、取消し、`writeObserver`） | P1-G | P2-G、P3-G | 形式に依らない名前へ改めてよい |
| `TarLayout`（R0–R8・R10）・`TarEditPlan`（internal。KaitoKit の `any ByteSource` と tar 像の座標だけで書く）、`ArchiveRewriter.validateRepresentability`（internal） | P2-G | P3-G | P3-G は二重に実装しない。終端は §G6.6（変更のある commit は必ず新しい終端）を P3 でも使う |
| `TarWriter(…, startPosition:)`・`endMembers()`、`ArchiveWriter.endTarMembers()`・`add(contentsOf:as:ownerIDs:expected:)` | P2-G | P3-G（付随の保存領域） | |
| `TarCompressor.beginMember(headerLength:bodyLength:)`・`beginEndOfArchive()`、`TarWriter.memberLayouts`、`XZFraming`、`ParallelXZCompressor.defaultBlockSize` | P3-G G1 | P2-G（その上に書く）、P3-G G2、P14 | G1 を P2-G より先に commit する |
| `@_spi(TarEditLayout)`、`ReaderOptions.recordsTarEditLayout`（SPI の stored property、既定 false） | P3-K | P3-G（試験で立てる）、P3-A（`kaitoFinder(password:)` で立てる） | P2 の TarUpdater は立てない。`CompressedTarLayout` の名前は使わない |
| `ArchiveReader.tarEditingSnapshot() -> TarEditingSnapshot?`（`container`・`image`・`archive`・`layout`・`layoutUnavailableReason`・`chunkMap`・`chunkMapUnavailableReason`・`archiveIdentity: ByteSourceFileIdentity?`・`archiveIsUnchanged()`・`headerGroup(ofMember:)`・`trailingBytesAreZero()`） | P3-K K3 | P3-G（open で）、P3-A（K5 の base として） | 分割巻・cpio・option が false では nil。同一性は一つ（配列にしない） |
| `TarArchiveLayout` / `TarMemberLayout`（`groupRange`・`headerOffset`・`bodyRange`・`headerRange`）、`endOfArchiveOffset`、`globalHeaderRanges` | P3-K K1 | P3-G（P2 の unit 表と突き合わせ。違えば R8） | P2 の `dataStart` ↔ `headerRange.upperBound`（`Record.dataOffset` ではない） |
| `CompressedTarChunkMap`、`CompressedTarChunk.compressedCRC32`、`GzipChunkMap`（`headerLength`・`points`・`trailerOffset`・`trailerCRC32`・`imageLength`）、`Bzip2StreamMap.Stream.level`、`XZBlockMap`（`streamFlags`・`checkSize`・`blocks[].unpaddedSize`） | P3-K K2 | P3-G D3–D5、V4 | `deflateEnd` の名前は使わない。GK は運ぶ区間の読み取り側の CRC-32 を `compressedCRC32` と比べる |
| `ArchiveReader.openSplicedCompressedTar(output:sourceURL:base: TarEditingSnapshot, splice: CompressedTarSplice, options:) throws -> sending ArchiveReader`、`TarSpliceVerificationError.Reason` | P3-K K5 | P3-A（公開前の検証）、P3-G の試験（神託） | xz の stream flags が base と等しいことは、reused があるときだけ求める。`.baseChanged` は無い |
| `CompressedTarOutputSegment { reused(output:base:), encoded(output:) }` ↔ `CompressedTarSplice.Segment` | P3-G D5・D9 / P3-K K5 | P3-A が一対一に写す | 被覆: gzip は header の後から trailer の前、bzip2 は全体、xz は stream header の後から Index の前 |
| `ByteSourceFileIdentityProviding` | P3-K K3 | P3-A（`ArchiveVerifiedFileSource` が適合） | 採用した reader の snapshot が記述子に結び付く |
| `ArchiveCapabilities.Mode.update(_:)`・`outputFormat`・`resolved(with:)` | P2-A §A2 | P3-A、P4-A、P5-A | §2 |
| `ArchiveOutputProjection` の `.update` の意味（生存 entry を元の順、追加を末尾、並び順と hard link の参照先の照合）と `resolving(_:)` | P2-A §A4 | P3-A | tar 系全体（`.tar`・`.tarGzip`・`.tarBzip2`・`.tarXZ`）に定義する |
| `publish` の `.update` の枝の形（open だけを `requiresRewrite` で囲み、mutate の前に `rewriteBranch(format:)`）、`didFallBackToRewriteForTesting` | P2-A §A3 | P3-A | mutate を二度呼ばない |
| `replay(on:sourcePassword:progress:preservingOwnerIDs:)` | P2-A（P1b の `replay(on:sourcePassword:progress:)` に一つ足す） | P3-A | |
| `publish(…, commitProgress:, sessionReader:)` | P1b（commitProgress）、P3-A（sessionReader） | – | sessionReader は actor の中で一回だけ `reopen()` した reader。publish が GK へ渡す前に snapshot を採る |
| KF の error の写し | P2-A・P3-A | – | `outputVerificationFailed` → `verificationFailed`。K5 の `.baseNotSpliceable` → 同じ出力を全体の検証 open。K5 のその他の失敗 → `verificationFailed`（自動の書き直しは無い）。`requiresRewrite` → open の直後に rewriter。GK の `sourceChanged` → そのまま失敗 |

除いた重複・矛盾:

- **GK が K5 を包む形**: P3-K のレビュー後の版にあった `makeReader` を除いた。GK の公開 API に KaitoKit の SPI の型を出さないためで、K5 は publish（KF）が呼ぶ。
- **P3-G の自己照合**: 書いた後の出力の運ぶ範囲を GK が読み直す照合と、gzip の全体の復号を除いた。K5 が同じ命題を公開前に独立に証明する。
- **GK のパスの照合**: GK が原本のパスを開いて fstat を採る照合を除いた。パスは KF の `ArchiveSetIdentity` が照合する。
- **分割巻の snapshot**: P3-K の分割巻の snapshot（`archiveIdentities` の配列と `ConcatenatedByteSource` の葉の accessor）を除いた。分割セットは P3 でも `.rewrite` のままで、P12 で扱う。
- **終端**: P2 の §0.2 にあった「P3 は元の終端を残してよい」を撤回した。P3 も新しい終端で終える。
- **P3-A の publish の枝**: P3-A のレビュー反映版では、`catch requiresRewrite` が mutate と commit まで囲んでいた。open だけを囲む形に改めた。
- **P3-A の option**: P3-A のレビュー反映版の「`ArchiveReaderOptions.swift` は変えない」を改め、KF が option を立てる。
- **R の一覧**: P3-G の「R1–R9」を「R0–R8・R10」に改めた。

新たに明記した相互作用:

- **K1 との突き合わせ**: P3-G は P2 の walk を `snapshot.image` に当て、K1 と突き合わせる。独立した二つの解析の境界が一致することを、継ぐ前提にする。
- **原本の書き換えの検出**: GK の読み取り側の CRC-32 は、open の後に原本が同じ inode のまま、同じ長さで書き換えられ、mtime が戻された場合を捕まえる（fstat では分からない）。
- **CRC64 の xz**: 他ツールの CRC64 の xz を GK が CRC32 で作り直した出力は、K5 が reused の無い継ぎとして受理する。全体の open には回らない。

## 2. 二つの設定と経路の解決（P2–P5 で共通の設計）

一つの設計として P2-A が作り、P3-A・P4・P5 は同じものに従う（新しい設定・注入・経路の分岐を作らない）。

1. **保存**: `ArchivePreferences.additionPosition: AdditionPosition { end, beginning }`（キー `ArchiveAdditionPlacement`、既定 `.end`）と `tarCarriedOwnerIDs: CarriedOwnerIDPolicy { keep, reset }`（キー `ArchiveTarCarriedOwnerIDs`、既定 `.keep`）。既存の `tarPreservesOwnerIDs` は「ディスクから追加する項目」の意味にする。UI と 26 言語は P2-A §A1。
2. **写し**: `writerOptions(for:)`。
   - ZIP は常に `.end`。
   - tar 系は二つとも写す。
   - 7z・LHA は `additionPlacement` だけを写す。
   - 設定は編集ごとに `sessionWriterOptions` から読むので、開いている書庫でも次の編集から効く。
3. **mode**: capability は open 時に構造だけで `.update(f)` を決める。
   - P2 では `.tar`。P3 で `.tarGzip`・`.tarBzip2`・`.tarXZ`、P4 で `.lha`、P5 で `.sevenZip` を足す。
   - 分割セットは P12 まで `.rewrite(f)` のまま。
4. **解決**: publish のたびに `mode.resolved(with: options)` を求める。`.beginning` はどの形式でも `.rewrite(f)`、`.reset` は tar 系だけ `.rewrite(f)` にする。
5. **updater の R0**: どの updater（TarUpdater、CompressedTarUpdater、P4・P5 の updater）も、従来の値を受けたら open で `requiresRewrite` を投げる（安全網）。操作ごとの拒否は作らない。rewriter へ戻す判断は open でだけ行う。
6. **rewriter**: P2-G から全形式で `.end` を実装し、`.beginning` は今日の出力と一致させる。所有者は `carriedTarOwnerIDs`（運ぶ tar 項目）と `preserveOwnerIDs`（ディスクから追加する項目）に分ける。
7. **KF の枝**: `.update` の枝は、open だけを `requiresRewrite` で囲み、捕まえたら mutate の前に `rewriteBranch(format:)` へ切り替える（P2-A §A3、P3-A §A2）。
8. **注意書き**: P3-A の `editNotice(options:onSave:)` で、解決後の mode から決める。
   - 解決後が `.rewrite(f)` で、f が `.tar` 以外なら、既存の「編集する / 保存するとアーカイブ全体を再圧縮します」。
   - 圧縮 tar の `.update` で次の編集がほぼ全体を作り直すなら、「最初の編集で / 最初の保存で…」。
   - 非圧縮 tar は出さない。
   - P2-A では、`rewriteNotice`（構造だけ）でこの規則と同じ結果になる。
9. **P4・P5 の義務**:
   - inspect で `.update(.lha)` / `.update(.sevenZip)` を返す。
   - `ArchiveOutputProjection` の `.update` の意味をその形式に定義する。
   - updater は `ArchiveEditing` の全要件を実装する。7z・LHA では、nil 以外の ownerIDs は `unsupportedOption("ownerIDs")` にする。replay は tar 系以外に ownerIDs を渡さない。日付付きの `addDirectory` は必ず実装する。
   - R0 を持つ。
   - `TarUpdaterError` を形式に依らない名前へ改める（typealias で互換を保つ）。

## 3. 実装順と依存

| 段 | リポジトリ / 仕様 | 前提（commit 済み） | 並行してよい実装 | 終わりの条件 |
|---|---|---|---|---|
| S4-pre | オーケストレータ | –（GyoshukuKit は c0df9fb のまま、未着手） | S2・S3 の実装 | §5 の文で `specs/final/P1-G.md` の D7 と AC を改める。S4 は改めた仕様で起動する |
| S4–S9 | ORDER-final のまま | – | – | P1・P1b の受け入れと release（KaitoKit 0.11.0 / GyoshukuKit 0.6.0） |
| P1c | KaitoKit と KaitoFinder（仕様は未作成。本書は順序を定めない） | – | – | 作業ツリーの直列化のため、入れるなら KaitoKit では S6 と S12 の間、KaitoFinder では S8 と S13 の間に置く |
| S10 | GyoshukuKit / P3-G G1 | S7 | S8（KF）、S12（KK） | P3-G の AC1–5。KF の全件試験を三つ組（KK: S6、GK: S10、KF: S8）で回す（`ArchiveRewriter` の圧縮 tar の配置が変わるため）。commit |
| **B-P2** | オーケストレータ | S8・S10 | – | P2 の基準の三つ組（KK: S6 か P1c-K、GK: S10、KF: S8 か P1c-KF）で P0b を採る（100k 全形式、500k の zip・tar・tar.gz、本文 256 MiB） |
| S11 | GyoshukuKit / P2-G | S10（と S4 の clone の helper） | S12（KK）、S8 の残り | P2 の AC-G1–G18。commit |
| S12 | KaitoKit / P3-K 段階 A | S6（P1c-K を入れるならその後）。Step 0-c の fixture（オーケストレータが先に作る） | S10・S11・S13 | P3-K の AC1–12。AC11（GK の全件）は GK の最新の commit と組む。commit |
| S13 | KaitoFinder / P2-A | S8（P1c-KF を入れるならその後）、S11 | S12・S14 | P2 の AC-A1–A12。P0b を B-P2 と比べる。commit。P2 の release（GyoshukuKit 0.7.0）はこの後に出してよい |
| S14 | KaitoKit / P3-K 段階 B | S12 | S13 | P3-K の AC13–17。commit |
| **B-P3** | オーケストレータ | S13 | – | P3 の基準の三つ組（KK: S6（P1c-K を入れたならその commit）、GK: S11、KF: S13）で P0b を採る。KK を S12・S14 にしない: K4 の並列 bzip2 は option に依らず S12 で入るので、S12 以後の KK を基準にすると、tar.bz2 の `open` と `verification_open` の改善が基準に入ってしまう。GK S11 と KF S13 は TarEditLayout の SPI を使わないので、この三つ組は build できる。S13 の受け入れ計測と兼ねてよい |
| S15 | GyoshukuKit / P3-G G2 | S11・S12・S14 | S16 の準備（fixture の取り込み） | P3-G の AC6–11。commit |
| S16 | KaitoFinder / P3-A | S13・S15 | – | P3-A の AC1–12。P0b を B-P3 と比べる。commit |
| S17 | オーケストレータ / release | S16 | – | KaitoKit 0.12.0 の tag → GyoshukuKit 0.8.0（`from: "0.12.0"`）→ KaitoFinder の release notes（`Documentation/releases/`） |

一つのリポジトリで同時に動く Codex は一つだけ。

- KaitoKit の順: S2 → S6 → (P1c) → S12 → S14
- GyoshukuKit の順: S4 → S7 → S10 → S11 → S15
- KaitoFinder の順: S3 → S5 → S8 → (P1c) → S13 → S16

**検証の窓**:

- 三つのリポジトリは互いを sibling の作業ツリーで読む。オーケストレータの検証（`swift test` の全件、xcodebuild、P0b、ベンチ）は、各段の commit から作った三つ組の worktree で行う。三つを同じ親ディレクトリに置けば、相対の `../` がその中で解決する。memory の `$SCR/verify` と同じ方式。
- Codex が編集中の作業ツリーを検証に使わない。この条件の下でだけ、表の「並行してよい実装」を許す。
- 基準との比較は、同じ機械・同じビルド設定・load average 4 未満（`uptime` を記録）で行う。画面のロックと古い bundle の注意は memory の xcodebuild-verification-pitfalls に従う。

**着手の門**:

- S11: S10 の commit があること。§5 の clone の helper が P1-G にあること（無ければ P1-G の Codex thread へ一つの修正を送り、その commit の後に始める）。
- S15: `CompressedTarUpdater` が要る P2-G の部品（TarLayout・TarEditPlan・追記用 factory・`validateRepresentability`）が internal で存在すること。無ければ G2 で作り直さず、報告して止める。
- S16: GK の API（§1 の `CompressedTarUpdater` の行）と KaitoKit の SPI（K3・K5）が本書の名前で commit されていること。

## 4. 版

| release | 中身 | 条件 |
|---|---|---|
| KaitoKit 0.11.0 / GyoshukuKit 0.6.0（S9） | P1・P1b | ORDER-final のまま |
| GyoshukuKit 0.7.0 | P3-G G1 と P2-G（KaitoKit は変えない。`from: "0.11.0"` のまま） | S13 の受け入れの後。S9 の後に出す |
| KaitoKit 0.12.0 | P3-K（SPI の追加と K4 の並列 bzip2）。P1c の KaitoKit 部分を別に出していなければ、それも含む | S14 の受け入れの後、S17 で tag |
| GyoshukuKit 0.8.0 | P3-G G2（`from: "0.12.0"`） | S17 |
| KaitoFinder | P2 は 0.7.0 の後、P3 は S17 の後。release notes に既定の変更を書く（追加は末尾、運ぶ tar の所有者 ID を保つ、名前の byte を保つ、圧縮 tar の区切りの配置） | 利用者が判断する |

## 5. S4 の着手前に P1-G の D7 を改める文（`specs/final/P1-G.md`）

GyoshukuKit は c0df9fb のままで、P1-G はまだ着手していない。D7 の次の 2 項目を置き換え、AC を 1 つ足す。P2 の反証の実験（`scratchpad/p2review/`）で、次のことが分かったため:

- `copyfile(COPYFILE_CLONE_FORCE)` と `fclonefileat` は UF_IMMUTABLE と xattr を運ぶ。
- 運んだ flag のせいで、snapshot は消せず、output は O_RDWR で開けない。
- パスでの clone は、open との間の差し替え（ABA）を許す。

**「source snapshot:」の項の置き換え**:

- source snapshot:
  1. 原本を `ZipUpdateSource(url:)`（O_RDONLY | O_NOFOLLOW、通常ファイル）で開き、`ZipFileIdentity` を記録する。
  2. fstat の `st_flags` に `UF_IMMUTABLE`・`UF_APPEND`・`SF_IMMUTABLE`・`SF_APPEND` のどれかがあれば、`WriterError.io(operation: "source flags", code: EPERM)` を投げる。何も作らない（公開の rename もどうせ失敗する）。
  3. `fclonefileat(その記述子, AT_FDCWD, <output の親>/.gyoshuku-source-<UUID>.zip, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)` で clone する。パスでは clone しない。
  4. 成功したら:
     - snapshot を O_RDONLY | O_NOFOLLOW で開いて (dev, ino) を記録する。
     - `st_flags != 0` なら `fchflags(fd, 0)` にする。
     - 原本の checkUnchanged を行う。
     - 以後の読み取り（門番、KaitoKit の解析、validate、rebuild、CD）は、すべて snapshot の記述子から行う。
  5. `errno` が ENOTSUP か EXDEV（clone できない volume）なら、原本を直接読む。この場合、原本は今日の APFS 以外の copyItem と同じく、checkUnchanged だけが守る。
  6. それ以外の errno は `WriterError.io(operation: "clone source", code:)`。途中の snapshot があれば消す。
  7. 手順 1–6 は、形式に依らない internal の helper にする。P2-G の TarUpdater が `.tar` の名前で共有する。
  8. checkUnchanged は、原本の `ZipFileIdentity` で行う。snapshot を使う場合は、snapshot 自身の同一性でも行う。

**「出力の作成」の項の置き換え**:

- 出力の作成（最初の add か commit。変更の無い commit でも作る）:
  1. checkUnchanged。
  2. snapshot があれば `fclonefileat(snapshot の記述子, AT_FDCWD, output, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)`。無ければ `FileManager.copyItem(at: url, to: output)`（今日の :249 と同じ。原本の IMMUTABLE・APPEND は open で拒否済み）。
  3. checkUnchanged。
  4. chmod 0600。flags があれば 0 にする。
  5. O_RDWR で開き、fstat と lstat の (dev, ino) の一致を記録する。
  6. xattr・quarantine・作成日は clone の結果のままにする。mode・xattr・作成日の復元と公開は、今どおり呼出側が行う（P1-A の `preserveAttributes`）。

**AC7（ZipUpdaterOutputModeTests）に足す**:

- 原本に `uchg` があると、open で `WriterError.io`（EPERM）になり、何も作らない（試験の後で flag を外す）。
- snapshot と output は、flags が 0 の inode である。
- clone を ENOTSUP / EXDEV 以外の errno で失敗させる internal の注入では、`WriterError.io` になり、直接読む経路に落ちない。
- 注入した ENOTSUP では、直接読む経路が今日と同じ出力を作る。

S4 が既に着手済みなら、同じ内容を P1-G の Codex thread へ一つの修正として送る（P2 のリスク 7）。

## 6. 受入計測

### 6.1 P0b の段（KaitoFinder、`scratchpad/v2/run_probes.sh` と同じ設定。-O・wholemodule の Debug）

- P2 の行は **B-P2** と、P3 の行は **B-P3** と比べる（§3）。
- 表の「P0b」の数値は、参考の現状（P1-A の前）。
- 比較は段ごとの `PROBE-TSV` の join で行う（P2 の VERIFICATION の awk と join）。

| 段（operation） | 形式 / fixture | P0b（参考）100k / 500k / 本文 | 合格条件 | 段 |
|---|---|---|---|---|
| `updater_open`（即時の全操作と保存） | tar / entries | `rewriter_open` 532–568 / 2,614–2,729 | 100k ≦ 700、500k ≦ 3,500 | P2 |
| `updater_open` | tar / 本文 | `rewriter_open` 5.5–34 | B-P2 の `rewriter_open` + 10 以下 | P2 |
| `commit` delete_end・rename_same_length・add_file・new_folder | tar / entries | 1,215–1,377 / 6,132–6,562 | 100k ≦ 50、500k ≦ 150（rename_same_length は 100） | P2 |
| `commit` delete_start・rename_different_length・rename_folder・replace_file | tar / entries | 1,222–1,322 / 6,108–6,574 | 100k ≦ 250、500k ≦ 1,000 | P2 |
| `commit` save_five_changes・save_rename_only | tar / entries | 1,232・1,298 / 6,122・6,662 | 100k ≦ 300、500k ≦ 1,200 | P2 |
| `commit` delete_start / delete_end | tar / 本文 | 88 / 87 | ≦ B-P2 × 1.5 / ≦ 20 | P2 |
| `mutate`（削除・改名） | tar / entries | 70–145 / 344–732 | B-P2 + 10 % 以下 | P2 |
| `verification_open`・`entry_comparison` | tar / entries | 366 / 1,823、81 / 466 | B-P2 + 10 % 以下 | P2 |
| `total` immediate delete_start | tar / 500k | 14,858 | ≦ 9,000（B-P2 が 13,000 を越えていれば B-P2 − 5,000 以下） | P2 |
| stage の有無 | tar | – | `.updaterOpen` があり、`.rewriterOpen`・`.workCopy`・`reload_open` が無い。fallback では `.updaterOpen` と `.rewriterOpen` が一度ずつ | P2 |
| `total` の各行 | zip・tar.gz・tar.bz2・tar.xz・7z・lha | – | B-P2 ± 10 % 以内（rewriter の `.end` は `mutate` を下げ `commit` を上げるので、比べるのは `total`） | P2 |
| `total` の即時の全操作（先頭と末尾の削除、同長と異長の改名、追加、新規フォルダ、置換） | tar.gz / 本文 | 1,869–1,913 | ≦ 900 | P3 |
| `total` の即時の全操作 | tar.bz2 / 本文 | 20,468–21,005 | ≦ 2,500 | P3 |
| `total` の追加・新規フォルダ | tar.xz / 本文 | 23,052 | ≦ 1,500 | P3 |
| `total` の削除・改名・置換 | tar.xz / 本文 | 22,739–23,055 | ≦ 9,000 | P3 |
| `total` の save_five_changes | tar.gz / tar.bz2 / tar.xz / 本文 | 2,188 / 20,943 / 23,403 | ≦ 1,300 / 2,900 / 9,500 | P3 |
| `total` の rename_folder | 三形式 / 本文 | 1,904 / 20,659 / 22,967 | ≦ B-P3（payload の全 member の header が変わり、全区切りを作り直すため。値を P14 の入力として記録） | P3 |
| `verification_open`（K5） | 三形式 / 本文（rename_folder を除く） | 290 / 6,324 / 1,486 | B-P3（KK は S6。直列の bzip2）の `verification_open` に対して tar.gz ≦ 60 %、tar.bz2 ≦ 10 %、tar.xz ≦ 35 % | P3 |
| stage の有無 | 三形式 | – | `rewriter_open` と `reload_open` が無く（従来の設定の行を除く）、`reader_adoption` がある | P3 |
| 書込み MB（本文の先頭削除） | 三形式 | 955 / 940 / 931 | ≦ 出力の書庫 + 16 MB | P3 |
| 1 byte × 100,000 の各操作 | 三形式 / entries | 2,379 / 2,613 / 3,108（先頭削除） | ≦ 同じ実行の非圧縮 tar の同じ操作 + 700 | P3 |
| 1 byte × 500,000 の各操作 | tar.gz / entries | 11,823（先頭削除） | ≦ 同じ実行の tar + 1,500。書込み MB ≦ 出力 + 16 MB | P3 |
| 連続 10 編集 | tar.gz / 本文 | – | 書込みの合計と、K5 の合成の写しの回数を報告する（閾値なし） | P3 |
| 操作 `open` の `total`（`document_ready` まで。option の費用と K4 の効果） | 本文と 100k | – | tar.gz ≦ B-P3 × 1.13、tar.xz・tar ≦ × 1.05。tar.bz2 は本文 fixture で ≦ × 0.5、100k（解析と木の構築が支配）で ≦ × 0.7。zip・7z・lha は ± 10 % | P3 |
| 従来の設定での圧縮 tar、ZIP・7z・LHA・非圧縮 tar の各行 | – | – | B-P3 ± 10 % 以内 | P3 |

### 6.2 ライブラリ単体（各仕様の基準の worktree と比べる）

| 計測 | 仕様 | 合格条件 |
|---|---|---|
| `TAR-SCALE`（TarUpdater、release、100k × 1 KiB） | P2 AC-G15 | open ≦ rewriter の open + 25 %。commit は、先頭削除 ≦ 150 ms、末尾削除・同長改名・追加 ≦ 20 ms |
| `TarUpdaterOracleTests`（p3val の 4 corpus） | P2 AC-G14 | rename-same・append はファイル全体が byte 一致。他は `[0, M')` が一致し、終端が §G6.6 |
| `gyoshuku-bench`（G1、threads 1 と 8） | P3-G AC3・AC5 | サイズと区切りの列が `p3gA_review/g1-layout-reference.json` と一致し、1 と 8 で出力 byte が一致。書き込み時間は S7 の commit の ±10 % |
| `kaito bench <archive> 5`（option off / on） | P3-K の見込みの表 | off は全対象で基準 × 1.02 以下。on は次のとおり: text.tgz × 1.13、small・mixed.tgz と k500.tgz × 1.08、txz・tar × 1.03（k500.tar × 1.05）、k500.tar の RSS + 24 MB、tbz（text・mixed）40 %、tbz（small）60 % |
| `KAITOKIT-PROBE`（K5、試作の 63 + 12 件と 4 GiB + 1 MiB） | P3-K AC16 | 全件受理され、全体の open と一致。K5 の時間は、同じ build（K4 が有効）の出力の全体の open に対して tgz 60 %、tbz 25 %、txz 35 % 以下（tbz の基準は並列の復号なので、直列の基準で見込んだ 10 % ではなく 25 %。P3-A の `verification_open` の 10 % は直列の B-P3 に対するもの） |
| `TAR-SCALE`（CompressedTarUpdater、mixed、8 threads） | P3-G AC9 | tar.gz の 4 操作 ≦ 0.6 s、tar.bz2 ≦ 1.2 s、tar.xz の追加と text256 の改名 ≦ 1.0 s、small の削除・改名 ≦ 符号化 + 1.5 s かつ ≦ 9.0 s。付随の書込み ≦ 追加量 + 1 MiB |

どの計測も、合格条件を満たさなければ TSV・`uptime`・`sample` を添えて報告し、閾値は下げない。方針 1 の照合（P2 の V5、P3 の K5）が原因の超過は、その時間を分けて示す。外すかどうかは、方針 1 の変更として利用者に諮る。

## 7. オーケストレータが受け入れ時に見る点

1. **K5 の失敗は公開しない**: `.baseNotSpliceable` 以外で自動の書き直しをしない。GK の不具合のときは、利用者に失敗が見える（原本は無傷）。P3-K のレビュー後の版は「書き直しでやり直す」としていたが、不具合を隠さないために採らなかった。利用者の意向で変える場合は、P3-A の A2-6-3 の一か所だけを変える。
2. **option の費用は KF の全ての open に乗る**: KF は option を常に立てる。tar.gz の session の open は約 +9〜13 % になる。代わりに、tar.bz2 の open は K4 で速くなり、編集ごとの全展開 3 回が無くなる。§6.1 の `open` の行で確かめる。K4 の効果が P3 の受け入れに現れるよう、B-P3 の KaitoKit は S6（K4 の前）にしてある。
7. **`assess` と注意書き**:
   - `CompressedTarUpdater.assess(reader:)` は、snapshot・layout・地図・`nameEncoding` だけを見る。R1–R6・R8 に当たる書庫（`comment` 以外の `g` など）では非 nil を返すので、注意書きは出ず、最初の編集は `requiresRewrite` で黙って全体の書き直しになる。
   - `nameEncoding != nil`（R10、CP932 の名前など）は `assess` が nil を返すので、既存の再圧縮の注意書きが出る（P3-G D9、P3-A A7）。
   - 残りの R は open で走査しないと分からないので、受け入れる。
3. **G1 を P2-G より先に入れる**: B-P2 は G1 を含む。P2 の受け入れの差分は、P2-G と P2-A だけのものになる。G1 自身の KF への影響は、S10 の KF の全件試験で見る。
4. **GK が見る原本の同一性は記述子の同一性だけ**: パスの差し替えは KF の `ArchiveSetIdentity` だけが捕まえる。P3-G の試験は、この分担を明示的に確かめる。
5. **advisor の不在**: P2 と P3-G・P3-A の反証レビューは、advisor の timeout で二人目の目を通していない。本書の調停は advisor に一度諮った。受け入れの時の advisor の相談は、CLAUDE.md の規則どおりに行う。
6. **P1c**: 仕様が未作成なので、本書は置き場所だけを定めた（§3）。P3-K の基準の commit は、P1c の KaitoKit 部分を入れるかどうかで変わる（P3-K の前提）。
