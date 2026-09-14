# 検証: 実アプリの起動スモークで見つかった「文書を開くと落ちる」— `4135e04` / `0c6ce61`

完成の定義(§10.1)を照合する前に、作った app に書庫のパスを渡して起動した。
**353 件のテストが通っていた状態で、ファイルを開くと必ず落ちていた。**

## 実測

- `KaitoFinder.app/Contents/MacOS/KaitoFinder smoke.zip` → exit 133(SIGTRAP)、
  CGWindowList にウインドウなし。クラッシュレポートの trigger thread は
  "NSDocumentController Opening":
  `_dispatch_assert_queue_fail ← _checkExpectedExecutor ← @objc ArchiveDocument.init()
   ← -[NSDocument initWithContentsOfURL:ofType:error:] ← NSBlockOperation`
- 原因: `canConcurrentlyReadDocuments(ofType:)` が `true`(4456df4、2026-09-10)。
  AppKit は並行読み込みを許された文書の initializer をバックグラウンドの operation
  queue で呼ぶ。`ArchiveDocument` は `@MainActor` なので Swift 6 の動的隔離検査が trap。
- File › 開く、Finder からのダブルクリック、⌘N で作った書庫の open、すべて同じ経路。
- 単体テストは `ArchiveDocument()` を main で直接作り、`NSDocumentController` を
  通らないので一件も踏んでいなかった。

## 修正と証明

- `false` にする。`read(from:ofType:)` は非隔離のままでよい(文書の生成だけ main)。
- `ArchiveDocumentOpeningTests`(3 件): `NSDocumentController.shared.openDocument`
  を実際に通し、ZIP と tgz でウインドウと一覧が出ることを見る。`true` に戻すと
  **テスト host ごと落ちる**(Executed 0 tests)。
- 起動スモーク(修正後): ZIP と tgz を渡して起動 → 1040×684 のウインドウ 2 つ、
  SIGTERM で正常終了(143)、新しいクラッシュレポートなし。
- `ExtractionTests` の旧契約テスト(並行読み込み true を主張)は新契約に書き換えた。
  4135e04 は全件を回す前に push してしまい、この 1 件が HEAD で赤かった(0c6ce61 で修正)。

## 修正後に残っていた 260×283 のウインドウ

CGWindowList に出ていた 260×283 は app のエラーではなく、macOS の
「“KaitoFinder”を最後に開いたとき、ウインドウの再開中にアプリケーションが突然終了しました。
もう一度ウインドウを再開しますか?」(lldb で `_NSAlertPanel` の文言を読んだ)。
上のクラッシュの名残で、一度正常に終了(Apple event の quit)すると消える。
消した後の再起動は書庫のウインドウ 1 つだけ、exit 0。

## 教訓

緑のテストは NSDocumentController の経路について何も言わない。文書や AppDelegate に
触ったら、最後ではなく毎回、作った app を fixture 付きで起動して exit code と
CGWindowList を見る。
