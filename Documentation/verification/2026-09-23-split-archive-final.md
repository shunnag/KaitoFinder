# 分割アーカイブの編集（M0〜M6）の最終検証

検証環境: macOS 27.2、arm64。ロック解除した GUI セッションで実行（`swift Tools/verify_gui_session.swift` が実行前後とも unlocked）。
対象コミット: KaitoFinder da5e81e（feature/split-archive-editing）、KaitoKit 03fd19b、GyoshukuKit 4c8c882。

## 全体テスト

1 回目（ロック解除、da5e81e のビルド）: 1187 件実行、skip 18、失敗 2（1 テスト）。
ArchivePasswordUITests.testSplitSavePanelResizesWithoutSlidingContents で、保存シート（保存先一覧を閉じた状態）に
「分割」の行があると、暗号化の行の伸縮中にシートの中心が 2.0 pt 動いた（3 回とも同じ）。

テストの修正（ユーザーの許可を得てオーケストレータが直接変更）:

- 親ウインドウの高さ: テストの親の内容の高さ 550 pt では、分割の行を含む展開後のシート（522 pt）を中央に置くと上端が 552 pt になり、
  AppKit がタイトルバーの下（550 pt）へ寄せるため中心が 2 pt ずれる（読み取り専用の診断）。分割の行がある場合だけ親を 600 pt にした。
  判定の 0.01 pt は変えていない。修正後は 16 通りの組み合わせすべてで 0.0 pt。
- 配置が落ち着くまで待つ: 修正中に、testPresentedSplitSavePanelAnimatesEncryptionAndCancelsWithoutSaving が単独実行で
  必ず失敗することを見つけた（全体実行では通る。変更前のコミットでも単独実行で失敗）。暗号化の行を開いた直後、
  付属ビュー（319 pt）の中のフォームが y = 6 に置かれ 6 pt はみ出していた。フォームは表示中のパネルの高さ
  （`viewportHeightInPanel`、この時点で 313 pt）に上端を合わせるため、付属ビューが先に伸び切ってもパネル本体の伸縮が
  終わるまでずれる。検査の前に、はみ出しがなくなるまで待つようにした（待っても消えなければ詳細付きで失敗する）。
  修正後、単独実行 3 回とクラス全体 2 回が通った。**未確認**: 分割の行のない従来の保存パネルにも同じ一時的なずれがあるのか、
  分割の行に固有で 1 フレーム程度 6 pt のはみ出しが見えうるのかは、画面がロックされたため確かめていない（追跡項目）。

2 回目（修正後のビルド）: 1187 件実行、skip 18、失敗 3（2 テスト）。ArchivePreviewSidebarTests.testMenuToolbarAndKeyboardToggleTheActiveArchive と
ArchiveTabTests.testOpeningPreferenceChangesOnlyNewWindowsAndKeepsNativeTabCommands は、実行中に画面がロックされたための
「無効なメニュー項目」で、1 回目（ロック解除）ではどちらも通っている。保存パネルの 2 テストは 2 回目も通った。

## 各リポジトリ

- KaitoKit: swift test 1412 件（skip 45）+ 互換 34 件、失敗 0（03fd19b）。
- GyoshukuKit: swift test 245 件（skip 1）、失敗 0（4c8c882）。

## 反証レビュー

- M2: 4 回（36 → 25 → 12 → 17 件、最後は軽微のみ）。第 4 回の修正は M5 の統合レビューで間接的に確認。
- M3 / M4: 1 回（20 件、重大 3 件）→ 修正。
- M5: 統合レビュー 1 回（22 件、重大 8 件）→ 修正。
- M6: 統合レビュー 1 回（18 件、保存先ごとの同意の範囲を含む）→ 修正。
- 「保存」メニュー追加による確認シートの Return の退行は、コミットをさかのぼって特定し修正（ab29814）。
