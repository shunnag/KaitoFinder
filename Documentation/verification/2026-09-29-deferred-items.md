# 2026-09-29 後回しにしていた整理項目の処理記録（KaitoFinder）

2026-09-28 のコード品質レビューで見送った項目を、Fable（orchestrator と advisor）と Codex の相談の上で「実施」か「据え置き（理由付き）」に振り分けた記録。
判断基準は「KaitoKit / GyoshukuKit を他の人や AI が使うときに使い勝手が良いのはどちらか」（app は両 library の利用者として同じ基準で見る）。

## 実施

| 項目 | 内容 | commit |
|---|---|---|
| KF-C F8 | 四つの JSON 台帳の排他と読み書きを `LockedJSONFile` と `VolumePublishFS.withSupportLock` に | dc6656e |
| KF-B F17 | 即時 / 保存前 mode の移動計画を `ArchiveMovePlanning` に、両 mode の差を固定する test | e0cbc6c |
| KF-T F20 (a) | `ArchiveEntryControlsTests` を削除・改名・移動の三つの class に分割 | cf9798d |
| 追随 | `fix/cancellation-followups`（header プローブ・分割保存の取消し）を現在の配置に移植 | fda9570 |
| 軽微 | 「旧名」注釈 23 件、二重名（`ArchivePasswordLayout`・`ExtractionProgressSheet.revealDelay`・`Stamp`）、`ArchiveFormRow` / `ArchiveAccessoryLayout` の file 分割 | b851d34 |
| KF-B F7 | テスト専用の薄い wrapper を型の file 内の `#if DEBUG` に（可視性は広げない。`rewriteNotice` は xcstrings の key を参照するため常時 compile） | b851d34 |
| KF-C F17 (b) | `publish` の ledger を必須にし、1,000 単位の擬似 progress の経路を削除。test は `ArchiveWriteProgress.forTesting` で実 ledger を渡す（fallback 経路の合計値を見ていた 4 test の期待値を実 ledger の値に更新） | 3f034b2 |
| KF-C F9 step 2 | updater の四経路（圧縮 tar・tar・LHA・7z）を `runUpdaterRoute` の一つの骨格に（`sending` reader は `Result` で受け、closure に捕まえない） | 3f034b2 |
| KF-T F20 (b) | `ArchiveEditTests` を `ArchiveNewFolderEditTests`・`ArchiveMoveEditTests` と分け、fixture を Support の `EditTestFixture` に | 3f034b2 |
| KF-A F8 | Quick Look の panel 制御・監視・data source を `ArchiveQuickLookCoordinator` に | 3f034b2 |
| 文書 | 次版 release notes の下書き `Documentation/pending/release-notes-next.md` | 265d9fa |

## 据え置き（理由付きで閉じる）

| 項目 | 理由 | 合意 |
|---|---|---|
| KF-A F14 (b) `ResizeTransition` | 保存 panel の XPC sheet の animation は目視でしか検証できず、struct 化の利得が検証費用に釣り合わない | Fable・Codex 一致 |
| KF-T F14 stage 2 `interface(...)` の共通化 | 各 file の 5〜7 行の helper は読みやすさを保っており、options struct の抽象を足す利得が小さい。stage 1 で teardown の不揃いは直っている | 一致 |

## 検証

ローカルの全 suite（1,714 件。失敗は既知の `ArchivePreviewSidebarTests` 1 件のみ）、Quick Look 関連 class の単独実行。CI は無い。GUI driver（`Tools/verify_ui_integration.py`・`verify_finder_interactions.py`）は利用者が実行する。
