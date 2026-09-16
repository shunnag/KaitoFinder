# 取り出し・QuickLook・undo・外部変更・パスワード入力の敵対的レビューと修正(Wave J)— 2026-09-16

## 方法

Wave H / I と同じ手順。Codex に読み取り専用で、ドラッグアウト・コピーアウト(file promise、
pasteboard)、QuickLook と一時コピー(materialization、起動時 sweep)、undo/redo、外部変更の検出、
パスワード入力を「操作の順序・失敗の順序・異常入力・外部変更」の観点で読ませ、9 件(高 7・中 2)
の候補を得た。オーケストレータがコードで確認し、**修正前に失敗するテスト**を先に書いてから直した。

## 修正した項目

| # | 症状 | 原因 | 修正 | 回帰テスト |
|---|---|---|---|---|
| 3-A | 外部アプリが原本を別内容に置換した後に undo すると、外部の内容が上書きされる(redo 用 clone に移るだけで原本からは失われる) | `restoreUndoSlot` が `sourceIdentity` を照合しない | swap の前に dev/ino/size/mtime を照合(mode は Finder の情報パネルで変わり swap が読み直すので除く)。違えば拒否、履歴は残す | `testUndoRefusesExternalReplacementAndPreservesHistory` / `testRedo…`(修正前に失敗を確認) |
| 3-B | 2 GiB 超のアーカイブで削除すると確認なしで削除され、公開後にスロットが破棄されて undo できない | `canUndoNextMutation` が原本サイズと `maximumBytes` を見ない | サイズを渡し、上限超えは既存の削除確認を出す | `testDeleteOverUndoByteLimitRequiresConfirmationWithoutChangingArchive` / `testDeleteAtUndoByteLimitStartsWithoutConfirmation` |
| 2-B | QuickLook パネルの閉じる通知で文書の一時コピー機能を `close()` し、以後の QuickLook・「開く」が無反応になり得る(design §5 の「パネルを閉じる操作をまたいで再利用する」に反する) | `windowWillClose` がパネルにも `materialization.close()` | `cancel()` + `setSelection([])` にとどめる(`close()` は文書の破棄だけ) | `testPanelCloseKeepsDocumentMaterializationReusable`(修正前に失敗を確認) |
| 2-A | 同じユーザーが 2 つ目のインスタンスを起動すると、起動時 sweep が 1 つ目の公開中の一時コピーを消す | sweep が自分の prefix 以外を全て消す | 領域名に pid を埋め、生きているプロセスの領域は残す | `testLaunchSweepPreservesOtherLiveProcessesAndRemovesDeadAndLegacyAreas`(同) |
| 1-A | 別名で保存すると、受理済みの遅い drag promise が原本が残っているのに失敗する | 旧 session を即 close | promise が無くなるまで旧 session の close を待つ(保持期間の上限あり) | `testSaveAsKeepsAcceptedPromiseAliveUntilDelayedWriteCompletes` / `testDocumentCloseAfterSaveAsCancelsRetainedPromiseWithoutWaitingForExpiry` / `testRegistryWaitTracksOnlyItsSession…` |
| 5-A | 異なるパスワードの項目をまとめて選ぶと、正しい鍵でも再入力を繰り返す | reader は 1 つの鍵しか持てず、一部成功を区別しない | 一部が成功し一部が wrongPassword なら「選択した項目には異なるパスワードが設定されています。同じパスワードの項目ごとに展開してください。」で止める(26 言語) | `testMixedPasswordsRefuseCombinedExtractionAndAllowEachEntrySeparately`(修正前に失敗を確認。fixture は `zip -P` を 2 回) |

## 明示にとどめた項目

- 4-A: 同じ inode・同じサイズで上書きし更新日時も戻す変更は検出できない(`identity` は ctime と
  内容を見ない。ctime は LaunchServices の xattr や Finder タグでも変わるため除いている)。
  README にこの限界を明記した。
- 4-B: 完成済みの QuickLook コピーは外部置換後もそのまま表示される(展開は拒否される)。表示は
  ユーザーが既に見た内容で、害はないので未修正。外部変更の検出時にキャッシュを捨てる改善は候補。
- 1-B: 同じ promise への再要求(受信アプリの再試行)の寿命。AppKit の挙動が未確認のため未修正。

## 検証

全件 `xcodebuild test` 642 件・失敗 0・skip 1(QuickLook の前面化)。回帰テスト 10 件のうち
5 件は修正前に失敗することを確認した(残りは新しい API・注入に依存)。起動スモーク(Debug、
fixture を引数に起動 → ウインドウ 1 → 正常終了)。
