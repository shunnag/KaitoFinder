# タブ、書庫間ドラッグ、一括追加の検証

検証環境: macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、arm64。
macOS 26 はビルド対象だが、この環境では実機検証していない。

## 開き方

設定 › 一般 ›「アーカイブを開くとき:」を追加。26 言語に翻訳した。

| 選択肢 | 次に開く書庫 |
| --- | --- |
| macOSの設定に従う（既定） | システムのタブ設定に従う |
| 新しいタブ | 既存の書庫とタブにまとめる。最初の書庫はウインドウを開く |
| 新しいウインドウ | 独立したウインドウを開く |

Finder の関連付け、「開く…」、履歴、新規作成後の表示に共通。
設定の変更では既存のタブを再配置しない。同じ書庫の再オープンは既存文書を再利用する。
ウインドウとして開いた書庫も、標準のウインドウメニューで結合・分離・切り替えできる。

実装は初回表示直前だけ `NSWindow.tabbingMode` を切り替え、表示後は `.automatic` に戻す。
設定画面が前面にある状態でも、LaunchServices の open-documents event でタブに追加できることを確認した。
複数 URL を同時に開く event と、既存文書の再利用も検査した。
API の設定タイミングは [Apple の tabbingMode の説明](https://developer.apple.com/documentation/appkit/nswindow/tabbingmode-swift.property)に従う。

## ドラッグの規則と修正

| 操作 | 動作 |
| --- | --- |
| 同じ書庫の一覧内 | 移動。Option を押すとコピー |
| 別の書庫へ（別ウインドウ／別タブ） | コピー。元の書庫は変更しない |
| フォルダ上／ファイル上／一覧の空白上 | そのフォルダ／ファイルの親／書庫の最上位へ追加 |
| 親フォルダとその子を同時に選択 | 親に含まれる子は重ねて送らない |
| 受信失敗、名前の衝突 | 追加全体を中止。追加先の原本を変更しない |

実操作で、書庫間の受信中に発生するクラッシュを再現した。
`NSFilePromiseReceiver` が背景の OperationQueue で呼ぶ callback に、initializer の MainActor 制約が
暗黙に付いていた。修正前の実ドラッグでは次のスタックで SIGTRAP になった。

```text
queue: com.shunnag.KaitoFinder.receive
_dispatch_assert_queue_fail
_swift_task_checkIsolatedSwift
closure #1 in ArchiveIncomingFiles.init(receivers:)
```

callback を `@Sendable` と明示し、Mutex で管理している受信状態を背景スレッドから更新する。
また、親子を同時に選ぶドラッグでは子の file promise を作らないようにした。
多数選択でも各 provider が全選択を走査しないよう、選択中の祖先だけを調べる。

## 検証範囲

- 100 ファイルと、子ファイル・空フォルダを含むフォルダを別ウインドウへドラッグ。
  全内容、空フォルダ、元の書庫のハッシュ、追加先で一回の取り消しができることを確認。
- 同じ選択を、ドラッグ中に別のタブへ切り替えてドロップ。同じ確認を実施。
- CRC を壊した項目を含むフォルダと 100 ファイルをまとめてドラッグ。
  エラーを表示し、両方の書庫のハッシュ・追加先の世代・undo 履歴を変更しないことを確認。
- 1,000 ファイルを名前付きペーストボードから実際の `acceptDrop` へ渡し、指定フォルダへ追加。
  draggingInfo のみテスト用。全内容、処理中の二重ドロップ拒否、一回の undo、redo、`unzip -tqq` を確認。
- ZIP / tar / tar.gz / 7z / LHA の各形式へ 100 ファイルとフォルダを一括追加。
  全ファイルのバイト列、空フォルダ、既存ファイルの保存を確認。
- 既存の衝突・途中失敗・キャンセルのテスト、コピーアウト、表示、カスケード配置を再実行。
- 設定は 26 言語 × ライト／ダークで描画し、新しいプルダウンの全選択肢をレイアウト検査。
  日本語ライト、英語ダークのウインドウ画像も目視確認。

ドラッグの結合テストはテストアプリの `NSEvent` キューにだけ入力し、実際の
NSOutlineView のドラッグ開始、受け入れ判定、file promise の IPC と callback、文書の更新を通す。
単に provider の型やドロップ可否のフラグを検査するテストでは、今回のクラッシュを検出できなかった。

関連 83 テストは成功（失敗・skip とも 0）。ログ: `/tmp/kaitofinder-tabs-related-tests.log`。
ドラッグの結合 6 テストも成功。ログ: `/tmp/kaitofinder-tabs-bulk-drop-tests.log`。
保存パネルの全 10 テストも成功。ログ: `/tmp/kaitofinder-tabs-password-final.log`。
Release ビルド成功。ログ: `/tmp/kaitofinder-tabs-release-build.log`。

結合検査では、ドラッグ後に前面の保存パネルを開き、「視差効果を減らす」を使うと
パスワード欄のフォーカスが外れる問題も再現した。表示高さは正しく、入力先だけが
`NSAccessoryViewWindow` 自身へ戻っていた。XPC ホスト更新後の main queue でも
フォーカスを引き渡すように修正。キャンセル・再切り替え・確認欄への移動後は引き渡さない。
前面状態を回帰テストへ明示し、失敗していたドラッグ直後の手順と保存パネル全 10 テストを通した。
サイズとアニメーションの計算は変更していない。
修正前の結合ログは `build/UIIntegrationVerification/4f90bd46-c20f-45b2-b945-97b9306414b2/` と
`build/UIIntegrationVerification/7322f8ac-e29d-4fe0-9c7d-0ed9e81d6526/` に残る。

修正後の最終結合検証は **30 テスト成功、失敗・skip とも 0**。
実メニュー・タブ・ドラッグ・保存パネルの 26 テストと、履歴の記録／再起動して再オープン／
消去／再起動して消去を確認する 4 テストを通過した。
ログ: `build/UIIntegrationVerification/eeec6241-61a4-49c7-9022-3886b835c02d/`。

再発検査は `Tools/verify_ui_integration.py` に `ArchiveTabTests` と `ArchiveDropIntegrationTests` を組み込み、
既存の実メニュー・保存パネル・履歴再起動の検査とともに実行する。
GUI テストは画面ロックを解除した macOS 上で直列に実行する。
