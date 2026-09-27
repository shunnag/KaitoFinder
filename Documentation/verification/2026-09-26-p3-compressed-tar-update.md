# S16 / P3-A: 圧縮 tar の区切り単位の更新

2026-09-26。KaitoFinder `feature/2026-09-24-review`、基底 `54c2b8d`。
P3-A AC1–AC12、ORDER-P2-P3 §1–§2、ORDER-P4-P5 §1.3 に対応する実装。
初回実装時の直接コンパイル・選択試験と、その後のオーケストレータの全件実行による指摘への修正を記録する。
直接実行を hosted GUI・全件・B-P3 と比較する受入計測の合格とは扱わない。コミットしていない。

## 依存と実装

| リポジトリ | 読み取った committed HEAD |
|---|---|
| KaitoFinder | `54c2b8d`（P2-A `f47d361`、P9 `500ce7a`、P2 受入計測 `f07428d`、tar 名前規則の補正を含む） |
| GyoshukuKit | `d5c51b3`（S15 / CompressedTarUpdater） |
| KaitoKit | `d35f2da`（S14 / K5） |

両 sibling の API 名は仕様と一致。ビルドにはその HEAD を `git archive` して
`build/P3AS16Verification/dependencies/` へ展開したものを使った。sibling の編集はしていない。

- 単一の `.tarGzip` / `.tarBzip2` / `.tarXZ` は `.update`。既存の表現可能性・権限・暗号化の門番は維持。
  assessment は注意書きだけに使用し、経路は従来どおり編集ごとの WriterOptions で解決する。
- `append` / `createFolder` / `edit` / `savePending` は、解決後の三形式の `.update` にだけ、一回の `reopen()` の結果を直接 `sessionReader:` へ渡す。
  publish が snapshot を採ってから `sending` reader を GK へ渡す。open の計測には closure を使わず、DEBUG の begin/defer-end を使った。
- `requiresRewrite` を捕まえる範囲は open のみ。mutate と commit での同名エラーはそのまま失敗する。
  `willOpenUpdater` は各 `.update` の open 前に一度。`rewriteBranch(format:)` では呼ばない（ORDER45 §1.2 維持）。
- commit の自己照合、出力の device/inode/size/mtime と検証記述子の照合、K5、解決後の計画・順序照合、公開直前の同一性検査をすべて通す。
  `.baseNotSpliceable` だけ同じ出力を全体 open で検証し、他の K5 拒否で書き直しに戻らない。
- 検証した reader の採用は既存機構を使用。`ArchiveVerifiedFileSource` は保持する記述子の fstat を SPI の identity として返す。
  mtime を検証後に変更しない。属性・quarantine の復元は検証前。
- publish / reader hand-over / `editNotice` は三形式を明記。後続の `.update(.lha)` / `.update(.sevenZip)` を巻き込まない。
- 新しい設定キーはない。既存の `ArchiveAdditionPlacement` / `ArchiveTarCarriedOwnerIDs` は `TestProcessSetup.autosaveKeys` と `AutosaveIsolationTests` に既に含まれる。
  French のコロン付き既存キーを含め、既存の訳は変更していない。
- `TarEditLayout` の製品 import は `ArchiveReaderOptions.swift` / `ArchiveVerifiedOutput.swift` / `ArchiveImportTransaction.swift` の三か所だけ。

## AC と試験

| AC | 対応 |
|---|---|
| 1 | 全ソースの直接 DEBUG コンパイル、Release 型検査、下記の選択実行。通常 host の全件は待ち |
| 2 | `CompressedTarRoutingTests`: 三形式 × 四設定 × GK 新配置 / 凍結した旧配置 / 外部単一 stream、xz CRC32 複数 block。mode・resolved mode・即時/保存の notice・戦略。reader 不在と snapshot 不在も区別 |
| 3 | `CompressedTarPublishTests`: 新旧配置の9操作（追加・両端削除・同長/異長改名・フォルダ改名・移動・新規フォルダ・置換）、一覧の順序・全本文の SHA-256・運ぶ header group の byte・採用・検証 options 一回・新旧それぞれ3連続 splice・外部互換・10240 の倍数 |
| 4 | 外部 gzip / bzip2 / CRC64 複数 block xz、bsdtar gzip / xz は fullEncode → splice。gzip member 連結 / xz padding は一度だけ full verification。uid/gid/uname/pax/AppleDouble、空書庫再追加、POSIX 名と NFC 衝突 |
| 5 | `CompressedTarDeferredSaveTests`: 5変更（置換は削除と追加）、sourceStamp の所有者、directory の0、運ぶ header、1 commit、次回保存の splice。global uid fallback と mutate/commit の requiresRewrite 非再生 |
| 6 | `CompressedTarSplitRegressionTests`: numbered tar.gz の即時/保存時は rewrite のまま。native と controlled coordination の別 case。連結した公開巻の一覧・内容を照合 |
| 7 | `CompressedTarVerificationFailureTests`: GK 全 fault、自己照合を無効にした K5 fault、作業ファイル差替え/mtime、元 inode の同長書換えと mtime 復元。byte・inode・世代・一覧・編集可否・cleanup・非 fallback を照合 |
| 8 | mutate / commit の進捗 / K5 入口での取消しと、公開後の取消しの採用 |
| 9 | `CompressedTarNonAPFSTests`: HFS+ / ExFAT / MS-DOS FAT32、tar.gz / tar.xz、即時削除・追加・同長改名・保存を APFS の一覧と本文 SHA-256 に比較。hdiutil 不可なら skip |
| 10 | probe の updater 経路・`PROBE-SPLICE`・10連続編集・下記の placement knob。`EditPlacementPreferencesTests.testProbePlacementEnvironmentMatchesSessionOptionsAndRequiredStage` で env→options→resolved mode/stage、ZIP例外、不正値を照合。性能受入は待ち |
| 11 | 新規2キー×26言語、translated・空値・日本語・bundle の照合を `WordingAcceptanceTests` に追加 |
| 12 | 本書と計画の P3 行 |

GK の `shiftLedger` は内部の image ledger だけを壊す fault で、K5 に渡す公開 segment 列には現れない。
GK 自己照合ありの試験に含め、自己照合なしの K5 試験からだけ除外した（GK 自身の `CompressedTarSelfCheckFaultTests` と同じ）。
欠落した bzip2 stream / xz block は K5 の解析または KF の計画照合で拒否する。

旧配置の fixture は P3-K Step 0-c の `gz.tgz.b64` / `bz.tbz.b64` / `xz.txz.b64` をコピーした。
`KaitoFinderTests/Fixtures/TarEdit/README.md` に元の生成 commit と SHA-256 を記録。

## 変更した既存 assertion と理由

- `ArchiveRewriteTests.assertCapability`（tar / TGZ / 7z / LHA）、`testTarWrapperDetectionUsesMagicInsteadOfExtension`、
  `testTarBzip2AndXZCapabilitiesEnableTheCorrectWriter`: 単一圧縮 tar は `.update(format)`、構造だけの `rewriteNotice` は nil。
- `ArchiveRewriteTests.assertDocumentEditsAndUndo` の初回と undo 後の mode、および共通の追加進捗:
  圧縮 tar も updater の1000単位を使う。本文・undo の SHA-256・世代の照合は維持。
- `ArchiveRewriteTests.testWindowRewriteNoticeContainsRecompressionAndZIPDoesNot`: notice と hidden を解決した mode と framing の notice に合わせた。
  外部 stream の最初の編集は新しい文言になる。read-only / ZIP の assert は維持。
- `ArchiveRewriteTests.testTarGzipRewriteHonoursPreferredCompressionLevel`: `.beginning` を明示し、名前どおり従来 rewriter の圧縮レベル試験として維持。
- `M6cNameRuleTests.testTarDeletePreservesNameBytesInBothSaveModes`: 三形式の mode を `.update(format)` に更新。生 byte 保存の assert は維持。
- `DeferredSaveUITests.testProjectionRefreshesNoticeAndEnablesPendingExtractionActions`: GK 新配置の既定設定では保存前/保存後の注意書きは空。
  未保存件数と操作可否は維持。設定変更で従来 notice を表示する case、外部 stream の最初の保存 notice の case を追加。
- `PerformanceProbeTests`: 即時/保存/direct の tar 系 open stage を updater にし、`.beginning` で反転。
  ZIP の updater は設定に関係なく維持。open の probe は entries に加え payload も実行する。

明示的に `.rewrite(.tarGzip)` を指定して rewriter の公開検証を試す既存試験、分割セット、
投影の fallback 比較はそのまま残す。単一ファイル capability の期待値との混同を避けるため全テストを検索した。

## 初回実装時の実行結果

Xcode の `swiftc` / `xctest` を直接使用。target は `arm64-apple-macos26.0`、Swift 6、
`-Onone`、DEBUG、MainActor default isolation、`NonisolatedNonsendingByDefault` / `InferIsolatedConformances`。
KaitoKit 203、GyoshukuKit 48、アプリ101、テスト137の Swift ソースをコンパイルした。
既存の Sparkle framework をリンクし、ライブラリのスタブは使用していない。

- **成功**: 依存二つとアプリの直接ビルド、全テストソースの直接コンパイル、アプリの DEBUG なし Release 型検査。
  app / Release の警告は0。テストには既存の `ArchiveDocumentControllerTests` / `ArchiveEditTests` / `ArchiveImportSafetyTests` の警告が残る。
- **選択試験の最終状態（同じ case の再実行は重複計上しない）: 114成功、9 skip、native coordination の3失敗、Save As の1中断**。
  case 名とログの対応は [final-summary.json](../../build/P3AS16Verification/final-summary.json)。全件成功という意味ではない。
- **成功**: `git diff --check`、新規2キー×26言語の translated 検査、既存の全 catalog entry が HEAD と同一であること、
  SPI import 許可リスト・records option の一か所・明示三形式・willOpenUpdater の配置・全テストの mode/notice/進捗期待値の検索。
- **実行していない**: `xcodebuild build-for-testing` / `test-without-building`、通常 host の GUI / 全件、PerformanceProbeTests の実測、B-P3 比較、`sample`。
  P0b / AC10 の性能値を今回の機能テストの所要時間から推定していない。

| 選択 | 成功 | skip | 失敗 / 中断 |
|---|---:|---:|---:|
| CompressedTarRoutingTests | 3 | 0 | 0 |
| CompressedTarPublishTests | 7 | 0 | 0 |
| CompressedTarDeferredSaveTests | 3 | 0 | 0 |
| CompressedTarVerificationFailureTests | 5 | 0 | 0 |
| CompressedTarSplitRegressionTests | 1 | 0 | 1（native） |
| CompressedTarNonAPFSTests | 0 | 3 | 0 |
| ArchiveCapabilityInspectionTests | 10 | 1 | 0 |
| ArchiveReaderAdoptionTests | 12 | 2 | 0 |
| TarUpdateEditTests | 9 | 3 | 0 |
| ArchiveImportTransactionVerificationTests | 12 | 0 | 0 |
| M6cNameRuleTests | 11 | 0 | 0 |
| ArchiveRewriteTests（window notice の1件を除く全33件） | 33 | 0 | 0 |
| DeferredSaveAttributeTests | 5 | 0 | 1（exit 69） |
| WordingAcceptanceTests.testFirstCompressedTarEditWordingHasAllTwentySixTranslations | 1 | 0 | 0 |
| AutosaveIsolationTests.testAutosaveKeysCoverAllApplicationAutosaveNames | 1 | 0 | 0 |
| EditPlacementPreferencesTests.testProbePlacementEnvironmentMatchesSessionOptionsAndRequiredStage | 1 | 0 | 0 |
| DeferredSplitSaveTests.testEveryWritableNumberedFormatReplaysOnceAndSecondSaveDoesNothing | 0 | 0 | 1（native） |
| ImmediateSplitInteropTests.testImmediateEditsAndSaveAsPassSevenZipAndInfoZIPInterop | 0 | 0 | 1（native） |

3件の native 失敗:

- `CompressedTarSplitRegressionTests.testNumberedSetsStillRewriteInBothSaveModes` は即時の最初の保存で、staging 作成前に
  Foundation の「archive.tar.gz.001 を保存できませんでした」を返した。この case の保存時モードには到達していない。
- 切り分けのため、変更していない既存 `DeferredSplitSaveTests` / `ImmediateSplitInteropTests` の上表の各1件も実行した。
  ともに最初の **7z** セットで同じ native 調整の失敗を返し、圧縮 tar には到達していない。
- 新規の `testNumberedSetRoutingAndPublicationWithControlledCoordination` は既存の coordination 注入境界だけを使い、
  producer・検証・公開・再読込を実物のまま実行して、即時/保存時とも成功。
  native を使う元の case はそのまま残してあり、skip 化や期待値変更はしていない。
  この切り分けは既報の [standalone harness の制約](2026-09-23-m6-immediate-split-and-save-as.md) と一致するが、hosted 合格の代わりにはならない。

`DeferredSaveAttributeTests.testDeferredTarPreservesSourceOwnerIDsThroughSaveAndSaveAs` は
`ClientCallsAuxiliary` / `HostCallsAuxiliary` の NSXPC listener が `Connection invalid` になり process exit 69。
その case は未完了。残る5件は個別実行を含め成功した。新規の所有者保存は `CompressedTarDeferredSaveTests` でも確認した。

skip 9件の内訳は、HFS+ / ExFAT / FAT32 の新規3件と既存 TarUpdateEditTests の3件、既存 reader adoption のHFS+/ExFAT 2件、
opt-in の100k ZIP open 計測1件。ディスク8件はいずれも `hdiutil create` が「装置が構成されていません」で失敗。

初回の新規 empty-archive case は、folder の子を含まない選択を渡したため staleSelection で失敗した。
実際の UI と同じ部分木選択へテストの準備を修正して再実行し、三形式×即時/保存時のすべてが成功。
その他の新規 publication 6件は初回から成功（新旧配置の9操作、外部 codec / bsdtar / 7zz / Python tarfile の互換検査を含む）。
初回ログは [initial/](../../build/P3AS16Verification/initial/)、最終の追加選択は
[final-selection.json](../../build/P3AS16Verification/final-selection.json) に保存した。

再現用の直接コマンドと各 invocation の結果は `build/P3AS16Verification/` の
`*-command.json`、`test-results.json`、`regression-results.json`、`final-results.json`、各 `.log` にある。
`build.py KaitoKit GyoshukuKit app` → `build.py test` → `package-resources.py` → `run-tests.py` / `run-regressions.py` / `run-final.py` の順。
初回の test command は旧 module path を参照していたため修正し、現在の app module で全テストをコンパイルし直した。
production の `sending` は初回から通った。direct probe の nested 計測 closure だけは region 検査に拒否されたため、
reader を outer observer の中で作り、total/open を begin/defer-end で測る形へ変更して通した。
`uptime` の記録は `05:20, load averages: 6.55 5.22 5.25`。これは機能検証時であり、性能受入の load <4 条件を満たす実行ではない。

## オーケストレータの残りの検証

修正1後も P3-A の VERIFICATION COMMANDS に従い、ロックしていない画面と各 committed head の三つ組で、
`xcodebuild build-for-testing`、対象クラス、全件を実行する。HFS+ / ExFAT / FAT32 の skip をそこで解消する。
B-P3 は KK S6 / GK S11 / KF S13（K4 並列 bzip2 前）の基準を使う。

`KAITOFINDER_PROBE_ADDITION_PLACEMENT=end` が既定。`beginning` は document の preferences と direct editor の options に伝わり、
tar 系では updater 要求/rewriter 禁止を反転する。不正値は構成エラー。defaults には保存しない。
`TEST_RUNNER_KAITOFINDER_PROBE_ADDITION_PLACEMENT=beginning` で xcodebuild の test runner に渡せる。

`PROBE-TSV` の列は変えていない。追加の `PROBE-SPLICE` は format / fixture / mode / operation に加え、
戦略、plan / encode / copy / selfCheck の ms、旧 image の再符号化 byte、運んだ圧縮 byte、scratch byte、
全再符号化 byte、運んだ/作り直した区切りの数を出す。
`testTenConsecutiveCompressedTarEditsWhenEnabled` は同じ session で10回の編集を測り、各回の書込みを既存 TSV に出す。
`PROBE-SPLICE-IMAGE` は採用する image の実型と長さを出す。`KaitoKit.SplicedTarImage` 以外へ materialize された回の数と長さを
合計すれば、K5 の断片/葉上限による合成の写しの頻度と量を確認できる。

正式計測で記録する表（未測定を合格とは扱わない）:

| 対象 | 段 / 合格条件 | 状態 |
|---|---|---|
| payload 256 MiB、三形式 | 各操作 total / verification_open / 書込み量、P3-A AC10 の絶対値と B-P3 比 | 未実行 |
| entries 100k、tar.gz 500k | 非圧縮 tar 比 +700 / +1500 ms、出力サイズ +16 MB | 未実行 |
| 10連続編集 | 書込み合計、K5 合成の写し回数・byte | 未実行 |
| 従来設定、他形式 | B-P3 ±10% | 未実行 |
| session open | gzip ×1.13、xz/tar ×1.05、bzip2 payload ×0.5 / 100k ×0.7、他形式 ±10% | 未実行 |

計測時には同じ機械・-O / wholemodule の Debug・load average 4 未満をそろえ、`uptime` と TSV を残す。
閾値を下げず、未達なら `sample` を採り、GK と K5 の時間を分けて報告する。

## 修正1: 圧縮 tar の hard-link の期待値

オーケストレータから、KK `d35f2da` / GK `d5c51b3` と P3-A 作業ツリーを隔離した三つ組で、
画面ロックなしの全件1,508件を実行したとの報告を受けた。既知の環境依存 GUI 失敗（native drag / sidebar toggle）以外の新しい失敗は
`ArchivePublicationTransformationTests.testHardLinkDirectTargetsAndChainsPublishImmediatelyAndDeferred` のみ。
この1,508件は今回こちらで実行したものではない。

同試験は plain tar だけ updater の期待値にし、単一の圧縮 tar には rewriter の期待値を残していた。
既定では四つの tar 形式すべてに P2 §G6.1 の規則を期待するように改めた。
直接参照と chain に対し、参照先の削除・改名、link の削除、両者の削除を、即時/保存時で確認する（4形式×2モード×4操作）。
AC-A9 の旧設定を残すため `testCompressedTarHardLinksUseRewriterRuleWithAdditionsFirst` を別に設け、
tar.gz と明示した `.beginning` で同じ2モード×4操作に今日の rewriter の結果を期待する。
entry の kind・size・実体の payload・直接の linkPath の照合を維持し、失敗文に形式・操作・モード・placement を加えた。
製品コード・設定キーの追加変更はない。

全テストを `rg` で hard-link / linkPath / 名前の byte / NFC・NFD / leading-dot / tar 専用分岐 / 明示 rewrite の語から再点検した。
追加の修正が必要な、単一圧縮 tar に rewriter の挙動を期待する assertion は見つからなかった。

- `TarUpdateProjectionTests` は四形式の `.update` を既に試し、fallback は明示した `.rewrite` と比較している。
- `ArchiveImportTransactionVerificationTests` の名前正規化・root 除外は `.rewrite` を明示する試験。
  `ArchivePublicationTransformationTests.testLinkSizesFollowOutputContainerDuringPublication` も明示した rewrite のまま。
- `M6cNameRuleTests` / `CompressedTarPublishTests` は運ぶ名前の byte の保存と NFC 衝突を既に期待する。
  `ArchiveEditPathTests` は plain tar の追加位置を明示し、保持名と正規化名を分けている。
- `DeferredSavePlanEquivalenceTests` とその reference は公開前の replay plan を比較するもので、出力コンテナの期待ではない。
  ZIP の改名、表示・衝突判定、抽出先、変換時の正規化も圧縮 tar の carried member の規則と混同していない。

修正1でこちらが実行したもの:

1. `python3 build/P3AS16Verification/build.py test`: 同じ committed dependency / app module に対し、全137テストソースの直接コンパイルを再実行、exit 0。
   初回と同じ既存警告4件のみ。製品コード・依存は再ビルドしていない。
2. `python3 build/P3AS16Verification/package-resources.py`: direct harness の framework と26言語の resource を再配置、exit 0。
3. `python3 build/P3AS16Verification/run-final.py ArchivePublicationTransformationTests TarUpdateProjectionTests M6cNameRuleTests`:
   下表の21件すべて成功、失敗0、skip 0。各クラスを `xctest -XCTest KaitoFinderTests.<class>` で実行した。
4. 全テストへの上記 `rg`、旧文書名の参照が残っていないこと、`git diff --check`、sibling の HEAD / clean status を確認。

| 修正1の選択 | 成功 | 失敗 | skip |
|---|---:|---:|---:|
| ArchivePublicationTransformationTests | 7 | 0 | 0 |
| TarUpdateProjectionTests | 3 | 0 | 0 |
| M6cNameRuleTests | 11 | 0 | 0 |

コマンドの完全な引数・case 名・結果・ログは [correction-1/](../../build/P3AS16Verification/correction-1/) の
`test-command.json` / `test-build.log` / `resource-commands.json` / `test-results.json` / クラス別 `.log` / `audit-commands.json` に保存。
この修正では `xcodebuild`・hosted GUI・全件・volume 試験・性能計測を実行していない。
KK `d35f2da` / GK `d5c51b3` は変更していない。コミットしていない。

**release notes に書く既定の変更**: 圧縮 tar の編集は既定で、変更せず運ぶ member の名前と byte を保つ。
hard-link は生存する実体保持 member へ参照先を付け替え、実体保持 member がない場合だけ実体化する（P2 §G6.1）。

## オーケストレータの検証（2026-09-26）

隔離した三つ組 `$SCR/v2`（KaitoKit d35f2da と GyoshukuKit d5c51b3 は `git archive`、KaitoFinder は作業ツリーの rsync）。画面のロックなし。

| 実行 | 結果 |
|---|---|
| build-for-testing | 成功 |
| 仕様の試験群（CompressedTar* の 6 クラス、ArchiveRewriteTests、ArchiveCapabilityInspectionTests、ArchiveReaderAdoptionTests、DeferredSplitSaveTests、ImmediateSplitInteropTests、DeferredSaveUITests、WordingAcceptanceTests、TarUpdateEditTests、DeferredSaveAttributeTests、AutosaveIsolationTests） | 181 件、失敗 0、skip 1（HFS+ / FAT の実 image を含む） |
| 全件 | 1,508 件。新しい失敗は `ArchivePublicationTransformationTests.testHardLinkDirectTargetsAndChainsPublishImmediatelyAndDeferred` の 1 件（圧縮 tar も updater の hard link の付け替えの規則になったのに、試験が書き直しの規則を前提にしていた）。他の失敗は既知の環境依存の GUI 系（ArchiveDropIntegrationTests 5、ArchivePreviewSidebarTests 1） |
| correction 1 の後、変更した試験を含む 4 クラス | 33 件、失敗 0（correction 1 は試験と文書だけの変更） |

受入計測（ORDER-P2-P3 §6.1 の P3 の行を B-P3 と比べる）は、負荷の平均が 4 未満のときに採り、この節の後に追記する（検証の時点では別の作業が機械を占有していた）。

## 受入計測（ORDER-P2-P3 §6.1 の P3 の行、2026-09-26 08:40〜09:30）

B-P3（KaitoKit 24311ac、GyoshukuKit da0af7b、KaitoFinder f47d361）と P3 の三つ組（KaitoKit d35f2da、GyoshukuKit d5c51b3、KaitoFinder d6bcfb4）を
`git archive` で作り、同じ -O・wholemodule の Debug で 100k（全形式）→ 100k → 500k（zip・tar・tar.gz）→ 500k の順に交互に実行した（本文 256 MiB）。
負荷の平均（1 分）は 3.8〜5.7。空きの段 S27〜S30 は P0b の行を変えない見込みで、B-P3 は S13 の commit で採っている（ORDER-P6-P13 §3.5）。

| 行（本文 256 MiB、即時） | B-P3 ms | P3 ms | 条件 |
|---|---:|---:|---|
| tar.gz 全操作（フォルダ改名を除く） | 1,772〜1,801 | 76〜117 | ≦ 900 |
| tar.bz2 全操作（同上） | 13,960〜14,114 | 48〜425 | ≦ 2,500 |
| tar.xz 追加・新規フォルダ | 18,717・18,751 | 68・118 | ≦ 1,500 |
| tar.xz 削除・改名・置換 | 18,612〜18,975 | 432〜4,316 | ≦ 9,000 |
| フォルダ改名 tar.gz / tar.bz2 / tar.xz | 1,792 / 14,044 / 18,775 | 1,043 / 9,805 / 17,546 | ≦ B-P3 |
| `verification_open`（K5、フォルダ改名を除く）の比 | – | tar.gz 0.13〜0.15、tar.bz2 0.00〜0.02、tar.xz 0.02〜0.08 | ≦ 0.60 / 0.10 / 0.35 |
| 本文の先頭削除の書き込み | – | 出力 + 14〜16 KB | ≦ 出力 + 16 MB |

- 1 byte × 100,000 の各操作: 圧縮 tar の `total` は同じ実行の非圧縮 tar の同じ操作に対して −305〜+313 ms（条件 ≦ +700）。
- 1 byte × 500,000 の tar.gz: 非圧縮 tar より速い（最大 −1,686 ms）。書き込みは出力 + 5〜526 KB（条件 ≦ 出力 + 16 MB）。
- stage: 圧縮 tar の即時・保存の 51 行すべてで `rewriter_open`・`reload_open` が無く、`reader_adoption` がある。
- open（`document_ready` まで、100k）: tar.gz 1.02 倍（≦ 1.13）、tar.xz 0.84、tar 1.01（≦ 1.05）、7z 0.94・lha 1.00（± 10 %）。zip は 1.16 倍だが、
  1 回だけの計測で 500k の open は 0.99 倍、他の zip の行は 0.99〜1.07 倍なので揺らぎと判断した。
- **未達**: tar.bz2 の 100k の open は 0.93 倍で、見込み（≦ 0.7 倍）に届かない（1 byte の member の書庫は bzip2 の復号が小さく、解析と木の構築が支配するため、
  K4 の並列の復号の効果が小さい）。本文の fixture の open の行（≦ 0.5 倍）は、B-P3 の probe にこの行が無いため比べられない。
- 未計測: 従来の設定（追加は先頭）での圧縮 tar の ±10 % の行と、連続 10 編集の報告の行。
- ログ: scratchpad `bp3/probe-{100k,500k}-r2.log`、`bp16/probe-{100k,500k}.log`、比較 `bp16/cmp-{100k,500k}.txt`。
