# 分割セット全巻の同一性と巻構成（M1）

検証環境: macOS 27.2、arm64。設計は [分割アーカイブの編集と保存時の書き込み](../pending/2026-09-23-split-archive-deferred-save.md) の M1。
依存: KaitoKit `ArchiveReader.volumeSet`（KaitoKit 03fd19b）、GyoshukuKit の分割 ZIP の拒否順と `ArchiveRewriter.volumeSet`（GyoshukuKit 4c8c882）。

## 変更

- `ArchiveVolumeLayout`: KaitoKit が連結した巻の順序・命名・長さ・入口（gate）と、巻サイズの推定
  （最後以外が同じ長さで最後が 0 より大きくそれ以下なら uniform、それ以外は uneven）。
- `ArchiveSetIdentity`: 全巻の {名前、親ボリュームの UUID、inode、size、mode、mtime} と、続きの巻名が存在しないこと。
  st_dev は再マウントで変わりうるため、ボリュームの UUID で照合する（取得できなければ st_dev）。
  開くときは KaitoKit が保持 fd から採った値と `lstat` の値を比べ、組み立て中の差し替えを拒否する。
- 同一性の照合は、session の open・読み取り・再読込・Undo、公開、別名で保存、一括展開後のゴミ箱の各所で全巻に広げた。
  一括展開の「展開後にアーカイブをゴミ箱に入れる」は、分割セットでは全巻を移す（途中で失敗したら残りは残す）。
- 編集可否は reader の `volumeSet` があれば `.splitArchive`（M0 の名前による判定も残す）。quarantine は巻の順に最初の値を採る。
- 起動時に RLIMIT_NOFILE の soft limit を min(hard, OPEN_MAX) まで上げる（KaitoKit は巻ごとに fd を保持する）。

## 自動検証

- build-for-testing 成功。`KaitoFinder.debug.dylib` に `ArchiveSetIdentity` のシンボルがあることを確認した。
- 対象 9 クラス（ArchiveSetIdentityTests、ArchiveSplitVolumeTests、ArchiveCapabilityInspectionTests、
  ArchiveBatchExtractionTests、ScenarioExternalChangeTests、ArchiveSaveAsTests、ArchiveUndoStackTests、ArchiveEditTests、
  ApplicationTerminationTests）: 179 件実行、失敗 0、skip 1。
- 全体: 906 件実行、skip 20、失敗 16（9 テスト）。失敗はすべて GUI 操作のテスト（ArchivePasswordUITests 6、
  ArchiveConflictUITests 1、ArchivePreviewSidebarTests 1、ArchiveTabTests 1）で、「シーンの状態遷移が時間切れ」
  「無効なメニュー項目」。GUI 以外の失敗はない。実行後に `swift Tools/verify_gui_session.swift` が
  "macOS is locked" を返した（実行中のロックは直接は確認していない）。M0 の全体実行では同じ 9 件が通っており、
  本変更は GUI の経路に触れていない。ロックを解除したセッションで 9 件を再実行し、結果をここに追記する（M6 の後）。

## GUI テストの再確認（2026-09-23、ロック解除後）

ロックを解除したセッションで GUI のクラスを再実行した。ArchivePasswordUITests（6 件）、ArchiveTabTests、
DeferredSaveUITests、ArchivePreferencesUITests、ArchiveBatchExtractionUITests は通った。
ArchivePreviewSidebarTests.testMenuToolbarAndKeyboardToggleTheActiveArchive と ArchiveTabSpringLoadingTests
（3 テスト）は、M0（4ec3d77）を別の作業ツリーで同じ時刻に実行しても同じく失敗したため、本ブランチの変更によらない
GUI 環境依存の失敗と判断した（M0 の全体実行時には通っていた）。ArchiveConflictUITests の 1 件は M3 の「保存」メニュー項目で
「スキップ」の Return が外れる退行で、M1 の時点ではロックによる失敗だった（a1ae9c6 では通る）。修正は別コミット。
