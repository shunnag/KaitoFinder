# 分割巻を文書として開く（M1b）

検証環境: macOS 27.2、arm64。設計は [分割アーカイブの編集と保存時の書き込み](../pending/2026-09-23-split-archive-deferred-save.md)。

## 実測した問題

KaitoFinder の Info.plist を写した実際の .app と標準の NSDocumentController で、`x.7z.001` は
`typeForContents` が動的 UTI（`dyn.ah62d4rv4ge8xaqbv`）を返し、`documentClass(forType:)` が nil になり、
「この種類のファイルは開けません」で失敗した。「開く」パネル、ようこそのドロップ、ウインドウへのドロップ、
「アーカイブを展開…」のパネルはいずれも宣言型で絞るため、番号付きの分割巻（`.7z.001`、`.tar.gz.001`、
`.zip.001` など）はアプリ内から開けなかった。`.z01` は既存の ZIP 型（`public.zip-archive.first-part`）への準拠で開ける。

## 変更

- 拡張子タグを持たない内部の型 `com.shunnag.KaitoFinder.split-volume`（Viewer、LSHandlerRank None）を宣言した。
  Finder・LaunchServices の関連付けは増えない（design.md の「.001 は関連付けの対象外」を維持）。
- `ArchiveDocumentController`（`main()` で NSApplication より前に生成し、shared であることを precondition で確認）:
  システムの型に文書クラスがなく、名前が KaitoKit の `ArchiveVolumeSet.parse` で分割巻と判定できるときだけ内部の型を返す。
  `openDocument` は途中の巻を実在する入口（番号付きは `.001`、ZIP は `.zip` / `.zipx`）へ揃えてから開くので、
  同じセットが二つの文書にならず、最近使った項目も入口で記録される。素の tar の `t.tar.002` も `.001` のセット全体として開く。
- 「開く」と「アーカイブを展開…」のパネルは型で絞らず、delegate が宣言型と分割巻の名前だけを有効にする。
  ようこそ・ウインドウへのドロップも同じ判定を使う。一括展開は入口へ揃えて重複を除く。
- 編集の拒否（M0 / M1）は変えていない。

## 自動検証

- build-for-testing 成功。`ArchiveDocumentController` のシンボルを確認した。
- 対象 8 クラス（ArchiveDocumentControllerTests、DocumentTypesTests、ArchiveDocumentOpeningTests、WelcomeWindowTests、
  ArchiveBatchExtractionTests、ArchiveSplitVolumeTests、RecentDocumentsPersistenceTests、RecentDocumentsMenuTests）:
  94 件実行、失敗 0、skip 3（Quick Look の前面表示を要する既存テスト。ロック中の環境で skip する）。
- 途中で直したテストの誤り: `.z01` は既存型で開けるので内部の型に置き換えない。最近使った項目は symlink を解決した
  パス（/private/var）で記録される。`NSDocumentController()` は既存の shared を返すため、システムの型は
  `URLResourceKey.contentTypeKey` で得る。
- 全体（927bc26 のビルド）: 919 件実行、skip 20、失敗 16（9 テスト）。失敗は M1 の記録と同じ GUI 操作の 9 件だけで、
  画面ロック中の実行による。ロックを解除したセッションで再実行する（M6 の後）。
