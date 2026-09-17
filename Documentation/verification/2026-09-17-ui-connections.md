# UI の接続確認と再発防止 — 2026-09-17

## 確認範囲と追加修正

「最近使った項目」が登録済みでも表示されなかった不具合を受け、宣言・ハンドラーだけの検査と、
ユーザーが実際に使う操作経路との差を確認した。

追加で、アプリ共通コマンドの有効状態に不整合があった。「新規アーカイブ」と
「アーカイブを展開」は選択パネル表示中も有効なままで、action は再入防止の guard で戻っていた。
実メニューからパネルを開いて `NSMenu.update()` を行うテストは、修正前に両方とも失敗した。
`AppDelegate.validateMenuItem` を操作の受付条件に合わせ、処理中の「記憶したパスワードをすべて削除」も
同様に無効化した。パネルのキャンセル後と処理終了後には再び有効になる。

| 対象 | 実行した確認 |
|---|---|
| アプリに登録された標準メニュー | Services / Window / Help が実際の main menu に属すること、Services provider と Info.plist の selector が一致すること |
| 新規作成・一括展開 | 実メニューの action から選択パネルが開くこと、パネル表示中・Services 経由の処理中の無効化、キャンセル・完了後の復帰 |
| パスワード削除 | 実メニューから注入したテスト保管庫を消去し、処理中と終了後の有効状態を確認 |
| 設定・ようこそ・隠しファイル | メニューを経由した表示・再利用・設定反映。既存の直接ハンドラー呼び出しのテストも実 action に変更 |
| ウインドウ一覧 | 二つの実ウインドウを追加し、メニューを表示して登録・改名・close による削除を確認 |
| 「このアプリケーションで開く」 | 実際の menu tracking 中に非同期処理を進め、アプリ項目が生成され、URL と action の送り先を持つことを確認 |
| ツールバーと responder chain | 実ツールバーからフォルダを作成し、メニューの action を実 responder chain へ渡して取り消し・やり直し。テキスト編集中の「すべてを選択」は文字列へ届くことを確認 |
| 選択なし・読み取り専用 | 実メニューとツールバーの validation、展開 action が選択項目／全項目を渡すことを確認 |
| 最近使った項目 | 実メニューの表示と再オープン。専用 bundle ID の別プロセスで登録・再オープン・消去・消去後の起動を確認 |

この範囲で、履歴以外の接続漏れは見つからなかった。Services の実 Finder メニューからの呼び出し、
外部アプリを起動しての「このアプリケーションで開く」、前面アプリ限定の操作は上の自動検査と区別する。

## 再発防止

- `ApplicationCommandIntegrationTests` に操作結果を検査するテストを追加した。
- `Support/MenuInteraction.swift` で実メニューの表示・自動 validation・action 実行を共通化した。
  動的メニューは Timer から開き、tracking 中に非同期処理が進むようにする。
- 別のメニューを構築する既存テストは、終了時にアプリの登録メニューを復元する。
- `Tools/verify_ui_integration.py` はランダムな専用 bundle ID でビルドし、履歴の各段階を
  別プロセスで検証する。通常アプリの履歴は消去しない。対象テストの未実行・skip も失敗にする。
  再オープンと消去は別起動に分け、文書の開閉に伴う履歴更新と消去の検査を混在させない。
- [UI の回帰テスト手順](../ui-integration-testing.md)を追加し、README の開発手順から参照した。

## 検証結果

- 全件テスト: 706 件、失敗 0、skip 2、262.801 秒。
  ログは `/tmp/kaitofinder-ui-integration-full.log`。
  skip は前面化が必要な Quick Look と、専用コマンドから実行する履歴のプロセス間検証。
  後者は下記の専用コマンドで別途通過した。
- 専用コマンド: メニュー等 11 件と、履歴の 4 回の起動に各 1 件、合計 15 件。失敗・skip ともに 0。
  独立した bundle ID で 2 回続けて通過した。ログは
  `build/UIIntegrationVerification/f68b7c97-f90a-4663-a93d-753f9affaefd/` と
  `build/UIIntegrationVerification/c9122a78-4526-4495-b399-4e1186a79b1c/`。
- Release ビルド成功。テスト用 ZIP を指定して起動し、文書ウインドウ 1 枚の表示と正常終了（exit 0）を確認。
  ログは `/tmp/kaitofinder-ui-connections-release.log` と
  `/tmp/kaitofinder-ui-connections-release-smoke.log`。
- 修正前の検出ログ: `/tmp/kaitofinder-ui-integration-before.log`。

前面時の main menu による「すべてを選択」「クイックルック」は既存の前面化テストへ接続した。
テストホストを前面化できない場合は skip となるため、この範囲の実機確認は残る。
