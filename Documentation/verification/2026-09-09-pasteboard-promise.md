# 検証: file promise は copy & paste に使えるか(2026-09-09)

## 背景

KaitoFinder は書庫内のファイルを Finder や他アプリへ **drag & drop** と
**copy & paste** の両方で取り出す。drag は `NSFilePromiseProvider` が定石だが、
paste でも同じ promise が使えるなら、巨大な entry を pasteboard へ置くだけで
展開せずに済む。ここを設計前に実測で確定させた。

## 方法

`scratchpad/spike/` に 2 本の実行ファイルを作り、別プロセス間で
`NSPasteboard.general` を受け渡した。

- writer: `NSApplication` を `.accessory` で起動し、pasteboard へ置いた後
  run loop で生存し続ける。2 モードを持つ。
  - `promise`: `NSFilePromiseProvider(fileType:delegate:)` を `writeObjects`
  - `lazyurl`: `NSPasteboardItem` に `setDataProvider(_:forTypes: [.fileURL])`
- reader: 貼り付ける側を模し、`readObjects(forClasses: [NSURL.self])` と
  `readObjects(forClasses: [NSFilePromiseReceiver.self])` の両方を試す。

環境は macOS 27.0 (26A5425a) / Xcode 27 / Swift 6.4 / Apple Silicon。

## 結果 1: promise は pasteboard に載るが、受け取れない

`NSFilePromiseProvider` を `NSPasteboard.general` へ書くこと自体は成功し、
型も期待どおり並ぶ。

```
com.apple.NSFilePromiseItemMetaData
com.apple.pasteboard.promised-file-name
com.apple.pasteboard.promised-suggested-file-name
com.apple.pasteboard.promised-file-content-type
Apple files promise pasteboard type
com.apple.pasteboard.NSFilePromiseID
```

受け側でも `NSFilePromiseReceiver` は 1 件構築でき、`fileTypes` も
`["public.plain-text"]` と正しく読めた。しかし実際に受け取ろうとすると
**AppKit が例外で拒否する**。

```
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
reason: 'receivePromisedFilesAtDestination:options:operationQueue:reader:
can only be called during -prepareForDragOperation:, -performDragOperation:,
and -concludeDragOperation:.'
```

同時に `readObjects(forClasses: [NSURL.self])` は `FILEURL_NONE` で、
promise だけを置いた pasteboard には file URL が一切無い。

**結論**: `NSFilePromiseReceiver` は drag 操作中しか使えないという API 契約が
AppKit 側で強制されている。paste の受け側は原理的に promise を受け取れないため、
**copy & paste に file promise は使えない**。これは Finder の実装都合ではなく
AppKit の契約なので、Finder に限らずどの貼り付け先でも同じ。

## 結果 2: 遅延 file URL は動くが、遅延にならない

`.fileURL` を `NSPasteboardItemDataProvider` で遅延供給する方式は、受け側から
正しく読めた。

```
FILEURL_OK: [".../kaitofinder-spike/spike-lazyurl.txt"]
FILEURL_CONTENT: materialized by lazy fileURL data provider
```

ただし **reader を一切起動しなくても、writer が pasteboard へ置いた直後に
`provideDataForType(public.file-url)` が呼ばれた**。2 秒後には既に実体化済みで、
16 秒待っても呼び出しは 1 回のまま。system 側(universal clipboard、
pasteboard の派生型生成、clipboard 監視)が即座に引き取るためで、
`NSFilenamesPboardType` や `Apple URL pasteboard type` が派生型として
並んでいることとも整合する。

**結論**: `.fileURL` の遅延供給は「書式としては遅延」でも「実際には即時」。
遅延を前提にした設計(巨大 entry を copy しても展開しない)は成立しない。

## 設計への反映

- **drag out**: `NSFilePromiseProvider`。実際の drop 先で初めて展開されるので
  遅延が効く。これは従来どおり正解。
- **copy out**: temp ディレクトリへ**明示的に展開**し、実 file URL を
  pasteboard へ置く。遅延で得られるものが無い以上、遅延を装わず、
  進捗表示とサイズ上限の確認を伴う明示的な展開として設計する。
- copy 時の展開先は `url(for: .itemReplacementDirectory, appropriateFor:)` では
  なく、アプリ専用の temp サブディレクトリに置いて寿命を自分で管理する
  (pasteboard の寿命はアプリより長い場合がある)。

## 未確認事項

`osascript` に Accessibility のキー送信権限が無く(エラー 1002
「osascript にはキー操作の送信は許可されません」)、実際の Finder への
⌘V を自動では発火できなかった。ただし結果 1 は AppKit の契約違反例外という
より強い根拠であり、Finder の挙動に依存しない。手動で確認する場合は
`scratchpad/spike/promise_writer promise` を起動したまま Finder で ⌘V し、
何も貼り付かないことを見ればよい。

> **Verification: can a file promise serve copy & paste? (2026-09-09)**
>
> KaitoFinder must move files out of an archive both by drag & drop and by copy &
> paste. `NSFilePromiseProvider` is the established answer for drag; this test
> settled whether the same promise can also serve paste, before the design
> depended on it.
>
> Two separate processes exchanged `NSPasteboard.general` on macOS 27.0 / Xcode 27
> / Swift 6.4 / Apple Silicon. A writer stayed alive in a run loop after placing
> either an `NSFilePromiseProvider` or an `NSPasteboardItem` with a lazy
> `.fileURL` data provider; a reader played the pasting app.
>
> **Result 1.** The promise reaches the pasteboard and the reader can even build an
> `NSFilePromiseReceiver` with the correct `fileTypes`, but actually receiving the
> files raises `NSInternalInconsistencyException`:
> `receivePromisedFilesAtDestination:options:operationQueue:reader: can only be
> called during -prepareForDragOperation:, -performDragOperation:, and
> -concludeDragOperation:`. A promise-only pasteboard also carries no file URL at
> all. Because AppKit enforces this contract, no paste destination — Finder or
> otherwise — can receive a file promise. **File promises cannot serve copy &
> paste.**
>
> **Result 2.** A lazy `.fileURL` data provider does work, but it is not lazy in
> practice: `provideDataForType(public.file-url)` fired immediately after the
> write, with no reader running at all, and only once thereafter. The system
> (universal clipboard, derived-type generation, clipboard observers) pulls it at
> once, which matches the derived `NSFilenamesPboardType` and
> `Apple URL pasteboard type` appearing alongside it.
>
> **Design consequences.** Drag-out keeps `NSFilePromiseProvider`, where laziness
> genuinely pays off at the real drop destination. Copy-out instead extracts
> explicitly into a temp directory and puts real file URLs on the pasteboard —
> since laziness buys nothing, it is designed as an explicit extraction with
> progress reporting and a size check, into an app-owned temp subdirectory whose
> lifetime the app manages, because a pasteboard can outlive the app.
>
> **Not confirmed.** `osascript` lacks Accessibility permission to send keystrokes
> (error 1002), so a real ⌘V into Finder could not be triggered automatically.
> Result 1 rests on an AppKit contract violation, which is stronger evidence than
> one Finder observation and does not depend on Finder's behavior. To confirm by
> hand, leave `promise_writer promise` running and press ⌘V in Finder: nothing
> pastes.
