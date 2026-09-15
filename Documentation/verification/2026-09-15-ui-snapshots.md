# UIスナップショットとレイアウト監査 — 2026-09-15

## 実装

`UISnapshot`でNSView、NSWindow、NSAlertをプロセス内描画し、2倍解像度のPNGを保存する。各画像を`XCTAttachment(contentsOfFile:uniformTypeIdentifier:)`で添付し、`.keepAlways`を指定する。透明なビューにはウインドウの背景色を合成する。

`overflowViolations(in:)`は、単一行テキスト・ボタン・ポップアップの必要サイズ、折り返しテキストの必要高、親の領域を越える子ビューを0.5ポイントの許容差で検査する。非表示の階層を除外し、スクロール領域では文書ビューの大きさを許容しつつ、その中のコントロールも検査する。パスワード値は診断文に含めない。

日英の各Bundleを組み立て、44場面を監査する。はみ出しのアサート前にPNG保存と添付を行う。

## 変更ファイル

| ファイル | 内容 |
| --- | --- |
| [KaitoFinderTests/Support/UISnapshot.swift](../../KaitoFinderTests/Support/UISnapshot.swift) | 描画・添付・はみ出し検出ヘルパーを追加 |
| [KaitoFinderTests/LayoutOverflowTests.swift](../../KaitoFinderTests/LayoutOverflowTests.swift) | 日英の画面監査11テストを追加 |
| [KaitoFinderTests/UISnapshotTests.swift](../../KaitoFinderTests/UISnapshotTests.swift) | 検出器とPNGの検証6テストを追加 |
| [KaitoFinder/UI/ArchivePasswordPrompt.swift](../../KaitoFinder/UI/ArchivePasswordPrompt.swift) | アクセサリの初期サイズと入力欄の幅を修正、表示時のBundleを伝播 |
| [KaitoFinder/UI/ArchiveWindowController.swift](../../KaitoFinder/UI/ArchiveWindowController.swift) | Bundle注入、フッターの余白、実際の表示処理と共有するアラート生成ヘルパー |
| [KaitoFinder/UI/PreferencesWindowController.swift](../../KaitoFinder/UI/PreferencesWindowController.swift) | Bundle注入、ラベルを含むスタックの余白 |
| [KaitoFinder/UI/ArchiveSavePanel.swift](../../KaitoFinder/UI/ArchiveSavePanel.swift) | Bundle注入、共有アクセサリ生成処理、初期サイズと余白 |
| [KaitoFinder/UI/ExtractionProgressSheet.swift](../../KaitoFinder/UI/ExtractionProgressSheet.swift) | Bundle注入、初期の進捗表示、ラベルとバーの余白 |
| [KaitoFinder/UI/ArchiveCreationController.swift](../../KaitoFinder/UI/ArchiveCreationController.swift) | `offerConversion`と監査が共有する変換アラート生成処理 |
| [Documentation/verification/2026-09-15-ui-snapshots.md](2026-09-15-ui-snapshots.md) | このレポート |

GyoshukuKit、KaitoKit、project.pbxprojは変更していない。新規の表示文言はなく、既存の日英文言を使用した。

## 追加テスト名

### LayoutOverflowTests

- `testPasswordPromptsInJapaneseAndEnglish` — required/incorrect × 名前なし/短い名前/CJKと空白を含む70文字の名前
- `testLockedWindowAndFooterInJapaneseAndEnglish` — 1040×684ポイントの内容とフッター単体
- `testSettingsTabsInJapaneseAndEnglish` — 一般・圧縮・展開
- `testConversionAlertsInJapaneseAndEnglish` — 暗号化の説明段落あり/なし
- `testDeleteConfirmationInJapaneseAndEnglish`
- `testImportFailureAlertsInJapaneseAndEnglish` — 3行の理由、追加前失敗/追加後の再読込失敗
- `testEditFailureAlertsInJapaneseAndEnglish` — 変更前失敗/変更後の再読込失敗
- `testExtractionFailureAlertsInJapaneseAndEnglish`
- `testBatchExtractionFailureAlertInJapaneseAndEnglish` — 3アーカイブの失敗
- `testSavePanelAccessoryInJapaneseAndEnglish` — 実際の`panel.accessoryView`
- `testStandaloneProgressSheetInJapaneseAndEnglish` — 長いタイトルの単独進捗パネル

### UISnapshotTests

- `testDetectsClippedSingleLineLabel` — 必要幅400ポイント以上の文字列を100ポイント幅に配置
- `testDetectsWrappingLabelWithInsufficientHeight`
- `testDetectsClippedButtonsAndPopup`
- `testDetectsFramesOutsideParentAndSkipsHiddenSubtrees`
- `testScrollViewAllowsLargeDocumentButStillChecksItsControls`
- `testRenderOverloadsWriteTwoTimesPNGs` — 3オーバーロード、PNG署名、画素数、背景の不透明度、描画内容を検証

## 保存先

- 環境変数`KAITOFINDER_SNAPSHOT_DIR`があれば、そのディレクトリを作成して使用する。
- xcodebuildから指定する場合は`env TEST_RUNNER_KAITOFINDER_SNAPSHOT_DIR=<dir> xcodebuild test …`を使う。xcodebuild自身のプロセスに設定された`TEST_RUNNER_`付き環境変数が、接頭辞を外してテストランナーへ転送される。xcodebuildの引数として渡しても効果はない。
- 未指定時は`NSTemporaryDirectory()/KaitoFinderSnapshots/<UTC日時>/`。日時は例として`2026-09-15T03-02-44.042Z`の形式。新しい実行ディレクトリを作成した後、日時名で新しい順に今回を含めて5世代だけを残す。環境変数が設定されている場合は削除しない。
- ファイル名は`ja-password-required-long-name.png`、`en-settings-compression.png`など。ヘルパー検証用は`harness-*.png`。
- 保存先のパスはテストプロセスにつき一度出力する。
- 今回の補助検証では`KAITOFINDER_SNAPSHOT_DIR=/private/tmp/kaitofinder-snapshot-check/snapshots`を使用し、47枚を生成した。

## 検出したはみ出しと修正

| 箇所 | 修正前の実測 | 修正 |
| --- | --- | --- |
| パスワード入力アクセサリ | アラート内の親領域が0×0で、300×48ポイントのスタックが領域外に配置された | アラートに渡す前に`fittingSize`を初期フレームへ設定。入力欄は幅300ポイント以上でアクセサリの幅に追従 |
| ロック画面のフッター | 日英とも説明ラベルのフレームが左へ2ポイント越えた | 左右2ポイントのスタック余白 |
| 設定の全タブ | 行ラベル・グループ見出し・説明が左へ2ポイント、レベルの数値ラベルが右へ2ポイント越えた | 行・グループ・レベル・タブの各スタックに左右2ポイントの余白 |
| 保存アクセサリ | 形式ラベルと暗号化不可の説明が左へ2ポイント越え、英語の説明は右にも2ポイント越えた | 行と外側のスタックに左右2ポイントの余白を設け、自然サイズで初期化 |
| 進捗パネル | 状態ラベルが左へ2ポイント越えた | 左右2ポイントの余白を設け、バーの幅も内側に合わせた |

パスワードの全12場面は修正後のウインドウ幅が332ポイントで、長い名前も500ポイント以内に収まった。名前の省略やボタンの文言変更は不要だった。変換・削除・各失敗アラートにははみ出しを検出しなかった。

## 補助検証

一時ディレクトリで現在のアプリソースをコンパイルし、既存のビルド済みKaitoKit/GyoshukuKitをリンクした。一時フレームワークの言語リソースにはビルド済みアプリのja/en.lprojを使用した。ソースと全既存・新規テストのSwift型チェックは警告なしで成功した。

直接起動したXCTestでは、監査10テスト、ヘルパー6テスト、一時的な保存アクセサリ確認1テストの計17テストが成功した。44場面とヘルパーの3画像を生成し、代表画像も目視確認した。ロック画面のPNGは日英とも2080×1368画素。

この補助実行には次の制約がある。

- `NSSavePanel`の生成は外部サービスへの接続で止まったため、実際のパネルを使う追加テスト1件の実行完了は確認できていない。保存アクセサリは、パネルと同じ`makeAccessoryView`を呼ぶ一時テストで確認した。
- 添付のエンコードでは`kLSDataUnavailableErr`による警告が47件出た。PNG保存・読込は成功しているが、XCTest結果への添付保存の成功は未確認。
- この補助実行を、アプリをホストにした全既存テストの成功とは扱っていない。

補助ログ: `/private/tmp/kaitofinder-snapshot-check/audit-final.log`。生成画像: `/private/tmp/kaitofinder-snapshot-check/snapshots/`。

## 指定の検証コマンド

```sh
cd /Users/nagash/Github/KaitoFinder && xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS' test 2>&1 | tail -15
```

実行シェルでは終了コードを保持するため`pipefail`を有効にした。終了コードは**74**。想定どおりサンドボックスがClang/SwiftPMのキャッシュ書き込みを拒否し、依存関係解決の段階で止まった。これはテスト失敗ではなく、全テストの実行結果は未確認。

末尾15行:

```text

Package: unknown

2026-09-15 12:12:16.759 xcodebuild[75901:10445395] Writing error result bundle to /var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/ResultBundle_2026-15-09_12-12-0016.xcresult
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/gyoshukukit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/kaitokit.dia' for diagnostics emission (Operation not permitted)
  <unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
<unknown>:0: error: cannot open file '/Users/nagash/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/gyoshukukit.dia' for diagnostics emission (Operation not permitted)

```
