# P3-A（KaitoFinder）: 圧縮 tar の編集を区切り単位の updater へ回し、1 編集あたりの全展開と一時展開をなくす（最終版）

## この版での調停（2026-09-25。レビュー反映版に対する変更。本文へ反映済み）

P2・P3-K・P3-G の最終版（`scratchpad/specs/final-p2p3/`）と突き合わせ、次の点を変えた。接点の一覧は `ORDER-P2-P3.md` の §1 にある。

1. **地図の記録**:
   - P3-K の最終版は、SPI の option `ReaderOptions.recordsTarEditLayout`（既定 false）で記録する。
   - KF は `ReaderOptions.kaitoFinder(password:)` でこれを立てる（`kaitoFinderVerification` も継ぐ）。
   - `ArchiveReaderOptions.swift` を SCOPE と SPI の import の許可リストに加えた。
   - session の open の費用（gzip の Z_BLOCK で +9〜11 %）は、P0b の `open` の段で受け入れる（AC10）。
2. **K5 の base は snapshot**:
   - `publish` は `sessionReader`（session の reader を actor の中で `reopen()` した reader）を一つだけ受け取る。
   - GK へ渡す前に、その reader から `tarEditingSnapshot()` を採り、K5 の base にする。
   - `reopen()` は一回だけで、base 用の reader を別に持たない。
3. **publish の枝の形**:
   - `requiresRewrite` を捕まえるのは `CompressedTarUpdater.open` だけにした（P2-A §A3 と同じ形）。mutate と commit は捕まえる範囲に入れない。
   - `CompressedTarUpdater.open` は `url:` を取らない。
4. **K5 の失敗の一覧**:
   - `.baseChanged` は P3-K の最終版に無いので除いた。
   - `.inconsistentBaseMap` を足した。
   - 他ツールの CRC64 の xz の最初の編集（GK の `fullEncode`）は、K5 が受理する。全体の open へは回らない。
5. **原本の同一性**:
   - GK はパスを開かない。
   - open の後の原本の書き換えは、GK が `snapshot.archiveIsUnchanged()` と運ぶ区間の読み取り側の CRC-32 で `UpdaterError.sourceChanged` にする。
   - パスの差し替えは KF の `ArchiveSetIdentity` が捕まえる（今のまま）。
6. **注意書き**: 解決後の mode から決める `editNotice(options:onSave:)` は、P2-A の注意書きの方針（非圧縮 tar は再圧縮の注意書きを出さない）を広げたもの。設定の設計は ORDER §2 の共通の設計をそのまま使う。
7. **順序**: ORDER-P2-P3.md の S16。P2-A（S13）、P3-G G1（S10）と G2（S15）、P3-K 段階 A（S12）と B（S14）の後。


## 前提

- 編集対象は `/Users/nagash/Github/KaitoFinder` だけ。`../GyoshukuKit` と `../KaitoKit` は読むだけ。コミットしない。Swift 6、macOS 26。`nonisolated(unsafe)` と `@unchecked Sendable` を新しく使わない。DEBUG の hook は `#if DEBUG` の TaskLocal。文言は `KaitoFinder/Resources/Localizable.xcstrings`（source は ja、各キー 26 言語: cs da de en es fi fr hi id it ja ko ms nb nl pl pt-BR pt-PT ru sv th tr uk vi zh-Hans zh-Hant）。
- 行番号: 無印は KF HEAD b91c70b。P1-A・P1b・P2-A の後は行がずれるので、関数名で読み替える。`GK` = GyoshukuKit c0df9fb、`KK` = KaitoKit b518014。GK の新しい API は `scratchpad/specs/final-p2p3/P3-G.md`（以下「P3-G」）、KaitoKit の新しい SPI は `scratchpad/specs/final-p2p3/P3-K.md`（以下「P3-K」）、P2 の名前は `scratchpad/specs/final-p2p3/P2.md`（以下「P2」）。コミット済みの名前が本仕様と違えば、実装を止めて報告する。scratchpad = `/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad`。
- 依存（すべて受け入れ・コミット済みであること）:
  - P1-A 段階 A（検証した reader の採用、`ArchiveVerifiedFileSource`・`ArchiveVerifiedOutput`・`adoptVerifiedReader`）と段階 B。
  - P1b の KF 部分（`publish(…, commitProgress:)` と `ArchiveUpdater.CommitProgress` → `Progress` の写し）。
  - P2-A。これが次を用意している:
    - `ArchiveCapabilities.Mode.update(_:)`・`outputFormat`・`resolved(with:)`、`.update(.tar)` の publish の枝と `rewriteBranch(format:)`（requiresRewrite の fallback）。
    - `ArchiveOutputProjection` の `.update` の意味（並び順の照合を含む）、`resolving(_:)`。
    - 設定二つ（`additionPlacement`・`tarCarriedOwnerIDs`）と 26 言語、`ArchiveSaveReplayPlan.replay(on:progress:preservingOwnerIDs:)`、`ArchiveDeferredTarWriter` の削除。
  - P3-G の G1 と G2。
  - P3-K の段階 A と B（`recordsTarEditLayout`、`tarEditingSnapshot()`、`ByteSourceFileIdentityProviding`、`openSplicedCompressedTar`）。
  - ORDER-P2-P3.md の S16。P1c の KF 部分を先に入れる場合は、その後。
- 計画: `Documentation/pending/2026-09-24-large-archive-edit-plan.md` の P3 行と方針 1–4・7。利用者の決定: 追加は末尾が既定、触らない tar member は uid/gid を含め byte のまま運ぶのが既定。どちらも設定で従来へ戻せ、従来は全体の書き直し。設定の UI・保存・`WriterOptions` への写しは P2-A が作り、P3-A は圧縮 tar でもその値に従う（新しい設定・注入を作らない）。
- 基準（P0b、-O・wholemodule の Debug、M4 Max、`Documentation/verification/2026-09-25-p0b-stage-probes.md:210-242`、ms）:

  | fixture | 形式 | 先頭削除 | 末尾削除 | 同長改名 | フォルダ改名 | 1 件追加 | 置換 | 保存（5 変更） | 書込み MB |
  |---|---|---|---|---|---|---|---|---|---|
  | 本文 256 MiB（4 MiB × 64）+ 1,000 | tar.gz | 1880 | 1886 | 1895 | 1904 | 1913 | 1869 | 2188 | 955 |
  | 同 | tar.bz2 | 21005 | 20861 | 20805 | 20659 | 20593 | 20468 | 20943 | 940 |
  | 同 | tar.xz | 22739 | 22984 | 23055 | 22967 | 23052 | 22805 | 23403 | 931 |
  | 1 byte × 100,000 | tar.gz / bz2 / xz | 2379 / 2613 / 3108 | – | – | – | – | – | 3842 / 3979 / 4459 | 308 / 307 / 307 |
  | 1 byte × 500,000 | tar.gz | 11823 | 11788 | 12819 | 12976 | 12409 | 13148 | 17457 | 1541 |

  tar.gz の内訳（本文）: rewriter の open の展開 297 + commit 986 + 公開前の検証の展開 290 + 再読込 295。この表は現状を示すだけで、比較の基準にはしない。基準は P3 の直前の commit の三つ組（P1-A・P1b・P2・P3-K を受け入れた後）で撮り直す（P2 が tar の行を、P1-A が `reload_open` を変えるため）。

## OBJECTIVE

1. 単一ファイルの tar.gz / tar.bz2 / tar.xz の capability を `.update(.tarGzip / .tarBzip2 / .tarXZ)` にする。
   - 即時編集（追加・削除・改名・移動・新規フォルダ・置換）と保存時モードの保存は、P2-A の `resolved(with:)` の結果が `.update` のとき GyoshukuKit の `CompressedTarUpdater` で行う。
   - 従来の設定（先頭へ追加 / 所有者 ID を 0）では `.rewrite(f)` に解決し、今と同じ `ArchiveRewriter` の経路を通る（P2-A の `rewriteBranch`）。
2. updater には session の reader の `reopen()` を渡し、session の open で一度だけ展開した tar image と区切りの地図を使わせる。これで rewriter の open の展開と staging がなくなる。publish は、その reader を GK へ渡す前に `tarEditingSnapshot()` を採り、K5 の base にする。
3. 公開前の検証は、KaitoKit の K5 `openSplicedCompressedTar` で、検証した作業ファイルの記述子を base の image と地図に照らして証明する（全体の展開なし）。その後に P2-A の `ArchiveOutputProjection` の照合を行い、得た reader を P1-A の採用で session の reader にする。1 編集の一時ファイルへの書込みは、出力の書庫と、追加した量（付随の保存領域と K5 の復号）の分になる。
4. 他ツールの framing（単一 stream、CRC32 以外の xz、複数 member の gzip など）は、最初の編集で updater が全体を GyoshukuKit の区切りへ作り直す（`fullEncode`。`ArchiveRewriter` へは回さない）。その書庫では「最初の編集で／最初の保存でアーカイブ全体を再圧縮します」と表示する（新しい文言 2 キー、26 言語）。
5. 分割セット（`.tar.gz.001` など）は今のまま `.rewrite(f)`。P3-K は分割巻に snapshot を作らないため（P12 で扱う）。
6. 計測（P0b）で新しい段と書込み量を出し、ACCEPTANCE の門を満たす。

## SCOPE (files and functions)

- `KaitoFinder/Model/ArchiveCapabilities.swift`:
  - `inspect(url:format:password:reader:)` の tar 系（:168-172）で `.gzip` → `.update(.tarGzip)`、`.bzip2` → `.update(.tarBzip2)`、`.xz` → `.update(.tarXZ)`（P2-A が `.tar` → `.update(.tar)` にした形に足す）。
  - 門番（:185-200: 書き込み権限、通常ファイル、`ArchiveRewriter.probe(reader:format:)`、暗号化）は P2-A の `.update` の扱いのまま。reader を開いた後（:196）で、圧縮 tar の `.update` なら `CompressedTarUpdater.assess(reader:)` を capabilities に保持する（新しい stored property `compressedTarAssessment: CompressedTarAssessment?`、init に既定 nil の引数）。
  - `inspectSplit`（:112-144）は変えない（`.rewrite(...)` のまま）。
  - 新しい `func editNotice(options: WriterOptions, onSave: Bool) -> String?`（A7）。`rewriteNotice`（:44-47）は P2-A の意味のまま残す。
- `KaitoFinder/Model/ArchiveReaderOptions.swift`: `@_spi(TarEditLayout) import KaitoKit` とし、`kaitoFinder(password:)` の `ReaderOptions` に `options.recordsTarEditLayout = true` を立てる（`kaitoFinderVerification` は `kaitoFinder` から作るので継ぐ）。`kaitoFinderOpenCount` の数え方は変えない。
- `KaitoFinder/Import/ArchiveVerifiedOutput.swift`（P1-A 段階 A）: `ArchiveVerifiedFileSource` を `ByteSourceFileIdentityProviding`（P3-K K3、`@_spi(TarEditLayout) import KaitoKit`）に適合させる。`currentFileIdentity()` は保持する記述子の fstat を返す（device は `UInt64(UInt32(bitPattern: st_dev))`、inode、size、mtime 秒・ナノ秒）。
- `KaitoFinder/Import/ArchiveImportTransaction.swift`（`@_spi(TarEditLayout) import KaitoKit`）:
  - `publish(...)`（:509-620）に引数 `sessionReader: sending ArchiveReader? = nil`（session の reader を actor の中で `reopen()` したもの。圧縮 tar の `.update` のときだけ非 nil）。
  - `.update(f)`（f が圧縮 tar）の枝（A2）と、検証の K5 の枝（A2-6）。
  - `ArchiveEditTransaction.run`（:394-420）、`createFolder`（:435-450）、`run(plan:...)`（:453-506）は同じ引数を通すだけ。
  - DEBUG の `didFallBackToFullVerificationForTesting: TaskLocal<(@Sendable (String) -> Void)?>`。
- `KaitoFinder/Model/ArchiveSession.swift`: `append`（:315-346）、`createFolder`（:389-407）、`edit`（:416-438）、`savePending`（:523-568）で、P2-A の解決の後の mode が圧縮 tar の `.update` なら `reader.reopen()` を渡す（A3）。`savePendingSplit`（:570-631）は変えない。
- `KaitoFinder/UI/ArchiveWindowController.swift`: `refreshCapabilityNotice(session:)`（:776-792）で注意書きを `editNotice(options:onSave:)` から得る。options は `preferencesStore.preferences.writerOptions(for: mode.outputFormat)`。既存の `ArchivePreferencesStore.didChange` の observer（:157-158 の `preferencesDidChange(_:)`）でも再計算する。
- `KaitoFinder/Resources/Localizable.xcstrings`: 新しいキー 2 つ（A7）、26 言語。
- `KaitoFinderTests/Support/ArchivePerformanceProbe.swift` と `PerformanceProbeTests.swift`: GK の `@_spi(Testing) lastCommitStatistics` を `PROBE-SPLICE` 行に出す（A8）。
- `Documentation/verification/2026-09-2x-p3-compressed-tar.md`（新規）と、`Documentation/pending/2026-09-24-large-archive-edit-plan.md` の P3 行の状態。
- 試験:
  - 新規: `CompressedTarRoutingTests`、`CompressedTarPublishTests`、`CompressedTarDeferredSaveTests`、`CompressedTarVerificationFailureTests`、`CompressedTarSplitRegressionTests`、`CompressedTarNonAPFSTests`。
  - 既存の試験は、新しい経路から当然に変わる期待だけを直す（下の一覧）。直した assert は全て理由付きで報告する。
    - `ArchiveRewriteTests.swift:113-128`: tgz の mode が `.update(.tarGzip)`、`rewriteNotice` は nil、`editNotice` は設定どおり。
    - `ArchiveRewriteTests.swift` の :150 付近: 圧縮 tar の `.rewrite(format)` の assert。
    - `DeferredSaveUITests.swift:224-252`: tar.gz の保存時の注意書き。既定の設定では空。一つは従来の設定で既存のキーを期待するように残し、他ツールの tar.gz で新しいキーを期待する試験を足す。
    - `WordingAcceptanceTests.swift:182` の一覧: 新しい 2 キー。

範囲外:
- GyoshukuKit と KaitoKit、非圧縮 tar（P2-A）、7z / LHA / ZIP。
- 分割セットの updater 化と、その公開の検証の全展開 2 回（ArchiveSplitSave.swift:152、:156-158。P12）。
- 別名保存（`ArchiveSplitWorkProducer.produce(existing:...)` :120-149 と `ArchiveCreationTransaction`。rewriter 経由で設定が効く）。
- 従来の設定の経路の速度（`ArchiveRewriter` の reader の再利用は後続）、元に戻す（`ArchiveUndoStack`）の仕組み。
- 設定の UI（P2-A）。

## DESIGN

### A1 mode と経路

1. **capability は構造だけで決まる**（P2-A §A2 と同じ考え方）:
   - 単一ファイルの圧縮 tar は `FormatDetector` の結果から `.update(.tarGzip / .tarBzip2 / .tarXZ)` にする。
   - 拒否の優先順（:146-147）と `.compress` 以下の拒否（:173-178）は変えない。
   - 表現可能性の門番は P2-A の `.update` の扱いのまま（`ArchiveRewriter.probe(reader:format:)`）なので、編集できる書庫の範囲は今と同じ（P2 §0.1-10。`.other` などを含む書庫は今どおり読み取り専用）。
   - `compressedTarAssessment` は注意書きだけに使い、経路の決定には使わない。
2. **経路は publish のたびに決める**。P2-A の `let options = options(for: base)`、`let mode = base.resolved(with: options)` をそのまま使う。
   - 従来の設定（`additionPlacement == .beginning`、または tar の `carriedTarOwnerIDs == .reset`）なら `.rewrite(f)` になる。
   - 設定は文書が注入する既存の `writerOptions` closure（ArchiveSession.swift:120、ArchiveDocument.swift:119-121）から読む。新しい注入は作らない。
3. **経路の一覧**:

   | 状況 | 経路 |
   |---|---|
   | 解決の結果が `.rewrite(f)`（設定のどちらかが従来） | P2-A の `rewriteBranch(format:)`（`ArchiveRewriter`。`ArchiveDeferredTarWriter` は P2-A で削除済み） |
   | `.update(f)` で `CompressedTarUpdater.open` が `TarUpdaterError.requiresRewrite`（snapshot・layout・同一性が無い、K1 との突き合わせの不一致、P2 の R0–R8・R10） | 同じ publish の中で mutate の前に `rewriteBranch(format:)`（P2-A §A3 と同じ。作業ファイルは作られていない） |
   | `.update(f)`、継げる framing | updater が区切りを運ぶ → K5 で検証 |
   | `.update(f)`、継げない framing（他ツール） | updater の `fullEncode` → K5 で検証（reused の無い継ぎ。CRC64 の xz も K5 が受理する）。base に地図が無い書庫（複数 member の gzip、padding 付きの xz）だけ、K5 が `.baseNotSpliceable` を返し、同じ出力を全体の open で検証する |
   | GK の `outputVerificationFailed`、K5 の拒否（`.baseNotSpliceable` 以外） | 公開しない（`ArchivePublicationError.verificationFailed`）。自動で書き直しへは回さない |
   | GK の `UpdaterError.sourceChanged`（session の open の後に原本の inode が書き換えられた。記述子の fstat か、運ぶ区間の読み取り側の CRC-32） | そのまま失敗。原本は未変更（KF の今の `sourceChanged` の扱いと同じ） |
   | 原本のパスが別の inode に差し替えられた | 今どおり KF の `ArchiveSetIdentity`（:521-522、:603-605）が拒否する。GK はパスを開かない |
   | 採用の失敗（P1-A の fallback の理由） | URL から開き直す（全展開 1 回。今と同じ） |

4. updater が `requiresRewrite` を投げるのは open だけ（P3-G D2-1、P2 §0.1-9）。KF は mutate を二度呼ばない（P2-A AC-A4 と同じ性質を圧縮 tar でも試験する）。

### A2 publish の圧縮 tar の枝

P2-A の `.update(let format)` の枝を二つに分ける。`format == .tar` は P2-A のまま（`TarUpdater`）。圧縮 tar は次のとおり。`requiresRewrite` を捕まえるのは open だけ（P2-A §A3 と同じ形）。

```swift
case .update(let format) where format != .tar:   // .tarGzip / .tarBzip2 / .tarXZ
    outputFormat = format
    work = directory.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: format))
    guard let reader = sessionReader else { throw ArchiveEditError.staleSelection }  // 呼出側の誤り。試験で検出する
    // K5 の base。GK へ渡す前に同じ reader から採る（Sendable の値。reader の寿命に依らない）。
    spliceBase = reader.tarEditingSnapshot()
    try willOpenUpdater?()
    var updater: CompressedTarUpdater?
    do {
        updater = try ArchiveStageDiagnostics.measure(.updaterOpen) {
            try CompressedTarUpdater.open(reader: reader, output: work, format: format, options: options)
        }
    } catch TarUpdaterError.requiresRewrite(let reason) {
        // open からだけ投げられ、mutate の前。GK は何も作っていない。
        didFallBackToRewriteForTesting?(reason)          // P2-A の DEBUG hook
    }
    if let updater {
        publishedMode = mode
        try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
        try ArchiveImportPlan.checkCancellation(progress)
        progress.totalUnitCount += 1000
        do {
            spliced = try ArchiveStageDiagnostics.measure(.commit) {
                try updater.commit(progress: /* P1b の CommitProgress → Progress の写し */)
            }
        } catch TarUpdaterError.outputVerificationFailed(_) { throw ArchivePublicationError.verificationFailed }
        try preserveAttributes(from: archive, to: work, includingCreationDate: true)   // P2-A の形
    } else {
        spliceBase = nil
        publishedMode = .rewrite(format)
        try rewriteBranch(format: format)                // P2-A。lstat(work) が ENOENT であることを確かめてから
    }
```

1. 作業ファイルの名前は `archive.tar.gz` / `archive.tar.bz2` / `archive.tar.xz`（ArchiveCreationPlan.swift:39-49。P0 の規則）。K5 と全体の open が同じ container の判断をする（KK ArchiveReader.swift:686-711）。
2. `sessionReader` は、session の reader を actor の中で `reopen()` した独立の reader（`sending`）。publish はそこから K5 の base の snapshot（`TarEditingSnapshot`、Sendable）を採ってから、reader を GK へ渡す。`reopen()` は一回だけで、base 用の reader を別に持たない。snapshot が nil（option を立てずに開いた reader など）なら、GK が open で `requiresRewrite` を投げ、rewriter へ戻る。`sending` の reader を `measure` の closure の中で GK へ渡す形が Swift 6 の region の検査を通らなければ、closure の外で渡す（`measure` を open の呼出しだけに使わず、`ArchiveStageDiagnostics` の計測を open の前後で行う）か、`Optional` から取り出して渡す。通る形を選び、選んだ形を報告する。
3. `preserveAttributes`（chmod と xattr と作成日時）と quarantine の付与（:576-581）は今どおり検証の前に行う。どれも mtime を変えない。検証の後に作業ファイルの mtime を変えない（P3-K「KaitoFinder（P3-A）が守ること」6。変えると採用した reader の `archiveIsUnchanged()` が false になり、次の編集が GK の `sourceChanged` で失敗する）。
4. `rewriter` の枝の `progress.totalUnitCount += entryNames.count`（:566）は、updater の枝では行わない（進捗は CommitProgress の写し）。
5. エラーの写し:
   - `TarUpdaterError.outputVerificationFailed` → `ArchivePublicationError.verificationFailed`。
   - `UpdaterError.invalidArchive` は GK が投げないので、`publishing`（ArchiveSession.swift:692-697）が書庫を読み取り専用にする経路は通らない。
   - `CancellationError` はそのまま。
6. **検証**（P1-A 段階 A の `ArchiveVerifiedFileSource(url: work)` を開き、パスとの同一性を確かめた後）:
   1. `spliced` があれば（updater の経路）、`source.identity` の inode・size・mtime（秒・ナノ秒）が `spliced.output` と一致しなければ `ArchivePublicationError.verificationFailed`（mode は chmod で変わるので比べない）。
   2. 次のとおり検証の reader を得る。
      ```swift
      let verificationOptions = ReaderOptions.kaitoFinderVerification(password: nil)   // 一度だけ作る
      verified = try ArchiveStageDiagnostics.measure(.verificationOpen) {
          do {
              guard let spliced, let spliceBase else {   // rewriter の経路は今どおり全体の open
                  return try ArchiveReader.open(source: source, sourceURL: hint, options: verificationOptions)
              }
              return try ArchiveReader.openSplicedCompressedTar(
                  output: source, sourceURL: hint, base: spliceBase,
                  splice: CompressedTarSplice(segments: spliced.segments.map(Self.kaitoKitSegment)),
                  options: verificationOptions)
          } catch let error as TarSpliceVerificationError where error.reason == .baseNotSpliceable {
              didFallBackToFullVerificationForTesting?("\(error.reason)")   // DEBUG
              return try ArchiveReader.open(source: source, sourceURL: hint, options: verificationOptions)
          }
      }
      ```
   3. 全体の open へ戻るのは `.baseNotSpliceable`（base に地図が無い他ツールの書庫、など）のときだけ。それ以外の `TarSpliceVerificationError`（`.outputChanged`、`.invalidSegments`、`.reusedBytesDiffer`、`.inconsistentBaseMap`、`.dictionaryMismatch`、`.encodedSegmentInvalid`、`.framingMismatch`、`.checksumMismatch`）と `KaitoError` は、既存の catch（:592-593）で `ArchivePublicationError.verificationFailed` になり、公開しない。自動で書き直しへも回さない（P3-K の最終版と同じ）。GK の segment の列が出力と食い違うことは GK の不具合で、全体の open は内容の置き違いを捕まえられないため。
   4. ZIP の `outputProbe` は対象外。
   5. `measure(.entryComparison) { try expectedOutput.resolving(publishedMode).validate(verified, format: outputFormat) }`（P2-A の `.update` の投影。生存 entry を元の順、追加を末尾、並び順も照合）。
   6. P1-A の `ArchiveVerifiedOutput`（hint、source、reader、`verificationPassword: nil`、format）を sink へ渡す。
7. 以降（`willPublish`、原本と作業ファイルの同一性、rename、:601-620）は今どおり。原本へ書くのは最後の rename 1 回だけ。

### A3 session の reader の受け渡し

1. `append`・`createFolder`・`edit`・`savePending` では、P2-A の解決の後の mode が圧縮 tar の `.update` のとき、`publishing { }` の closure の中で `try reader.reopen()` を呼び、その結果を直接 `sessionReader:` 引数へ渡す（ローカル変数に入れて closure で捕捉しない。`sending` の region を保つため）。`reopen()`（KK ArchiveReader.swift:581-627）は解析と staging を共有し、P3-K により snapshot も引き継ぐ。`reopen()` は一回だけ（K5 の base は publish がこの reader から採る）。
2. 地図の記録は、`ReaderOptions.kaitoFinder(password:)` が立てる `recordsTarEditLayout`（P3-K の SPI、既定 false）で有効になる。session の open（ArchiveSession.swift:135）、採用が失敗したときの開き直し（P1-A の `openAfterPublication`）、`ArchiveCapabilities.inspect(url:...)`（:73-77）、全体の検証 open の reader は、どれも `kaitoFinder` / `kaitoFinderVerification` の options で開くので snapshot を持つ。K5 の reader は option に依らず snapshot を持つ。
3. 採用（P1-A の `adoptVerifiedReader`）は format `.tar` の reader を受け入れ、`hint == sourceURL`、`contentEqualsAfterMove`、`source.isUnchanged()` を確かめて `reopen()` する。K5 の reader の `reopen()` は、snapshot を引き継ぐ（archive = 作業ファイルの記述子（公開後は原本のパスの inode）、image = K5 の合成、派生の地図）。変更は不要だが、圧縮 tar の採用と、採用の後の snapshot の `archiveIsUnchanged() == true` を試験で確かめる。
4. capability の再検査（`reloadAfterMutation` の `capabilityProbe`）は A1 の inspect を使う。`assess` は O(区切り数)。

### A4 保存時モード

1. `savePending` は P2-A の解決で mode を決め、圧縮 tar の `.update` なら A3 のとおり `sessionReader` を渡す。`ArchiveSaveReplayPlan.validateRepresentability`（:547）の対象は P2-A の規則のまま。
2. 所有者 ID は P2-A の `replay(on:progress:preservingOwnerIDs:)` がそのまま効く。`preserveOwnerIDs` かつ tar 系なら、追加項目に `sourceStamp` の uid/gid、directory とフォルダに 0 を渡す。P3-A で足すものは無く、圧縮 tar でも効くことを試験で確かめる。触らない member は updater が byte のまま運ぶ。
3. 保存の計画の検証、`publication` の境界、undo の扱いは今どおり。

### A5 分割セット

- `inspectSplit` の圧縮 tar は `.rewrite(f)` のまま。`ArchiveSplitWorkProducer.produce(source:...)`（:88-111）は変えない。
- P2-A の規則（`.update` が来たら `ArchiveEditError.staleSelection`）もそのまま。
- P3-K は分割巻（`volumeSet != nil`）に snapshot を作らないので、updater は使えない。
- 即時の分割保存（`allowsImmediateSplitSave`、ArchiveCapabilities.swift:93-98）も同じ。

### A6 進捗、取消し

- 進捗は P1b が `publish(…, commitProgress:)` に入れた写し方をそのまま使う（GK の `ArchiveUpdater.CommitProgress` の byte を `Progress` の単位へ）。
- 取消しの地点は今どおり: mutate の前後、commit の中（GK が部品ごとに確認する）、検証の後（K5 は reused の比較の 64 MiB ごとにも確認する）、公開の境界（:607-613）の前。
- 公開前に取り消すと作業ディレクトリごと消え（:533 の `defer`）、原本も session の reader も変わらない。公開の後の取消しは P1-A の規則どおり。

### A7 注意書きと文言

1. `ArchiveCapabilities.editNotice(options: WriterOptions, onSave: Bool) -> String?`:
   - `resolved = mode?.resolved(with: options)` を求める。
   - `resolved` が `.rewrite(f)` で、元の mode が `.update(.tar)` でないとき: onSave なら「保存するとアーカイブ全体を再圧縮します」、でなければ「編集するとアーカイブ全体を再圧縮します」（既存の 2 キー）。非圧縮 tar は P2-A のとおり注意書きなし。
   - `resolved` が圧縮 tar の `.update` で、`compressedTarAssessment == nil`（open で rewriter に戻る書庫）のとき: 上と同じ既存のキー。
   - `resolved` が圧縮 tar の `.update` で、`compressedTarAssessment!.nextEditReencodesEverything` のとき: onSave なら「最初の保存でアーカイブ全体を再圧縮します」、でなければ「最初の編集でアーカイブ全体を再圧縮します」（新しい 2 キー）。
   - それ以外は nil。
   - `nextEditReencodesEverything` は、地図が無い・CRC32 以外の xz、または区切りが 1 つで image が S を越える場合（P3-G D9）。小さな書庫は区切りが 1 つでも全体の作り直しが軽いので、表示しない。
2. `ArchiveWindowController.refreshCapabilityNotice(session:)`（:776-792）では、:777 の `rewriteNotice` と、保存時に既存のキーへ置き換える処理（:778-781）を `editNotice(options:onSave:)` に置き換える。`preferencesDidChange(_:)`（:157-158 で登録）と capabilities の observer で再計算する。
3. 新しいキー 2 つの 26 言語の訳を入れる（`state: translated`）。既存の「編集するとアーカイブ全体を再圧縮します」（en: "Editing will recompress the entire archive."）と「保存するとアーカイブ全体を再圧縮します」（en: "Saving recompresses the entire archive"）の各言語の語彙に揃え、「最初の編集で」「最初の保存で」を足す。句読点の有無も既存のキーに揃える。既存のキーの訳は変えない。

### A8 計測

1. P0b の probe は GK の内部を測れないので、`PerformanceProbeTests` / `ArchivePerformanceProbe` は updater の commit の後に `@_spi(Testing) import GyoshukuKit` で `lastCommitStatistics` を読み、`PROBE-SPLICE` 行に出す。内容は段（plan・encode・copy・selfCheck、commit に入れ子）、戦略、作り直した旧 image の byte、運んだ圧縮 byte、付随の保存領域へ書いた byte。TSV の既存の列の意味は変えない。
2. 圧縮 tar の行から `rewriter_open` と `reload_open` が消える（採用）。`verification_open` は K5 の時間になる。
3. 検証の文書に P3 の節を書く: 実行の構成（三つ組の worktree、同じ機械・設定、load average）、段ごとの表、書込み MB、GK と K5 の段、連続 10 編集の書込み（K5 の合成の写し、P3-K K5「断片が 1,024 を越えるか葉の source が 8 を越えたら…写し」の頻度と量）。

## CONSTRAINTS

1. KaitoFinder だけを編集する。GyoshukuKit・KaitoKit は変えない。コミットしない。Swift 6 strict concurrency。`ArchiveReader` は actor が所有したまま、`reopen()` した独立の reader だけを `sending` で transaction へ渡す。
2. 公開前の検証を弱めない。次を全て通ったものだけを rename する。検証の失敗で書き直しへ自動で回さない。
   - GK の自己照合。
   - GK の出力の同一性と検証した記述子の照合。
   - K5（全体の open へ戻るのは `.baseNotSpliceable` だけ）。
   - P2-A の計画との照合（並び順を含む）。
   - 公開直前の原本と作業ファイルの同一性（:603-612）。
3. 原本へは rename 以外で書かない。GK へは原本の URL を渡さない（GK は reader の記述子だけを読む）。
4. 従来の設定の経路（`.rewrite`）の挙動・出力は P2-A の後と同じ。その出力の区切りは G1 の配置になる。ZIP / 7z / LHA / 非圧縮 tar・分割セットの経路を変えない。
5. 新しい文言は 2 キーだけ、26 言語。既存のキーの訳を変えない。
6. 分割セットの公開の仕組み（`VolumePublish*`、journal、ArchiveSplitSave.swift の検証）に触らない。
7. 計測の閾値を満たさないときは下げず、TSV・段・`sample` を添えて報告する。
8. `@_spi(TarEditLayout) import KaitoKit` は、`ArchiveReaderOptions.swift`・`ArchiveVerifiedOutput.swift`・`ArchiveImportTransaction.swift`（と試験）だけに置く。

## ACCEPTANCE CRITERIA

1. `xcodebuild build-for-testing` が通り、全試験が通る。オーケストレータが、画面をロックしない状態で memory の xcodebuild-verification-pitfalls に従って実行する。変えた既存の assert は全て理由付きで報告されている。
2. **`CompressedTarRoutingTests`**: 次の組み合わせで、capability の mode（`.update(f)`）、解決した mode、注意書き（即時と保存時）、GK の戦略が A1-3 と A7 の表どおりになる。
   - 形式: tar.gz / tar.bz2 / tar.xz。
   - 設定: 新・新 / 追加だけ従来 / ID だけ従来 / 両方従来。
   - framing:
     - GK の新配置。
     - GK の旧配置（`SP/p3k/fixtures/tar-edit/*.b64`。P3-K の Step 0-c でオーケストレータが c0df9fb の gyoshuku-bench で作った小さな実出力を試験 fixture に写す）。
     - 他ツールの単一 stream（`/usr/bin/gzip -6`、`/usr/bin/bzip2`、`xz` の既定 CRC64）。
     - `xz --check=crc32 --block-size=1MiB` の複数 block。
3. **`CompressedTarPublishTests`**:
   - 三形式それぞれについて、GK の新配置と旧配置、1 byte の小項目と数 MiB の本文を混ぜた fixture で、即時の追加・先頭と末尾の削除・同長と異長の改名・フォルダ改名・移動・新規フォルダ・置換を行う。
   - それぞれで次が成り立つ。
     - (a) 公開された書庫を `ArchiveReader.open(url:)` で開き直した一覧と各 entry の SHA-256 が計画どおり。追加は末尾。触らない member の header byte が原本と同一。
     - (b) 公開の後の session の reader が採用され（`ArchiveSession.readerAdoptionObserver` が `.adopted`）、その snapshot の `archiveIsUnchanged()` が true。編集 1 回で URL からの open が無い（`ReaderOptions.kaitoFinderOpenCount` の増分は検証用の options を作る 1 回だけ）。計測の TSV に `reload_open` の行が無く、`reader_adoption` の行がある。`didFallBackToFullVerificationForTesting` が呼ばれない。
     - (c) 3 回続けた編集がどれも継ぎになり（GK の戦略 `.splice`）、毎回採用される。
     - (d) 出力が `gzip -t` / `bzip2 -t` / `xz -t`、`bsdtar -tvf`、`7zz t`、Python `tarfile` を通る。
     - (e) 変更した commit の出力を復号した長さが 10,240 の倍数。
   - uid 501 / gid 20 / uname `alice` / `LIBARCHIVE.xattr` の pax / `._` member を含む `bsdtar -czf` の書庫では、1 回目の編集が `fullEncode`、2 回目が `.splice` になり、どちらの後も触らない member の header byte が原本と同一。
4. **他ツールの framing**（`gzip -6` / `bzip2` / `xz` の既定で作った tar.gz / tar.bz2 / tar.xz）:
   - 1 回目の編集が `fullEncode` になり、追加は末尾、触らない member の byte は同一。2 回目が `.splice`。
   - 注意書きは、1 回目の前に新しい文言（即時 / 保存時）、後に nil。
   - base に地図が無い書庫（二つの gzip member の連結、stream padding 付きの xz）では、検証が全体の open へ戻り、`didFallBackToFullVerificationForTesting` が一度呼ばれる。
   - `xz` の既定（CRC64、複数 block）と `bsdtar -cJf` の書庫では、1 回目の編集の出力（CRC32 の `fullEncode`）を K5 が受理し、`didFallBackToFullVerificationForTesting` は呼ばれない。
   - 4a. 全件を削除した後の追加（image が終端だけの圧縮 tar）が、三形式の即時と保存時モードで成功し、capability が読み取り専用にならない。
   - 4b. `.update` の tar.gz / tar.bz2 / tar.xz で、`\` と `:` を含む名前への改名と、その名前の新規フォルダが通る（`reservationFormat` が P2-A により `outputFormat` になり、tar の規則を使う。GK 95fef0e）。NFD の名前の member と NFC の同じ名前への改名が衝突として拒否される。
5. **`CompressedTarDeferredSaveTests`**:
   - 5 変更の保存（削除・改名・追加・フォルダ・置換）が updater の経路で 1 回の commit になる。
   - 所有者 ID の保存を有効にしたとき、追加項目の uid/gid が元のファイルの `sourceStamp` の値、追加 directory が 0、触らない member は原本の byte のまま。
   - 保存後に採用され、次の保存も継ぎになる。
   - `comment` 以外の `g` を持つ tar.gz では、`requiresRewrite` で rewriter へ戻る。mutate は一度だけで、stage に `.updaterOpen` と `.rewriterOpen` が一度ずつ、`progress.completedUnitCount` が二重に数えられない。
6. **`CompressedTarSplitRegressionTests`**: `.tar.gz.001` 〜 の numbered セット（即時と保存時）で、capability が `.rewrite(.tarGzip)` のまま、今と同じ経路（`ArchiveSplitWorkProducer.rewrite`）で保存でき、公開後の巻の連結が計画どおりの書庫になる。
7. **`CompressedTarVerificationFailureTests`**:
   - 次の場合に、publish が `ArchivePublicationError.verificationFailed` を投げ、原本の byte と inode、session の reader と世代が不変で、作業ディレクトリが残らず、capability が読み取り専用にならない。
     - GK の `testingFault` の GK 側の各種。
     - `testingSkipsSelfCheck` 付きの K5 側の各種（P3-G D11-10）。
     - commit の後に作業ファイルを差し替える（`didCommitForTesting`）。
     - 検証の前に作業ファイルの mtime を変える。
   - session の open の後、編集の前に、原本の運ぶ範囲の 1 byte を同じ長さのまま書き換えて mtime を戻す（試験の中で pwrite と `utimes`）と、GK が `UpdaterError.sourceChanged` を投げて公開しない。原本は試験が書いたとおりで、それ以外は変わらず、作業ディレクトリが残らない。
   - bzip2 の stream の欠落と xz の最後の block の欠落（自己照合なし）は、K5 の合成の解析か計画との照合で拒否される。
8. **取消し**: mutate・commit・K5 の検証のそれぞれで取り消すと、原本と session が不変。公開の後の取消しは P1-A の規則どおり（再読込の失敗にならない）。
9. **`CompressedTarNonAPFSTests`**: `VolumePublishTestDisk("HFS+")` と `("ExFAT")` の上の tar.gz / tar.xz で、即時の削除・追加・同長改名と保存が成功し、結果が APFS の上と entries・内容で一致し、採用される（hdiutil が無ければ skip）。
10. **P0b の計測**（-O・wholemodule の Debug、`run_probes.sh` と同じ構成、load average を記録、P3 の直前の三つ組と同じ機械で比較）:
    - 本文 256 MiB（4 MiB × 64）+ 1,000 件の total:
      - tar.gz: 先頭・末尾の削除、同長・異長の改名、1 件追加、新規フォルダ、置換 ≤ 900 ms。保存（5 変更）≤ 1,300 ms。
      - tar.bz2: 同じ操作 ≤ 2,500 ms、保存 ≤ 2,900 ms。
      - tar.xz: 1 件追加・新規フォルダ ≤ 1,500 ms（新しい配置では終端の区切りだけが橋）。先頭・末尾の削除、同長・異長の改名、置換 ≤ 9,000 ms、保存 ≤ 9,500 ms。末尾の削除は最後の payload member と小項目を含む最後の区切り（≈ 5 MB）を作り直すため、1,500 ms の群に入れない。
      - フォルダ改名は三形式とも ≤ 直前の基準（payload の全 member の header が変わり、全区切りを作り直すため）。値を P14 の入力として記録する。
    - `verification_open`（K5）は、フォルダ改名を除き、直前の基準の `verification_open` に対して tar.gz ≤ 60 %、tar.bz2 ≤ 10 %、tar.xz ≤ 35 %（P3-K の見込みの門）。
    - 圧縮 tar の行に `rewriter_open` と `reload_open` が無い（従来の設定で測る行を除く）。
    - 書込み MB（本文 fixture の先頭削除）≤ 出力の書庫のサイズ + 16 MB（今 955 / 940 / 931 MB）。
    - 1 byte × 100,000: tar.gz / tar.bz2 / tar.xz の各操作 ≤ 同じ実行の非圧縮 tar（P2 の後）の同じ操作 + 700 ms。1 byte × 500,000 の tar.gz ≤ 同じ実行の tar + 1,500 ms。1 回の編集の書込み MB ≤ 出力の書庫のサイズ + 16 MB（今 1,541 MB）。連続 10 編集の書込みの合計と、K5 の合成の写しの回数を報告する。
    - 従来の設定での圧縮 tar と、ZIP / 7z / LHA / 非圧縮 tar の各行が、直前から ±10 % 以内。
    - session の open（`recordsTarEditLayout` を立てた費用と K4 の並列 bzip2）: 操作 `open` の `total`（`document_ready` まで）が、本文 fixture と 100k の各形式で、tar.gz ≤ 直前の基準 × 1.13、tar.xz と非圧縮 tar ≤ × 1.05。tar.bz2 は本文 fixture で ≤ × 0.5、100k（解析と木の構築が支配）で ≤ × 0.7。ZIP・7z・LHA は ±10 % 以内。
    - 「直前の基準」は ORDER-P2-P3.md §3 の B-P3（KaitoKit は S6。K4 の前の直列の bzip2）。`verification_open` の tar.bz2 ≤ 10 % も、この直列の基準に対するもの。
11. `Localizable.xcstrings` の新しい 2 キーが 26 言語全てで translated。`WordingAcceptanceTests` の一覧に入っている。
12. 検証の文書に P3 の節があり、計画の P3 行の状態が更新されている。

## VERIFICATION COMMANDS

```sh
cd /Users/nagash/Github/KaitoFinder
S=/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad
git -C ../GyoshukuKit log -1 --oneline; git -C ../GyoshukuKit status --short
git -C ../KaitoKit log -1 --oneline; git -C ../KaitoKit status --short
git grep -n "case .inPlace\|case .rewrite\|case .update\|\.rewrite(let\|\.update(let" -- KaitoFinder   # mode の網羅の漏れがないこと
git grep -n "@_spi(TarEditLayout)" -- KaitoFinder   # ArchiveReaderOptions.swift・ArchiveVerifiedOutput.swift・ArchiveImportTransaction.swift だけ
git grep -n "recordsTarEditLayout" -- KaitoFinder     # kaitoFinder(password:) の 1 か所だけ
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath $S/p3a-dd build-for-testing
ONLY=()
for t in CompressedTarRoutingTests CompressedTarPublishTests CompressedTarDeferredSaveTests CompressedTarVerificationFailureTests \
  CompressedTarSplitRegressionTests CompressedTarNonAPFSTests ArchiveRewriteTests ArchiveCapabilityInspectionTests \
  ArchiveReaderAdoptionTests DeferredSplitSaveTests ImmediateSplitInteropTests DeferredSaveUITests WordingAcceptanceTests \
  TarUpdateEditTests DeferredSaveAttributeTests; do ONLY+=(-only-testing:KaitoFinderTests/$t); done
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath $S/p3a-dd -parallel-testing-enabled NO "${ONLY[@]}" test-without-building
# 全件（オーケストレータ。画面のロックと古い bundle に注意）
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath $S/p3a-dd -parallel-testing-enabled NO test-without-building

# 文言
python3 - <<'EOF'
import json
d = json.load(open('KaitoFinder/Resources/Localizable.xcstrings'))
for k in ('最初の編集でアーカイブ全体を再圧縮します', '最初の保存でアーカイブ全体を再圧縮します'):
    loc = d['strings'][k]['localizations']
    print(k, len(loc), all(v['stringUnit']['state'] == 'translated' for v in loc.values()))
EOF

# 計測（オーケストレータ。三つ組の worktree を $S/v2 と同じ配置で作り、-O の Debug で build-for-testing の後）
cd $S/v2/KaitoFinder   # P3 の三つ組に差し替えた worktree
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath $S/v2/dd-opt SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule build-for-testing
uptime
TEST_RUNNER_KAITOFINDER_PERFORMANCE_PROBES=1 TEST_RUNNER_KAITOFINDER_PROBE_ENTRIES=2000 \
TEST_RUNNER_KAITOFINDER_PROBE_FORMATS=zip,tar,tar.gz,tar.bz2,tar.xz,7z,lha TEST_RUNNER_KAITOFINDER_PROBE_PAYLOAD_MIB=256 \
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath $S/v2/dd-opt -parallel-testing-enabled NO -only-testing:KaitoFinderTests/PerformanceProbeTests \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule test-without-building > $S/p3a-probe-payload.log 2>&1
zsh $S/v2/run_probes.sh     # 100k 全形式、500k の zip,tar,tar.gz
uptime
grep -a PROBE-TSV $S/p3a-probe-payload.log | awk -F'\t' '$3 ~ /tar/ && ($7=="total" || $7 ~ /^(rewriter_open|updater_open|commit|verification_open|entry_comparison|reload_open|reader_adoption)/)'
grep -a PROBE-SPLICE $S/p3a-probe-payload.log
```

Codex は sandbox で動く範囲だけを実行し、何を実行したかを正確に報告する。xcodebuild・GUI・全件・計測はオーケストレータが行う。
