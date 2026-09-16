# クラッシュ・強制終了で残る作業ディレクトリの台帳と回収(Wave L、design §12-5)— 2026-09-16

## 変更

公開の作業コピー `.KaitoFinder-add-<UUID>/` と作成の仮出力 `.KaitoFinder-new-<UUID>/` は、作る前に
`PendingWorkRegistry`(`~/Library/Application Support/KaitoFinder/pending-work.json`、atomic 保存、
プロセス内は `Mutex`)へ記録し、作った後に dev/ino を記録し、`defer` の削除の後に台帳から外す。
起動時(`applicationWillFinishLaunching` → `startLaunchSweeps()`)に台帳に残った項目を回収する。
回収するのは、自分の命名規則で始まり、`lstat` がディレクトリ(symlink でない)で、記録した dev/ino と
一致する項目だけ。条件に合わない項目は消さずに台帳から外す。台帳が壊れていれば空として扱う。
台帳の保存に失敗しても本来の公開・作成は止めない(台帳は保険)。

テストプロセスは `TestProcessSetup` で台帳を `$TMPDIR/KaitoFinderTests-<pid>/pending-work.json` に
向け、ユーザーの台帳を触らない(`PendingWorkRegistry.shared` は `Mutex` 保護の差し替え可能な値)。
テスト host としての KaitoFinder.app 自身の起動は、テスト bundle が読み込まれる前に
`applicationWillFinishLaunching` を通るため、XCTest 環境変数がある場合は台帳の sweep を行わない
(`sweepsPendingWorkAtLaunch`。展開の一時領域の sweep は従来どおり)。最初の全件実行でこれに気づいた
— 実行後にユーザーの台帳が `[]` で作られていた。

## 検証

- `PendingWorkRegistryTests` 7 件(往復・壊れた JSON・クラッシュ相当の回収と symlink 先の保全・
  取り違え防止 4 種・起動経路)、`ArchiveEditTests` / `ArchiveCreationTests` に配線のテスト 4 件
  (公開前の gate で台帳に path があり、完了後に消える)。うち 4 件は修正前に失敗することを
  Codex の直接実行で確認。
- 全件 `xcodebuild test` 672 件・失敗 0(ガード追加後の再実行も 672 件・失敗 0。実行後にユーザーの台帳は作られない)。
- 実機(Debug): 台帳に (a) `.KaitoFinder-add-DEADBEEF`(中に `archive.zip` と外を指す symlink)、
  (b) `unrelated`(命名規則外のディレクトリ)、(c) `.KaitoFinder-new-STALE`(dev/ino が不一致)を
  登録してアプリを起動。(a) だけが消え、symlink 先の `outside/keep.txt`、(b)、(c) は残り、台帳は
  `[]` になった。
