# 操作中の終了 — 2026-09-16

## 発端と実測(変更前)

`AppDelegate` は `applicationShouldTerminate(_:)` を実装しておらず、`ArchiveDocument.close()` は
展開の取消しと後始末を非同期 Task に投げるだけだった。

- in-process のプローブ(4 MiB の entry の展開を `didWrite` で止め、`document.close()` を呼ぶ):
  `close()` が返った直後、`out/large.bin`(途中)は存在し、`extractionTask` の完了後に消えた。
  公開を `willPublish` で止めて `close()` すると、`.KaitoFinder-add-<UUID>/` は `close()` 直後に
  存在し、Task 完了後に消えた。つまり後始末はプロセス終了に間に合わない。
- 実機(Debug、50 万件の一括展開中に `osascript` で quit): 作成したフォルダが残った。
- lldb で quit の経路を追跡(文書を 1 つ開いた状態、非 dirty):
  `-[NSApplication _shouldTerminate]` → `-[NSApplication terminate:]` →
  `-[NSWindow _closeForTermination]` → `-[NSWindow _close]` → `-[NSWindowController _windowDidClose]`
  → `ArchiveDocument.close()`。`reviewUnsavedDocuments…` / `closeAllDocuments…` /
  `canClose(withDelegate:)` は呼ばれない。したがって文書側の `canClose` では ⌘Q を捕まえられず、
  `applicationShouldTerminate` が唯一の終了前フック。

## 変更

`AppDelegate.applicationShouldTerminate(_:)`: 進行中の仕事(文書の `hasWorkInFlight`、作成 Task、
一括展開 Task)があれば「KaitoFinderを終了してもよろしいですか？」で確認し、終了なら全て取り消して
`.terminateLater`。各文書の `prepareForTermination()`(取消し → 完了待ち → undo スロットと
一時コピーの破棄)と app レベルの Task の完了を待ち、`reply(toApplicationShouldTerminate: true)`。
上限 10 秒は独立した 2 つの MainActor Task(後始末 / 期限)が同じ `finishTermination()` を呼び、
先に着いた方だけが返答する形で実装した(`withTaskGroup` は取消しに反応しない後始末を暗黙に
待つため、上限が効かない)。進行中の仕事が無くても undo スロットがあれば確認なしで同じ待ち。
何も無ければ `.terminateNow`。

## 実測(変更後)

- `ApplicationTerminationTests` 7 件(仕事なし → `.terminateNow`、キャンセル → 展開完走、
  終了 → 戻り直後は partial が残り返答時には消えている、公開直前の取消しと `.KaitoFinder-add-*`
  の削除、undo スロットの破棄、上限 300 ms での返答、Services の一括展開の取消し待ち)。
- 実機(Debug、`applicationShouldTerminate` に lldb のブレークポイント、確認は自動で「終了」):
  50 万件の一括展開を 5,550 ファイルまで書いたところで `osascript` の quit。
  `applicationShouldTerminate` は `-[NSApplication _docController:shouldTerminate:]` ←
  `-[NSDocumentController _closeAllDocumentsWithDelegate:shouldTerminateSelector:]` から呼ばれ、
  後始末 Task は AppKit が `NSModalPanelRunLoopMode` で待つ間に main actor で走り、
  `finishTermination()` → `-[NSApplication replyToApplicationShouldTerminate:]` は 1 回だけ、
  期限 Task は取消し後に起きて no-op。quit から exit まで 1.14 s(lldb なしの再実行で 0.73 s)、
  `big500k/` フォルダとファイルは残らなかった。
- 実機(文書を 1 つ開いた idle 状態の quit): 0.09 s で終了(遅延なし)。
- 全件: `xcodebuild test` 611 件・失敗 0・skip 1(QuickLook の前面化テスト。テスト host が
  前面になれない環境の既知のスキップ)。

## 残る課題

- kill -9 / クラッシュの `.KaitoFinder-add-*` / `.KaitoFinder-new-*` は回収しない(design §12-5)。
- 別名で保存や新規作成の保存パネルが出ているだけの状態でも、Task が生きているため確認が出る
  (実害なし)。
