# 最近使った項目の修正 — 2026-09-17

## 原因と修正

`AppDelegate.makeMenu` は通常の `NSMenu` に「メニューを消去」を置くだけで、
AppKit の最近使った項目メニューとして接続していなかった。文書を開くと
`NSDocumentController.recentDocumentURLs` に URL は入るが、メニューを表示しても項目が出ない。
既存の別名保存テストは URL の登録だけを確認していたため、この不具合を検出できなかった。

Xcode の標準 Main Menu テンプレートと同じ `systemMenu="recentDocuments"` を持つ
小さな `RecentDocumentsMenu.xib` を追加し、プログラムで作るファイルメニューに組み込む。
履歴の保存・項目の生成・再オープン・消去は引き続き標準の `NSDocumentController` に任せる。
メニューの二つの見出しは既存の文字列カタログから取得し、26 言語の表示を保つ。
初期化順序や文書を開く経路は変更していない。

標準の文書コントローラが Open Recent を管理する責務については
[Apple の文書アプリ設計資料](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/KeyObjects/KeyObjects.html)を参照。

## 検証

- `RecentDocumentsMenuTests.testOpenedArchiveAppearsInRecentMenuAndCanBeReopened`:
  ZIP を標準の文書オープン経路で開いて閉じ、実際にメニューを表示し、生成された履歴項目の
  action から新しい文書とウインドウが開くことを確認。元のメニュー構築へ戻すと失敗し、修正後は通過。
- AppKit はメニューの表示時に履歴項目を生成するため、テストも `popUp` と timer による
  `cancelTracking` で実際に開閉する。`update()` による validation だけの検査では不十分。
- 関連テスト 42 件、失敗 0、skip 1。履歴の回帰テスト、通常の文書オープン、別名保存、
  ようこそ画面、26 言語の標準メニューを含む。skip はテストホストを前面にできない Quick Look の既存テスト。
- 実行時は `PRODUCT_BUNDLE_IDENTIFIER=com.shunnag.KaitoFinder.RecentMenuVerification` を指定し、
  実ユーザーの通常アプリの履歴と分離した。
- 通常の識別子 `com.shunnag.KaitoFinder` の Release ビルド成功。製品に
  `RecentDocumentsMenu.nib` が含まれること、ZIP を引数に起動して文書ウインドウが現れ、
  通常の終了処理で exit 0 になることを確認した。

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/ReviewDerivedData \
  -only-testing:KaitoFinderTests/RecentDocumentsMenuTests \
  -only-testing:KaitoFinderTests/ArchiveDocumentOpeningTests \
  -only-testing:KaitoFinderTests/ArchiveSaveAsTests \
  -only-testing:KaitoFinderTests/WelcomeWindowTests \
  -only-testing:KaitoFinderTests/WordingAcceptanceTests/testStandardMenusHaveLocalizedTitlesActionsShortcutsAndApplicationBindings \
  PRODUCT_BUNDLE_IDENTIFIER=com.shunnag.KaitoFinder.RecentMenuVerification test
```

ログ: `/tmp/kaitofinder-recents-regression-before.log`（修正前）、
`/tmp/kaitofinder-recents-related.log`（修正後）、`/tmp/kaitofinder-recents-release.log`、
`/tmp/kaitofinder-recents-release-smoke.log`。
