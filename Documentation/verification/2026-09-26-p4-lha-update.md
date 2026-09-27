# P4-A（S21）LHA の raw member 編集 — 2026-09-26

P4-A の実装と sandbox 内の検証を完了した。未 commit。
通常の Xcode test host での全件・実 volume・GUI・AC-A10 の受入計測はオーケストレータの実行待ち。
`build-for-testing` の成功や全件合格を、この記録で主張するものではない。

## 基底と隔離

- KaitoFinder: `feature/2026-09-24-review`、開始時 HEAD `aed29b6`（実装基底 `7b623b4` と文書 commit）。
- GyoshukuKit: `6e7cd9b53ebbf2cc9a288216bbddef02f71c2917`（P4-G-b）。
- KaitoKit: `0cbd809592cad139ea430dd75cc15af37f8ca2c1`（P4-K / P5-K）。
- 仕様: `SP/specs/final-p45/P4.md` の P4-A、`ORDER-P4-P5.md` §2–§3、
  `SP/specs/final-p613/ORDER-P6-P13.md` §1-3 の並列数の修正。
- SP: `$SP`。

次の三つ組を作り、編集中の live sibling はビルドに使わなかった。兄弟リポジトリは変更していない。

```sh
mkdir -p /private/tmp/kaitofinder-p4a-s21/{KaitoFinder,GyoshukuKit,KaitoKit}
git -C ../GyoshukuKit archive 6e7cd9b | tar -xf - -C /private/tmp/kaitofinder-p4a-s21/GyoshukuKit
git -C ../KaitoKit archive 0cbd809 | tar -xf - -C /private/tmp/kaitofinder-p4a-s21/KaitoKit
git archive HEAD | tar -xf - -C /private/tmp/kaitofinder-p4a-s21/KaitoFinder
```

ビルド前に KaitoFinder / KaitoFinderTests の作業ソースをこの KaitoFinder へコピーした。
依存の `Sources` は Git blob と照合し、GK 56 / KK 215 ファイルが固定 commit と一致した。
[出自と静的検査](../../build/P4AS21Verification/source-checks.json)。

## 実装

- 単一 LHA の capability を `.update(.lha)` にし、従来の `ArchiveRewriter.probe(reader:format:)` の門番を維持。
  `lhaRewriteReason` は init の既定 nil の stored property で、既存の即時 / 保存時の再圧縮注意書きにだけ使う。
- publish に `LHAUpdater.open(url:output:options:)` の枝を追加。作業ファイルは `archive.lzh`。
  `requiresRewrite` は open だけで捕まえ、同じ publish の中で mutate 前に rewriter へ切り替える。
  `willOpenUpdater` は一回、mutate / replay も一回。自己照合の失敗は既存の updater 診断を持つ
  `ArchivePublicationError.verificationFailed` へ写す。
- commit の1000単位は LHA の publish の枝でだけ追加し、既存の `ArchiveReencryptionProgress` で写す。
  LHA の rewriter 経路では、削除済みの項目を carry の予算から除くため、解決後の projection の生存項目数を使う。
  従来の `entryNames.count` は削除済みも含み、AC-A4 の完了値と総数が一致しなかったため。
  tar / ZIP / 7z の予算は変更していない。
- `ArchiveOutputProjection.validateMode()` で `.update(.lha)` を許可。
  既存の `.update` の格納順・種類・既知サイズの一走査照合と、fallback 後の `.rewrite` への再解決を使う。
- direct probe の LHA は updater で開く。既存の `KAITOFINDER_PROBE_ADDITION_PLACEMENT` を使い、
  `end` で `updater_open`、`beginning` で `rewriter_open` を要求し、逆の段と `work_copy` を禁止する。
  即時 / 保存 / direct の全てが共通の `editorStage` / `requireRoute` を通る。

P3-A の三形式条件は実装済みだった。`ArchiveSession.append` / `createFolder` / `edit` / `savePending` の
`sessionReader` は `.tarGzip` / `.tarBzip2` / `.tarXZ` のみで、LHA では nil。
LHA 用に `reader.reopen()` を増やしていない。`rewriteBranch(format:)` 内に `willOpenUpdater` はなく、
`.rewrite` case と updater case が一回ずつ呼ぶ既存の配置を維持した。
`editNotice` と publish の圧縮 tar の条件も三形式のまま。

`ArchivePreferences.writerOptions(for:)` は変更していない。
LHA の `additionPlacement` と P9 の `compressionThreads`（0 以外）をともに保つ。
新しい defaults key / 文言はない。`TestProcessSetup.autosaveKeys` / `AutosaveIsolationTests` の変更は不要で、
既存の並列数・追加位置の隔離キーを確認した。製品は `LHARawLayout` SPI を import しない。
新しい `@unchecked Sendable` / `nonisolated(unsafe)` はない。
`git diff --check` は成功。最終的な246個のアプリ / テスト Swift ソースがビルド用コピーと byte 一致することも照合した。

基底の P1d は A0 の計測までで、A1–A6 / S33 は未実装。
そのため保存 probe の既存の `plan_keys` / `validate_representability` / `representability_probe` の要件は維持した。
S33 後を前提とする `ORDER-P6-P13` §1-4 の差分検査は、この P4-A に混ぜていない。

## 試験の追加と変更

新規の五クラスと共通 helper:

| 試験 | 確認すること |
|---|---|
| `LHAUpdateEditTests` | GK 製と tl-S3b の9操作ずつ。削除（途中 / 末尾）、同長 / 異長 header 改名、フォルダ改名、移動、追加、新規フォルダ、置換。commit strategy、作業ファイル一つ、rename 前の inode / byte / mtime、運ぶ header / payload（level 0 lh6 を含む）、内容、`.adopted`、mode / quarantine / xattr / 作成日時。全削除後の追加（即時 / 保存時）、混在 CP932 の追加 / 改名 |
| `LHAUpdateDeferredSaveTests` | 五操作と改名だけの保存（GK / 混在）、予約表示と保存後の順序、フォルダの予約日時。分割 LHA の即時 / 保存時が rewriter のままであること（Foundation の調停だけ制御し、実の producer / 検証 / 公開を通す） |
| `LHAUpdateFallbackTests` | SFX、EUC-JP、宣言なし / 宣言あり UTF-8、tl-S5、tl-S11、level 3、anonymous、空名 directory 終端、data 付き directory、LHArk の注意書きと即時 / 保存時の削除。open / fallback / mutate の一回性、進捗完了、UTF-8 の二回目が updater、先頭追加と開いたままの設定変更 |
| `LHAUpdateVerificationFailureTests` | 出力 member の入替え、updater 自己照合 error、mutate / commit からの requiresRewrite の再実行禁止、取消し、0 byte 進捗、root directory / サイズ / 種類 / 順序の projection |
| `LHAUpdateNonAPFSTests` | HFS+ / ExFAT と APFS の項目・内容の比較、削除 / 追加 / 同長改名 / 保存。clone 無効時も同じ4操作が `.sequential` |

Step 0 の base64 14件と門番用の最小 fixture 3件をリポジトリに置いた。
[出自と復号後の SHA-256](../../KaitoFinderTests/Fixtures/LHAUpdate/LHAUpdateFixtures-README.md)。
GK の試験 builder や LHARawLayout SPI を使わず、公開 metadata の offset で header / payload の一致を検査する。

変更した既存試験 / helper の一覧:

1. `ArchiveRewriteTests`: `testLHACapabilityUsesUpdateMode` へ改名。共通 capability / rewriteNotice / commit 進捗 / undo 後の mode の
   LHA の期待を updater に変更。先頭設定の解決と二つの注意書きを確かめる試験を追加。
   `testLHADocumentEditsAndUndoRestoreOriginalSHA256` の本体と undo の SHA-256 assertion は変更していない。
2. `ScenarioShapeTests`: CP932 append を updater の期待へ変更し、先頭設定で同じ名前・内容を確かめる試験を残した。
3. `ArchiveCapabilityInspectionTests`: `.lzh` / `.lha` / 大文字 / 拡張子なし、GK / ASCII / 混在、分割の rewrite、
   先頭設定、symlink / CP932 不可名 / `:` の従来の拒否を追加。
4. `TarUpdateProjectionTests`: 未実装 updater の拒否一覧から LHA を外した。LHA の照合 assertion は新規 verification suite に置いた。
5. `EditPlacementPreferencesTests`: probe の設定と経路の行列に LHA を追加。
6. `PerformanceProbeTests` / `Support/ArchivePerformanceProbe`: LHA direct open と経路要件を updater に変更。

全テストソースで LHA / lzh を検索し、上記以外の単一ファイルの mode / notice / 進捗期待も確認した。
[全 LHA 参照](../../build/P4AS21Verification/lha-test-audit.txt)・[mode / notice 検索](../../build/P4AS21Verification/mode-notice-audit.txt)。
直接 `.rewrite` を指定して rewriter 自体を試す試験、分割の期待は変更していない。
`ArchiveImportCorrectionTests.swift` は HEAD と byte 一致のまま7試験が通った。

## 実行したビルド

以下の Xcode コマンドを隔離側で2回実行した（初回、最終ソースのコピー後）。
両方 exit 74 で、package resolution 時に sandbox 外のキャッシュ書込みが拒否され、アプリの compile に到達しなかった。

```sh
cd /private/tmp/kaitofinder-p4a-s21/KaitoFinder
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/kaitofinder-p4a-s21/dd build-for-testing
```

拒否先は `~/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule` と
`~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/gyoshukukit.dia`。
[初回ログ](../../build/P4AS21Verification/xcode-build-for-testing-initial.log)・
[最終ログ](../../build/P4AS21Verification/xcode-build-for-testing-final.log)。

代わりに実行した直接ビルド:

```sh
python3 build/P4AS21Verification/build.py KaitoKit GyoshukuKit
python3 build/P4AS21Verification/build.py app test
python3 build/P4AS21Verification/build.py test
python3 build/P4AS21Verification/package-resources.py
```

テストの修正後は `build.py test` と resource packaging を繰り返した。
`swiftc` は Xcode 27 の `arm64-apple-macos26.0` / Swift 6、アプリとテストは MainActor default isolation、
`NonisolatedNonsendingByDefault` / `InferIsolatedConformances`、DEBUG / enable-testing を使用。
compiler macro launcher には既存 harness と同じ `-disable-sandbox` を指定。実際の依存をビルドしており、スタブは使っていない。
既存の Sparkle framework をリンクし、26言語の catalog と `.strings` を直接テスト用 framework に格納した。

- KK 206 / GK 54 / アプリ101 / テスト145の Swift ソースの compile / link は成功。
- DEBUG を定義しない全アプリソースの `swiftc -typecheck` も成功。
- アプリの新規 warning は0。依存の既存3 warning、既存テストの4 warning は残る。
- 初回のテスト compile では新規 deferred suite の Testing SPI import 不足を修正した。
- 最初の edit matrix 実行は、混在 fixture の同長改名用に選んだ header が GK の最小 header より短く、
  テストの文字数計算で abort した。対象を同長改名可能な level 2 member に直し、負値を作れない guard を加えて再実行し、全18操作が通った。

[ビルドスクリプト](../../build/P4AS21Verification/build.py)・
[アプリの正確な引数](../../build/P4AS21Verification/app-command.json)・
[テストの正確な引数](../../build/P4AS21Verification/test-command.json)・
[最終テスト compile ログ](../../build/P4AS21Verification/test-build.log)・
[Release 型検査の引数](../../build/P4AS21Verification/release-typecheck-command.json)・
[Release 型検査ログ](../../build/P4AS21Verification/release-typecheck.log)。

## 実行した試験と限界

直接 XCTest runner で、選択ごとに別 process、`TZ=Asia/Tokyo` で実行した。
[全実行の selector・コマンド・exit・case・ログ](../../build/P4AS21Verification/test-results.json)を保存している。
同じ case の再実行を重複計上しない最終結果は、**207成功、8 skip、3失敗、3中断**。
失敗 / 中断は下記の direct runner / sandbox の制約で、全件合格という意味ではない。

基本のコマンドは次の形。各 selector の実引数は上記 JSON に全て記録した。

```sh
python3 build/P4AS21Verification/run-tests.py <class-or-class/testMethod> ...
# runner が実行する形:
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest KaitoFinderTests.<selector> build/P4AS21Verification/P4AS21Tests.xctest
```

| 選択（class 内の一部だけの実行を含む） | 成功 | skip | 失敗 | 中断 |
|---|---:|---:|---:|---:|
| `ArchiveCapabilityInspectionTests` | 12 | 1 | 0 | 0 |
| `ArchiveImportCorrectionTests` | 7 | 0 | 0 | 0 |
| `ArchiveReaderAdoptionTests` | 12 | 2 | 0 | 0 |
| `ArchiveRewriteTests` | 35 | 0 | 0 | 0 |
| `ArchiveSplitVolumeTests` | 16 | 0 | 0 | 0 |
| `AutosaveIsolationTests` | 2 | 0 | 0 | 0 |
| `CompressedTarRoutingTests` | 3 | 0 | 0 | 0 |
| `CompressedTarSplitRegressionTests` | 1 | 0 | 0 | 0 |
| `CompressionThreadPreferenceTests` | 6 | 0 | 0 | 0 |
| `DeferredSaveAttributeTests` | 5 | 0 | 0 | 1 |
| `DeferredSaveCorrectionTests` | 6 | 0 | 0 | 1 |
| `DeferredSaveDocumentTests` | 17 | 0 | 0 | 1 |
| `DeferredSplitSaveTests` | 3 | 0 | 0 | 0 |
| `EditPlacementPreferencesTests` | 5 | 0 | 0 | 0 |
| `LHAUpdateDeferredSaveTests` | 2 | 0 | 0 | 0 |
| `LHAUpdateEditTests` | 3 | 0 | 0 | 0 |
| `LHAUpdateFallbackTests` | 4 | 0 | 0 | 0 |
| `LHAUpdateNonAPFSTests` | 1 | 2 | 0 | 0 |
| `LHAUpdateVerificationFailureTests` | 4 | 0 | 0 | 0 |
| `ScenarioShapeTests` | 7 | 0 | 0 | 0 |
| `TarUpdateEditTests` | 9 | 3 | 0 | 0 |
| `TarUpdateProjectionTests` | 3 | 0 | 0 | 0 |
| `WordingAcceptanceTests` | 44 | 0 | 3 | 0 |

全ての実行を記録した JSON のほか、case ごとの最後の状態は [最終集計](../../build/P4AS21Verification/final-summary.json)を参照。

skip の内訳は、`hdiutil create` が「装置が構成されていません」で失敗した7件
（LHA 2、reader adoption 2、tar 3）と、opt-in していない100k open 計測1件。
`VolumePublishTestDisk` は起動失敗 / 非0終了を既に `XCTSkip` にしており、変更していない。
clone 無効の LHA 4操作は実行して成功したが、実 HFS+ / ExFAT の代用として合格扱いにはしない。

通常 host で再実行するもの:

- `WordingAcceptanceTests/testEnglishDevelopmentFallbackKeepsAllTwentySixLocalizations`:
  direct runner の `Bundle.main` が xctest で、アプリの26言語を持たない。
- `WordingAcceptanceTests/testJapaneseMenuCorrectionsAndNamedProgressTitle` と
  `testStandardMenusHaveLocalizedTitlesActionsShortcutsAndApplicationBindings`:
  `RecentDocumentsMenu` nib を `Bundle.main`（Xcode の `usr/bin`）から読めず失敗。
- `DeferredSaveAttributeTests/testDeferredTarPreservesSourceOwnerIDsThroughSaveAndSaveAs`、
  `DeferredSaveDocumentTests/testDeferredSaveAsCallerCancellationReachesUnstructuredTask`、
  `DeferredSaveCorrectionTests/testFinderMoveFollowsPresentedURLForSaveAndSaveAs`:
  XPC の `ClientCallsAuxiliary` / `HostCallsAuxiliary` が `Connection invalid` となり exit 69。
  これらは started だけで XCTest の完了結果がないため「中断」とした。
  各クラスの残りの sandbox 内で動く試験は個別 selector で実行した。

Wording の最初の実行では、direct framework の `ServicesMenu.strings` 不足でも1件失敗した。
現行の `.strings` を packaging し直した後、`testBuiltAppContainsAllTwentySixLocalizationFoldersAndTranslatedResources` は成功した。
製品の resource / 文言や既存テストの assertion は、このために変更していない。

`xcodebuild test-without-building`、全件、実アプリの GUI 操作、性能 probe の opt-in、100k / 500k、
256 MiB、B-P4 比較、I/O / RSS / `sample` は実行していない。
P0b の TSV 列は変更せず、経路の knob / 要件は `EditPlacementPreferencesTests` と通常の LHA stage 試験で確認した。
試験時間を AC-A10 の受入計測の代わりには使っていない。

## AC と引継ぎ

| AC | この実行で確認した範囲 | 残り |
|---|---|---|
| A1 | spellings、構造の注意書き、従来の拒否、分割、LHA 専用経路。圧縮 tar / sessionReader の四か所を静的照合 | 通常 host の全件 |
| A2 | GK / 混在の18操作、strategy / raw byte / attributes / P1-A adoption、全削除からの追加 | 実 volume |
| A3 | GK / 混在、五操作 / 改名のみ、格納順、予約日時 | 通常 host の全件 |
| A4 | 11構造 × 即時 / 保存時、fallback / open / mutate 一回、進捗、R10 の二回目、先頭設定 | 通常 host の全件 |
| A5 | member の順序違いと自己照合 error の拒否、原本不変、編集可能性維持 | なし |
| A6 | 宣言なし CP932 + 932宣言 + ASCII、追加 / 改名後の表示名・raw byte | なし |
| A7 | 強制 sequential の削除 / 追加 / 同長改名 / 保存、APFS と同じ項目・内容 | HFS+ / ExFAT の実行 |
| A8 | mode / notice / 進捗期待の全検索、先頭設定の試験、既存 LHA undo / import correction | 通常 host の全件 |
| A9 | 直接ビルド・全テスト compile・Release 型検査・選択試験 | build-for-testing、hosted 全件、上記の失敗 / 中断 |
| A10 | probe の LHA updater 経路と旧設定の反転を実装 | オーケストレータの B-P4 比較。閾値は変更していない |

オーケストレータは同じ固定 commit の三つ組で `build-for-testing`、P4-A の選択試験一覧、全件を実行する。
性能は P4.md の AC-A10 と ORDER45 §6.1 のとおり、`-O` / wholemodule Debug、100k、payload 256 MiB、全形式、
LHA `beginning` の行を採る。負荷平均4未満、開始 / 終了の `uptime`、最初の1回を捨てる条件を守る。
B-P4 は採取済みの基準を使い、S21 の計測を B-P5 にも使う。LHA の stage は通常 `updater_open` のみ、
fallback は updater / rewriter を一回ずつ、先頭設定は rewriter のみ。

## 既存の制限

- tl-S11: KaitoKit が level 2 header 長の下位 byte 0 を終端と見なす既存の挙動は変更していない。
  fallback の rewriter は KaitoKit に見えない後続 member を落とす。
  この fixture の検査対象は経路の切替えと KaitoKit に見える内容だけ。
- `.lha` / `.lzh` の拡張子がない書庫を全削除すると出力は `[0]` の1 byte。
  `archive.lzh` の作業名で公開前検証はできるが、公開後の名前では LHA と判定できない。
  従来の rewriter と同じ制限であり、これを拡張子推測で変えていない。
- LHArk の凍結 fixture の payload は復号不能。fallback 試験ではその member を削除して経路を確認した。
- 分割 LHA、別名保存、読み取り専用の範囲は変更していない。

## S21 correction 1 — test bundle の resource 名の衝突

オーケストレータの通常 host / 固定三つ組（KK `0cbd809`、GK `6e7cd9b`）での
`xcodebuild build-for-testing` は、test bundle の `Resources/README.md` に対する
`Multiple commands produce` で失敗した。同期 folder group が resource を平らにコピーするため、
追加した `Fixtures/LHAUpdate/README.md` が既存の `Fixtures/TarEdit/README.md` と衝突していた。

LHA 側だけを `LHAUpdateFixtures-README.md` へ改名し、この記録のリンクを更新した。
改名前後の SHA-256 を比較し、内容が同じであることを確認した。Swift と fixture の byte は変更していない。

この修正で実行した確認:

- `git status --short`、`git diff --name-status -- KaitoFinderTests`、
  `git ls-files --others --exclude-standard -- KaitoFinderTests` と `rg` による project / 参照の確認。
- Python で `git diff --name-only --diff-filter=A HEAD -- KaitoFinderTests` と
  `git ls-files --others --exclude-standard -- KaitoFinderTests` の和集合を列挙。
  追加した全24ファイル（resource 18件 = README 1件 + base64 17件、Swift 6件）を、
  `KaitoFinderTests` 以下の全ファイルに対して basename で照合した。
  Unicode NFC 正規化と大文字小文字を区別しない比較でも、改名後の衝突は0件。
  [全24ファイルの監査結果](../../build/P4AS21Verification/correction-1/resource-name-audit.json)。
- `rg -n 'Fixtures/LHAUpdate/README\.md' --glob '!build/**' .` で、
  修正説明に残した旧パス以外の参照がないことを確認。
- `git diff --check` は成功。追加 README と検証記録の行末空白も Python で確認した。

この correction では Xcode build / Swift compile / XCTest を再実行していない。
前節の207成功等は修正前の機能検証結果のまま。通常 host の `build-for-testing` の再実行は
オーケストレータに残る。兄弟リポジトリへの変更と commit は行っていない。

## release notes に書く既定の変更

LHA の編集では、触らない member の header と圧縮済みデータを byte のまま運ぶ。
追加は既定で末尾に置き、改名した member は level 2 の header になる。
「先頭へ追加」の設定では従来どおり全体を書き直す。

非 ASCII の名前を持ち、書庫全体の文字コードが推定されない書庫は、最初の編集で全体を CP932 の名前へ書き直す。
その後は raw member 編集を使う。再圧縮が必要な場合は既存の注意書きを表示する。

公開済みの `Documentation/releases/` は変更せず、release-note 文面はこの節にだけ記録した。

## オーケストレータの検証（2026-09-26）

隔離した三つ組（KaitoKit 0cbd809、GyoshukuKit 6e7cd9b は `git archive`、KaitoFinder は作業ツリーの rsync）。

| 実行 | 結果 |
|---|---|
| 最初の build-for-testing | 失敗: 新しい fixture の `KaitoFinderTests/Fixtures/LHAUpdate/README.md` が試験バンドルの既存の `README.md` と同じ出力先になり衝突（Codex の sandbox では xcodebuild が動かない）。correction 1 で名前を変えた |
| correction 1 の後の build-for-testing | 成功 |
| LHA の試験群（LHAUpdate* の 5 クラスと関連の 7 クラス） | 94 件、失敗 0、skip 1（HFS+ / FAT の実 image を含む） |
| 全件 | 1,551 件。失敗は既知の環境依存の GUI 系 8 試験（ArchiveConflictUITests 1、ArchiveDropIntegrationTests 5、ArchivePreviewSidebarTests 1、ArchiveTabTests 1）だけ |

受入計測（AC-A10、P0b を B-P4 と比べる）は、この節の後に追記する。

## 受入計測（AC-A10、2026-09-26 14:30–15:20、オーケストレータ）

B-P4 = KaitoKit d35f2da・GyoshukuKit a03833e・KaitoFinder 7b623b4、S21 = KaitoKit d171f27・GyoshukuKit 6e7cd9b・
KaitoFinder ac5cab9。どちらも `git archive` の隔離した三つ組を `-O`・wholemodule の Debug で build し、
`PerformanceProbeTests` の 3 試験（編集・直接の編集・open）を 100k 件と本文 256 MiB で交互に流した。
3 試験とも全回で成功。負荷の平均は 6.1〜18.3 で、仕様の「4 未満」は満たせていない（Codex の試験と並走）。

| 回 | 内容 | 負荷（開始 → 終了） |
|---|---|---|
| 1 | B-P4 全形式 → S21 全形式（追加は末尾） | 18.25 → 6.78、6.78 → 9.64 |
| 2 | S21 → B-P4、LHA だけ、`KAITOFINDER_PROBE_ADDITION_PLACEMENT=beginning` | 6.11 → 13.27、13.27 → 6.67 |
| 3 | B-P4 → S21、7z・tar・tar.xz（回 1 で ±10 % を外れた行の測り直し） | 6.67 → 7.10、7.10 → 9.67 |

比較の全行: [回 1](data/2026-09-26/p4-bp4-vs-s21-100k.txt)、[回 2](data/2026-09-26/p4-bp4-vs-s21-lha-beginning.txt)、
[回 3](data/2026-09-26/p4-bp4-vs-s21-recheck.txt)（`format fixture mode operation stage 基準 新 比`）。

### LHA の行（回 1）

| 行 | 合格条件 | 結果 | 判定 |
|---|---|---|---|
| entries の `updater_open` | ≦ B-P4 の `rewriter_open` × 1.25 | 889–952 ms（基準の 1.09–1.16 倍） | 合格 |
| payload の `updater_open` | ≦ B-P4 の `rewriter_open` + 10 | immediate・deferred 24.0–25.2 ms（基準 9.6–10.3 + 10 = 19.6–20.3）、direct 24.7・25.0 ms（基準 23.5・25.3 + 10） | **immediate・deferred は約 5 ms 超過** |
| entries immediate の delete_end・rename_same_length・add_file・new_folder の `commit` | ≦ 50 | 3.9・3.9・3.9・4.0 | 合格 |
| entries immediate の delete_start・rename_different_length・rename_folder・replace_file の `commit` | ≦ 250 | 10.6・15.9・10.3・7.7 | 合格 |
| entries deferred の `commit` | ≦ 300 | save_five_changes 9.8、save_rename_only 7.1 | 合格 |
| payload immediate の delete_end・rename_same_length・add_file・new_folder の `commit` | ≦ 60 | 1.3・1.1・0.7・0.7 | 合格 |
| payload immediate の delete_start・replace_file・rename_different_length の `commit` | ≦ 800 | 86.9・74.7・77.0 | 合格 |
| payload の rename_folder、deferred save_five_changes の `commit` | ≦ 900 | 79.4・1.0 | 合格 |
| entries immediate の編集の `total` | ≦ B-P4 × 0.7 | 0.59–0.62 倍（例: delete_end 3,344 → 1,986 ms） | 合格 |
| payload immediate の delete_end・rename_same_length・add_file・new_folder の `total` | ≦ 200 | 54.8・57.5・56.1・57.2 | 合格 |
| payload の他の immediate と deferred の `total` | ≦ 1,100 | 118.8–182.4 | 合格 |
| entries の `verification_open`・`entry_comparison`・`capability_probe` | ≦ B-P4 + 10 % | 0.98–1.03 倍、0.78–0.93 倍、0.98–1.03 倍 | 合格 |
| `written_bytes` payload immediate delete_start / delete_end | ≦ 出力 + 16 MB / ≦ 4 MB | 168,587,264 B（出力 168,563,277 B）/ 28,672 B（基準は 338 MB / 342 MB） | 合格 |
| stage の有無 | `updater_open` があり、`rewriter_open`・`work_copy`・`reload_open` が無い | そのとおり（LHA の行に `rewriter_open` 0 件） | 合格 |
| 従来の設定（先頭へ追加）の LHA の `total`（回 2） | B-P4 ± 10 % | 0.98–1.07 倍。stage は `rewriter_open` だけ | 合格 |
| entries immediate open の `total` | （± 10 % として扱った） | 1,138 → 1,199 ms（1.05 倍） | 合格 |

payload の `updater_open` の超過について: direct の行では updater（24.7・25.0 ms）と rewriter（23.5・25.3 ms）の費用は同じで、
immediate・deferred の `rewriter_open` だけが約 10 ms に下がっている。基準の rewriter は文書の session が
開いた後で同じ書庫を開くので、その差を updater は取れていない（1,064 件の header をもう一度たどる）。
超過は約 5 ms で、同じ行の `total` は 3,066–3,135 ms から 54.8–182.4 ms（0.02–0.05 倍）になっている。
閾値は変えず、仕様からの逸脱として最終報告に挙げる。

### 他の形式の `total`（B-P4 ± 10 %）

- 回 1: 予約の行（`five_changes_reserve_*`・`rename_only_reserve_*`。数 ms〜数十 ms の値が上下どちらにも揺れる。
  P2・P3 の計測と同じくノイズとして除いた）を除く 100k の行のうち、±10 % を外れたのは遅い側が 4 行
  （7z entries direct delete_end 1.11、7z payload open 1.16、tar payload deferred save_five_changes 1.71、tar.xz payload
  replace_file 1.13）と、速い側が数行。
- 回 3 で 7z・tar・tar.xz を測り直すと、その 4 行のうち 3 行は範囲に入った（0.98、1.05、1.07）一方で、回 1 では範囲内だった
  7z payload の direct / immediate の再圧縮の行（10.8–12.7 s）が 1.13–1.17 倍になった。同じ build の 2 回の間でも
  7z payload direct delete_start は B-P4 で 12,823 / 10,755 ms、tar.xz payload replace_file は 2,730 / 3,340 ms と揺れ、
  負荷 6〜18 の中では再圧縮の行の揺れが ±10 % を越える。
- 各 build で 2 回の小さい方を採ると、7z・tar・tar.xz の 78 行の幾何平均は 1.029、外れるのは 5 行
  （7z payload direct delete_end / delete_start 1.13、tar payload deferred save_five_changes 1.21、tar.xz payload direct delete_end 1.10、
  tar.xz payload immediate replace_file 1.13）。zip・tar.gz・tar.bz2 の 78 行は幾何平均 0.964、外れるのは速い側の 4 行だけ。
- S21 はこれらの形式の経路を変えていない。GyoshukuKit の B-P4 → S21 の差は LHA の追加と、`TarUpdaterError` を
  `UpdaterRouteError` の型別名にしたことだけ（`TarUpdater.swift` はそれと `mode(for:)` の可視性の 2 か所）。
  tar payload deferred save_five_changes の増加（54–55 → 66–95 ms）は `save_sheet` の中の名前の付いていない残り
  （22–23 → 33–42 ms）で、名前の付いた段（`updater_open` 15–16 ms（1 回だけ 33 ms）、`verification_open` 7.5–7.9 ms など）は同じ。
  tar.gz・zip の同じ保存の行は S21 の方が速いか範囲内なので、保存の経路に共通の後退は無いと判断した。
- 静かな機械（負荷 < 4）での採り直しはしていない。最終報告に、負荷の条件を満たしていないことと上の 5 行を挙げる。
