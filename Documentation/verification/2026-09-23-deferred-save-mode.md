# 保存時にまとめて書き込むモード（M3）と保留中の項目の読み取り（M4）

検証環境: macOS 27.2、arm64。設計は [分割アーカイブの編集と保存時の書き込み](../pending/2026-09-23-split-archive-deferred-save.md) の §2・§5 と付録 2。
反証レビューへの対応の詳細は [M3 / M4 の修正記録](2026-09-23-m34-corrections.md)。

## 事前の実測（実際の .app と KaitoFinder の Info.plist）

- 役割 Viewer の文書では、編集済みでも AppKit の既定の検証が `saveDocument:` を無効にする。保存と戻すの有効化は
  `validateUserInterfaceItem` で明示する。有効にすれば ⌘S は保存パネルなしで `save(to:ofType:for:completionHandler:)` に届く。
- `writableTypes(for:)` は保存・閉じるときの保存・終了時の保存のどれでも参照されない。
- super を呼ばない保存では、入口で得た `changeCountToken(for: .saveOperation)` による `updateChangeCount(withToken:for:)` と、
  `fileModificationDate` の更新の両方が必要（片方だけでは次の保存で「別のアプリケーションで変更」の警告、
  または編集済みのまま）。`.changeCleared` は保存中の編集まで消す。
- 終了時は reviewUnsavedDocuments → canClose → 保存 → 文書を閉じて一覧から除く → applicationShouldTerminate の順。
  確認済みの文書は applicationShouldTerminate の時点で一覧にないため、後始末は別の台帳で待つ。`close()` は二度呼ばれうる。
- タブには編集済みの印が出ない（閉じるボタンの点と「ウインドウ」メニューの「•」は出る）。

## 実装の要点

- 設定「変更の書き込み」（すぐに書き込む / 保存時にまとめて書き込む）。既定はすぐに書き込む。文書を開いた時点で固定。
- 保存時モードでは、追加・削除・改名・移動・新規フォルダ・書庫内コピー・パスワード変更をメモリ上の予約にする。
  基底の項目は (index, 期待名, 世代) で参照し、世代が合わなければ拒否する。表示は基底と予約の投影から作る。
  予約は NSUndoManager で取り消せ、ディスクには保存まで触れない。
- 追加元は Application Support の staging へ clone / コピーし、変更禁止フラグと ACL は外す。所有者の死んだ staging は
  ゴミ箱へ移して知らせる。
- 保存は基底の項目と予約から再生計画を作り（削除 → 循環を一時名で断った改名 → 追加）、既存の単一ファイルの公開経路で
  一回だけ書き込む。予約が打ち消し合って空なら書き込まない。別名で保存は予約を含めて書き出す。戻すは予約を捨てる。
- M4: payload は revision と origin を持ち、保存時モードでは名前による引き直しをしない。保留中の追加は staging から、
  改名した基底の項目は reader から投影上の名前で取り出す。混在フォルダは両方を合わせる。取り出し中の staging は lease で保持する。
- 分割セットは M3 / M4 では引き続き読み取り専用（M5 で保存に対応）。

## 自動検証

- build-for-testing 成功。
- 保存時モードの新規クラス（DeferredSaveModelTests、DeferredSaveDocumentTests、DeferredSaveExtractionTests、
  DeferredSaveAttributeTests、DeferredSaveCorrectionTests、DeferredSaveStagingCorrectionTests）と、既存の
  ArchiveEditTests、ArchiveUndoStackTests、ArchivePasswordTests、EntryTreeTests、ArchivePreferencesTests、
  ApplicationTerminationTests、ArchiveSaveAsTests、ExtractionTests、DragCopyOutTests、QuickLookOpenTests、
  ArchiveThumbnailTests、ArchiveImportConflictTests、WordingAcceptanceTests: 失敗 0。
- 「dirty にならない」前提の既存テストはモード別にし、すぐに書き込むモードの期待は変えていない。
- 反証レビュー（5 観点、各指摘を 2 人が検証）で 20 件の指摘を受け、重大 3 件（改名したフォルダの下へ元の場所に戻す移動が
  投影の名前規則で打ち消される、外部変更の「破棄して読み直す」が保存の状態機械の外で動く、staging が変更禁止フラグと ACL を
  引き継ぐ）を含む 17 項目を修正した。
- DeferredSaveUITests（GUI）は画面ロック中のため未実行。ロック解除後に実行する（M6 の後）。
