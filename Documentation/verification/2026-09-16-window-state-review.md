# ウインドウ状態機械の敵対的レビューと修正(Wave H)— 2026-09-16

## 方法

Codex に読み取り専用で、`ArchiveWindowController` / `ArchiveDocument` / `AppDelegate` /
`ExtractionProgressSheet` / `WelcomeWindowController` / `ArchiveBatchExtractionController` を
「ユーザー操作の順序と非同期の完了順」の観点で読ませ、候補ごとに所在・引き金となる操作・
期待と実際・コード経路の根拠・確信度・再現テストの骨子を報告させた(状況 8 種を指定、
既存テストで担保済みの項目はテスト名を挙げて除外)。報告された 7 件(高)+ 1 件(中)を
オーケストレータがコードで確認し、**修正前に失敗するテスト**を先に書いてから直した。

## 修正した項目

| # | 症状 | 原因 | 修正 | 回帰テスト |
|---|---|---|---|---|
| 2 | 改名を未確定のまま ⇧⌘S(またはパスワード操作)すると、改名の公開 Task を別の Task が上書きし、改名側の defer が後続の Task/Progress を消す | 可否確認が `commitRenaming()` の前。確定が同期的に `startEdit` → `extractionTask` を登録する | 確定 → 可否確認の順に | `testSaveAsAfterInlineRename…` / `testPasswordAfterInlineRename…`(修正前に失敗を確認) |
| 4 | 同じパスのレコードを 2 つ持つ ZIP で片方だけ選んで並べ替えると両方が選ばれ、以後の削除が選んでいないレコードにも及ぶ | `ArchiveViewState.selectedPaths` がパスの集合だけ | 同じ世代の復元は `selectedEntryIndices`(レコード番号)で選ぶ。世代が進んだ後と編集後のパス指定は従来どおり | `testDuplicateRecordSelectionSurvivesSortAndDisplayButFallsBackAfterMutation`(修正前に失敗を確認) |
| 6 | 作成中にようこそウインドウへドロップすると、成功扱いで受け取って黙って捨てる | drop zone に busy の判定がない | `canAcceptDrop` を通し、作成 Task かパネルがある間は受け付けない(強調表示もしない) | `testCreateDropRechecksCanCreateAtEveryDragStage` |
| 5 | 作成の進捗シートがようこそウインドウに付いたまま別の文書が main になると、親ごと閉じて進捗とキャンセル手段が消える(作成は続く) | `archiveWindowBecameMain` が無条件に `close()` | シートが付いている間は閉じない | `testArchiveMainWindowKeepsWelcomeOpenUntilAttachedProgressSheetFinishes` |
| 8 | 内側の壊れたアーカイブを「開く」と、展開は成功したのに「項目を展開できませんでした」 | 開く段階の失敗も展開用の見出し | `reportFailure(_:title:)` で「項目を開けませんでした」(26 言語)を使う | `testOpeningBrokenNestedArchiveReportsOpenFailureAfterSuccessfulExtraction` |
| 1-A | 検索中に改名・移動すると、検索解除時に検索前の(古いパスの)選択・展開が復元される | `unfilteredViewState` が変換されない | 公開成功時に `unfilteredViewState` にも同じパス変換 | `testClearingFilterAfterRename…` / `testClearingFilterAfterMove…` |
| 1-B | 検索中に手で折り畳んだフォルダが、編集完了の再表示で全部展開し直される | `display()` が検索中は全展開 | `collapsedPaths` を取り、全展開の後に(選択の祖先を除いて)折り畳み直す。新しく現れた一致フォルダは従来どおり展開 | `testAppendPreservesCollapsedMatchingFolderAndSearchQuery` |
| 1-C | 編集後の復元で横スクロールが左端に戻る | `scroll(NSPoint(x: 0, …))` | `scrollX` を取って戻す | `testAppendPreservesHorizontalScrollPosition` |

1-B の最初の実装(`display()` で全展開しない)は、undo で再び現れた一致フォルダが折り畳まれた
ままになり、既存の `testFilteredDeleteRemovesEntireRealAndVirtualSubtreesWithUndoRedo` と
`testFilteredInlineRenameRewritesHiddenDescendantsOfRealAndVirtualFolders` が実行で落ちた。
「検索中は一致を見せる」を保ちつつ「手で折り畳んだものは尊重する」規則に改めた。

## 除外した項目(既存テストで担保)

drag promise と編集の競合(`DragCopyOutTests` の世代不一致 3 件)、`switchBackingFile` 中の
undo / パスワード記憶 / 一時コピー(`ArchiveSaveAsTests`、`ArchivePasswordPersistenceTests`、
`ArchiveThumbnailTests`)、展開中の編集禁止(`ScenarioConcurrencyTests`)。

## 未確認のまま残した候補

- `reportFailure` 系が `window == nil` のとき無通知で return する分岐。通常操作で
  非取消しエラーがそこへ届く順序は確認できていない。
- 新規作成のパネルと一括展開のパネルは相互排他でない(同時に開ける)。不具合になる順序は未確認。

## 検証

全件 `xcodebuild test` 622 件・失敗 0・skip 1(QuickLook の前面化)。起動スモーク(Debug、
fixture を引数に起動 → CGWindowList でウインドウ 1 → `osascript` quit で正常終了。引数なしの
起動でようこそウインドウ 1 → 正常終了)。
