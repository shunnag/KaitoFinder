# 分割アーカイブの編集（M0〜M6）の最終検証

検証環境: macOS 27.2、arm64。ロック解除した GUI セッションで実行（`swift Tools/verify_gui_session.swift` が実行前後とも unlocked）。
対象コミット: KaitoFinder da5e81e（feature/split-archive-editing）、KaitoKit 03fd19b、GyoshukuKit 4c8c882。

## 全体テスト

`xcodebuild … test-without-building`（build-for-testing 済み、`KaitoFinder.debug.dylib` に `ArchiveSaveSplitControls` のシンボルを確認）:
1187 件実行、skip 18、失敗 2（1 テスト）。

- 失敗: ArchivePasswordUITests.testSplitSavePanelResizesWithoutSlidingContents（M6 で追加した GUI テスト）。
  保存シート（保存先一覧を閉じた状態）で「分割」の行があると、暗号化の行の伸縮中にシートの中心が 2.0 pt 動く（3 回とも同じ）。
  他の組み合わせと、分割の行のない従来の testSavePanelResizesWithoutSlidingContents は 0.0 pt。
- 原因（読み取り専用の診断）: テストの親ウインドウの内容の高さが 550 pt で、分割の行を含む展開後のシート（522 pt）を中央に置くと
  上端が 552 pt になり、AppKit がタイトルバーの下（550 pt）へ寄せるため中心が 2 pt ずれる。アプリの配置の不具合ではなく、
  テストの親ウインドウが低いことによる。提案される修正はテストの親の高さを 600 pt にすること（判定の 0.01 pt は緩めない）。
- 未適用: 書き込み権限つきの Codex の起動が自動許可の判定で拒否されたため、この 1 行は変更していない。
- 以前に環境依存で失敗していた ArchivePreviewSidebarTests と ArchiveTabSpringLoadingTests は今回はすべて通った。

## 各リポジトリ

- KaitoKit: swift test 1412 件（skip 45）+ 互換 34 件、失敗 0（03fd19b）。
- GyoshukuKit: swift test 245 件（skip 1）、失敗 0（4c8c882）。

## 反証レビュー

- M2: 4 回（36 → 25 → 12 → 17 件、最後は軽微のみ）。第 4 回の修正は M5 の統合レビューで間接的に確認。
- M3 / M4: 1 回（20 件、重大 3 件）→ 修正。
- M5: 統合レビュー 1 回（22 件、重大 8 件）→ 修正。
- M6: 統合レビュー 1 回（18 件、保存先ごとの同意の範囲を含む）→ 修正。
- 「保存」メニュー追加による確認シートの Return の退行は、コミットをさかのぼって特定し修正（ab29814）。
