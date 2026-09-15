# Wave D・26言語対応の検証 — 2026-09-15

## 結果

全 292 キーへ 16 言語・4,672 訳を追加し、合計 **26 言語・7,592 訳**とした。
既存 10 言語の **2,920 訳、キー、エントリのメタデータは変更なし**。
新規 16 言語の Finder Services（圧縮・展開）と `knownRegions` を追加した。

補助 XCTest は **59 件成功、1 件が実行ホストの制約で失敗、1 件が OS サービス接続で中断**。
完了した描画監査では **26 言語 × 51 画面 = 1,326 PNG、はみ出し 0 件**。
標準の `xcodebuild build` / `test` は、どちらも sandbox 内の依存解決で **終了コード 74**。
以上は sandbox 内の検証結果であり、本番アプリのフルビルド・全件テストが成功したという結果ではない。
ユーザーのシェルでの結果は、後述の[オーケストレータによる全件検証](#オーケストレータによる全件検証)を参照。

KaitoKit / GyoshukuKit のパッケージ、既存の Services 訳、Xcode のビルド設定や scheme は変更していない。
プロジェクトファイルの変更は `knownRegions` の 16 コード追加のみ。コミットは作成していない。
`inbox/` と git-ignored ファイルには編集・移動・削除を行っていない。

## オーケストレータによる全件検証

2026-09-15 に、オーケストレータがユーザーのシェルで Wave D 適用後の検証を行った。
全件テストは `xcodebuild test -scheme KaitoFinder -destination 'platform=macOS'` で実行した。

- **1 回目: 598 件・失敗 1**。`ArchiveBatchExtractionTests.testIncorrectRememberedPasswordFallsBackToPrompt` が失敗した。
- **2 回目: 598 件・失敗 0**。QuickLook の前面化テストのみアクティベーションのタイミングでスキップされ、その他のスキップは **0 件**。

`xcodebuild -configuration Release build` は成功し、生成したアプリのバンドルに **26 個の `.lproj`** を確認した。
Release 実機のアプリで lldb smoke を行い、`th` / `ru` / `pt-PT` のメニューが
それぞれ「ไฟล์」「Файл」「Ficheiro」と表示されることと、`nl` → `en` のフォールバックを確認した。

### 1 回目の失敗原因と KaitoKit の修正

原因は実行順序への依存ではなく、KaitoKit の ZipCrypto 読み取り時のパスワード判定だった。
1 バイトのヘッダーチェックだけで判定していたため、誤ったパスワードでも **1/256** の確率で通過した。
その後の CRC / デコーダーの失敗が `wrongPassword` ではなく `checksumMismatch` / `malformed` として返され、
`ArchivePasswordChallenge` が `.incorrect` にならず、一括展開はパスワード入力を求めずに失敗を記録した。

ヘッダーチェックが衝突するパスワードで確実に再現した。
`kaito sha secret.zip -p wrong-113` は「Checksum mismatch」、`unzip` は
「(may instead be incorrect password)」、7-Zip は「Wrong password?」を表示した。

KaitoKit PR #27 としてマージ済み（`862b32d`、2026-09-15）。
完全な ZipCrypto エントリでは、7zAES / RAR4 と同様にこれらのエラーを `wrongPassword` へ正規化し、
衝突を確実に再現するテストを追加した。WinZip AES の扱いは変更していない。
KaitoFinder はローカルパス `../KaitoKit` に依存しているため、KaitoFinder 側のコード変更は不要。

## 言語と用語

追加言語は `th`、`vi`、`id`、`ms`、`hi`、`ru`、`nl`、`pl`、`tr`、`sv`、`da`、`nb`、`fi`、`uk`、`cs`、`pt-PT`。
既存の `en`、`ja`、`de`、`fr`、`es`、`it`、`pt-BR`、`zh-Hans`、`zh-Hant`、`ko` は維持した。

- 提供された Apple 用語集 `tier1-glossary.json` を利用した。Archive Utility の展開・パスワード入力・
  保存先の表現、AppKit の標準コマンド、Finder の用語を基準にした。
- 用語集の `no` は `nb`、`pt_PT` は `pt-PT` に対応付けた。
- 単独の `Archive` が動詞である箇所は、名詞としての「アーカイブ」と区別した。
  用語集にない Save As は実機の AppKit `Document.loctable`、Compress と Date Modified は
  Finder の言語別 `.strings` で補った。Finder の `MenuBar.strings` で uk の Undo / Redo と
  cs の Redo を確認し、用語集の英語フォールバックを表示に残さなかった。
- 名前の引用符は ru / uk / nb `«%@»`、pl `„%@”`、cs `„%@“`、sv / fi `”%@”`、
  nl `'%@'`、それ以外の追加言語 `“%@”`。コマンドの省略記号は空白なしの `…`。
- タイ語は文末の句点なし、ヒンディー語は `।`、pt-PT は `palavra‑passe` の改行しないハイフン。
  `ArchiveAlertText` に `।` の認識を追加し、既に句点のある説明を整形しても重複しないようにした。
- Apple のウェルカム文字列に含まれる内部の活用指定や特殊な書式マーカーは除き、表示用の文にした。

## 変更ファイル

| ファイル | 変更 |
|---|---|
| `KaitoFinder/Resources/Localizable.xcstrings` | 全 292 キーに 16 言語追加 |
| `KaitoFinder/Resources/{th,vi,id,ms,hi,ru,nl,pl,tr,sv,da,nb,fi,uk,cs,pt-PT}.lproj/ServicesMenu.strings` | 新規 16 ファイル、各 2 項目 |
| `KaitoFinder.xcodeproj/project.pbxproj` | `knownRegions` のみ追加 |
| `KaitoFinder/UI/ArchiveAlertText.swift` | ヒンディー語の句点重複を防止 |
| `KaitoFinderTests/WordingAcceptanceTests.swift` | 共通一覧を 26 言語へ拡張、16 文体テスト、句読点回帰テスト、件数・Services・バンドル照合を更新 |
| `KaitoFinderTests/LayoutOverflowTests.swift` | 警告・ロック画面・ステータスバーを含む全監査の言語一覧を 26 言語へ統一 |
| `KaitoFinderTests/ArchivePreferencesUITests.swift` | 設定の固定期待値を 26 言語へ拡張、テスト名を更新 |
| `KaitoFinderTests/ArchiveErrorTextTests.swift` | 26 言語を表すテスト名へ更新 |
| `KaitoFinderTests/ArchivePasswordTests.swift` | 同上 |
| `KaitoFinderTests/ScenarioNestedTests.swift` | 同上 |
| `Documentation/design.md` | 対応言語 §5.4、現行言語数、M9 の Wave D を追記 |
| `Documentation/manual-verification.md` | §8.1 の 26 言語一覧・切替・文体・フォールバック、関連確認手順を更新 |
| `Documentation/verification/2026-09-15-languages.md` | この日本語レポート |

## 自動検証

### 1. 標準の Xcode コマンド

```sh
xcodebuild -scheme KaitoFinder -destination 'platform=macOS' build
xcodebuild -scheme KaitoFinder -destination 'platform=macOS' test \
  -only-testing:KaitoFinderTests/WordingAcceptanceTests \
  -only-testing:KaitoFinderTests/LayoutOverflowTests
```

両方とも **終了コード 74**。ログの主要部分は以下。

```text
xcodebuild: error: Could not resolve package dependencies:
error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output:
  /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia'
  for diagnostics emission (Operation not permitted)
```

GyoshukuKit の manifest 診断ファイルにも同じ拒否が出た。回避のためのプロジェクト設定変更は行っていない。
ログは `/private/tmp/kf-wave-d-build.log`、`/private/tmp/kf-wave-d-test.log`。

### 2. 一時領域でのコンパイル

`/private/tmp/kf-wave-d-verification/` に補助 framework と XCTest バンドルを作成した。
既存のビルド済み KaitoKit オブジェクトと、読み取り専用で参照した GyoshukuKit ソースを使用した。
出力・モジュールキャッシュはすべて一時領域。アプリとテストは現在の git-tracked Swift ソースを対象に、
Swift 6、MainActor 既定、strict concurrency complete、NonisolatedNonsendingByDefault、macOS 26 でコンパイルした。

```text
dependency exit: 0
catalog exit: 0
app-link exit: 0
test-link exit: 0
runner exit: 0
```

カタログは `xcrun xcstringstool compile` でコンパイルした。26 言語の Services も補助 framework に格納し、
`testBuiltAppContainsAllTwentySixLocalizationFoldersAndTranslatedResources` で全訳との一致を確認した。
これは補助 framework のリソース確認であり、Xcode が生成する本番アプリのパッケージ確認は未完了。

### 3. 補助 XCTest の実測

`KAITOFINDER_SNAPSHOT_DIR=/private/tmp/kf-wave-d-verification/snapshots` を指定して、
`xcrun xctest -XCTest <テスト識別子> /private/tmp/kf-wave-d-verification/KaitoFinderTests.xctest` で実行した。
既存の `TestProcessSetup` を principal class として使用。試走による同一テストの重複は下表に加算していない。

| 対象 | 成功 | 失敗 | 中断・未完了 |
|---|---:|---:|---:|
| `WordingAcceptanceTests` | 35 | 1 | 0 |
| `LayoutOverflowTests` | 12 | 0 | 1 |
| `ArchivePasswordUITests/testVisibleSavePanelPasswordRowsAndAllThreeSheetsFitInEveryLanguage` | 1 | 0 | 0 |
| `ArchivePreferencesUITests/testExtractionSettingsUseArchiveUtilityLabelsInEveryLanguage` | 1 | 0 | 0 |
| `ArchiveErrorTextTests` | 10 | 0 | 0 |
| **合計** | **59** | **1** | **1** |

実際の出力:

```text
WordingAcceptanceTests:
Executed 36 tests, with 1 failure (0 unexpected)

設定・ようこそ・進捗・ステータスバー・保存アクセサリ／暗号化シート・設定用語:
Executed 6 tests, with 0 failures (0 unexpected)

ArchiveErrorTextTests:
Executed 10 tests, with 0 failures (0 unexpected)
```

`LayoutOverflowTests` の最初の 8 件は各 `Test Case ... passed` を確認した後、
保存パネル生成でプロセスが終了したため、その実行には suite 全体の完了集計がない。
残りの 4 件は上記の 6 件の実行に含めて完了した。

**失敗・中断の内容:**

- `testEnglishDevelopmentFallbackKeepsAllTwentySixLocalizations` の `Bundle.main.localizations` の確認が失敗。
  単独の `xctest` ホストは本番アプリの 26 言語リソースを持たない。`CFBundleDevelopmentRegion == en` の確認は成功。
  このテストは変更して制約を隠すことなく、本番アプリで再実行する対象として残した。
- `testSavePanelAccessoryInEveryLanguageAndFormat` は `NSSavePanel` 生成中に
  `ClientCallsAuxiliary` / `HostCallsAuxiliary` の XPC 接続が `Connection invalid` となり、終了コード **69**。
  実パネルを生成する経路は未検証。OS のパネルを生成せず同じ本番アクセサリを直接構築する既存テストは、
  **26 言語 × 5 形式**とパスワード全三シート・入力状態を含めて成功した。
- 補助 `.app` ランナーも試行したが、実行時に終了コード **134**、診断ログは空だった。
  その起動成功は主張せず、上記の `xcrun xctest` に切り替えた。
- XCTest 添付への画像エンコードには LaunchServices の `kLSDataUnavailableErr` 警告が出た。
  PNG 自体は一時領域へ保存され、ファイル数と代表画像の表示を確認できた。

ログ:

- `/private/tmp/kf-wave-d-verification/wording-xctest.log`
- `/private/tmp/kf-wave-d-verification/overflow-initial.log`
- `/private/tmp/kf-wave-d-verification/layout-accessory-initial.log`
- `/private/tmp/kf-wave-d-verification/error-text.log`
- `/private/tmp/kf-wave-d-verification/{dependency,catalog,app-link,test-link,runner}.log`

### 4. レイアウトと画像確認

各言語で 51 枚、合計 **1,326 枚**の PNG を保存し、完了した全描画で `UISnapshot.overflowViolations` は空だった。

- 警告（削除、展開失敗、追加失敗、変更失敗、変換、複数アーカイブ失敗）
- ロック画面（通常幅・600 pt 幅）とパスワード入力（名前なし・短い名前・70 文字名、必須・誤り）
- 設定の全タブ、圧縮レベル、選択肢の切替
- ようこそと設定の一般タブは 26 言語 × ライト・ダーク
- 保存アクセサリの全 5 形式、パスワード設定・変更・削除、空欄・不一致・一致
- 120 文字名の進捗、600 pt 幅・大きな数値のステータスバー

hi のようこそ、th のダーク表示、da の二行キャプション、ru の展開設定、pl の圧縮設定、fi の暗号化アクセサリを目視した。
既存のラベル・チェックボックスの折り返し、二行キャプション、必要幅を算出するアクセサリで収まり、
追加のレイアウト寸法変更は不要だった。監査の許容差やはみ出し判定を緩めていない。

実機での Finder Services 登録、システム／アプリ別言語切替、英語フォールバック、
保存パネルの外部サービスを含む表示は [手動検証 §8.1](../manual-verification.md#81-言語)で確認する。

### 5. 静的監査

`/private/tmp/kf-wave-d-work/audit.py` で JSON、書式引数、元のカタログ、言語コード、Services を照合した。
全 Services とプロジェクトは `plutil -lint`、差分は `git diff --check` を実行。
禁止語の検索対象は Git が返す追跡ファイルと新規の非 ignored ファイルに限定した。

```text
PASS catalog: 292 keys × 26 languages = 7,592 nonempty translations; ordered format specifiers match
PASS regression: 2,920 existing translations, all keys and entry metadata unchanged
PASS project: knownRegions = 26 language codes + Base; no no/pt_PT aliases
PASS Services: 26 files / 52 titles; all plutil checks pass; Compress matches catalog
PASS git diff --check
PASS prohibited-term audit: 0 matches in tracked and new non-ignored files
PNG snapshots: 1326
```

全静的監査は終了コード **0**。ログは `/private/tmp/kf-wave-d-verification/static-audit.log`。
