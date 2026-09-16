# Services・設定・最近使った項目・app レベルのエラー表示・起動の敵対的レビューと修正(Wave K)— 2026-09-16

## 方法

Wave H / I / J と同じ手順。4 回目の読み取り専用レビューは Services の入口、設定ウインドウ、
最近使った項目、app レベルのエラー表示(`presentFailure` / `NSApp.presentError` / `ArchiveErrorText` の
`default` 経路)、起動引数の処理を対象にし、候補は 4 件(高 3・中 1)。回を追うごとの候補数は
8 → 7 → 9 → 4 で、収穫が減り始めている。

## 修正した項目

| # | 症状 | 原因 | 修正 | 回帰テスト |
|---|---|---|---|---|
| 1 | LHA でシンボリックリンクを固めると失敗理由が `Docs/link: unsupportedFileType("Docs/link")` | `ArchiveCreationTransaction.add` が `\(error)` で文字列化 | `ArchiveErrorText.describe(error)` を通す(「対応していないファイルの種類です: …」) | `testLHASymlinkFailureUsesLocalizedWriterDescription`(修正前に失敗) |
| 2 | Services の入力に同じアーカイブが 2 件あると `archive` と `archive 2` に 2 回展開(ゴミ箱オンなら 2 件目は失敗) | `archivesToExtract` / `filesToCompress` が重複を残す | 実パスで順序を保って重複を除く | `testFinderExtractionRemovesDuplicateURLsPreservingOrder` / `…SymlinkPaths…` / `testFinderCompression…`(2 本) |
| 3 | アーカイブでない `bad.zip` を起動引数・ようこそのドロップ・File > 開く で開くと、KaitoKit の英語 `Unsupported archive format` が出る | `ArchiveDocument.read` が `KaitoError` をそのまま投げ、`NSApp.presentError` が英語の `errorDescription` を使う | `read` で「アーカイブを開けませんでした」(26 言語)+ `ArchiveErrorText` の理由を持つ NSError に包む | `testInvalidZIPReturnsLocalizedDocumentErrorWithUnderlyingKaitoError` / `testInvalidZIPReadWrapsFailureBeforeInstallingSession`(修正前に失敗)/ `testHeaderEncryptedReadKeepsLockedDocumentWithoutPresentingPrompt` |
| 4 | 存在しないパスを起動引数に渡すと無言で捨てられる | `fileExists == false` で `continue` | Cocoa の `NSFileNoSuchFileError` で報告(ようこその判定は従来どおり) | `testLaunchArgumentsReportMissingPathAndContinueOpeningFixture` / `testMissingLaunchArgumentKeepsWelcomeEligibleAndIgnoresOptions`(修正前に失敗) |

## 除外した項目(既存テストで担保)

Services の宣言・file URL のフィルタ・パネル表示中の再呼び出し(`ArchiveCreationUITests` /
`ArchiveBatchExtractionUITests`)、非アーカイブ・フォルダの混在(`ScenarioServicesTests`)、
設定値の往復と不正値(`ArchivePreferencesTests` / `ArchivePreferencesUITests`)、隠しファイル設定の
複数文書への反映(`ArchiveHiddenFilesTests`)、別名で保存の最近使った項目(`ArchiveSaveAsTests`)、
各エラー型の変換(`ArchiveErrorTextTests`)、ようこその表示条件(`WelcomeWindowTests`)。

## 未確認のまま残した項目

異種パネルの併存時の前面順序、数百件の失敗を並べたアラートの実表示、ネットワークボリュームの
切断時の応答、設定ウインドウの OS による状態復元、最近使った項目の削除済み/symlink/エイリアス、
起動時に複数ファイルを開いた場合の失敗パネルの順序。

## 検証

全件 `xcodebuild test` 661 件・失敗 0・skip 1(QuickLook の前面化)。回帰テスト 10 件のうち
4 件は修正前に失敗することを Codex が直接実行で確認(K-2 の pasteboard テストは sandbox では
スキップ、こちらの実行で通過)。起動スモーク(Debug、fixture を引数に起動 → ウインドウ 1 → 正常終了)。
