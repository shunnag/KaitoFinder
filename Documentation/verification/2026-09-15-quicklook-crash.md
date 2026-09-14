# 検証: クイックルック(Space)で落ちる — `2d05b22`

ユーザー報告「クイックルックをしようとスペースキーを押したらクラッシュ」。Xcode から
実行していたためクラッシュレポートは無く、lldb で再現した。

## 再現の要点

- 背面で `togglePreviewPanel:` を呼ぶだけでは**落ちない**(パネルは出る)。
- `open -a` で前面に出し、ウインドウを key にして同じ操作をすると落ちる。
  trigger thread は `NSOperationQueue`:
  `_checkExpectedExecutor ← @objc ArchivePreviewItem.previewItemURL.getter
   ← -[QLPreviewView shouldUseAsyncLoading] ← QLPreviewDocument startLoading…
   ← NSFileCoordinator _invokeAccessor:`
- 原因: `ArchivePreviewItem` が app target の既定隔離で `@MainActor` になり、
  `QLPreviewItem` の getter が main actor 隔離。前面の QuickLookUI は非同期読み込みで
  項目を operation queue から読むので、Swift 6 の動的隔離検査が trap する。
  `4135e04` の文書オープンと同じ型の不具合(AppKit / QL がバックグラウンドから触る
  ObjC 面が、既定隔離で main actor になっている)。

## 修正と証明

- `ArchivePreviewItem` を `nonisolated` + `Sendable` にし、URL を `Mutex` で保護。
- `testPreviewItemPropertiesAreReadableThroughObjCProtocolOffMainThread`: protocol 面
  (`any QLPreviewItem`)経由で非 main thread から読む。`nonisolated` を外すと
  **テスト host ごと落ちる**(Executed 0 tests)。
- 前面テスト `testQuickLookForSelectedZIPRowSurvivesForegroundAsyncLoading` は
  テスト host が前面になれない環境(ここ)では XCTSkip。実アプリで前面再現を再実行し、
  パネル(800×500)が出て生存、新しいクラッシュレポートなし。
- 358 件(1 skip)0 失敗。

## 同型の穴の点検

AppKit / QL が main 以外から触り得る ObjC 面を洗った: file promise の書き出し
callback(`nonisolated`、自前 queue)、QL の data source / delegate(main 契約)、
outline / toolbar / path control / menu の delegate(main)、サービスの provider(main)、
`EntryNode`(outline の item、main)。残りは無い。
