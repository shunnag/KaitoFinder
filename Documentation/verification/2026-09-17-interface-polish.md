# 保存ダイアログとインターフェースの整理 — 2026-09-17

この記録の後、暗号化 On / Off の切り替えを再調整した。
現在は必要なときだけ入力欄を表示し、標準保存パネルを滑らかに伸縮させる。
[伸縮中の位置の安定化と検証](2026-09-17-encryption-content-stability.md) を参照。

## 変更と監査範囲

- 保存ダイアログ: 標準 `NSSavePanel` の付属フォームで、形式・圧縮レベル・パスワード・方式の
  ラベル列と入力列を統一。暗号化をオンにすると入力欄を展開し、オフでは余白も詰める。
  7z のファイル名暗号化も入力列に揃えた。文字入力中の不一致は同じフォーム内に表示する。
- パネル幅: フォームの外枠を伸縮可能にし、内側だけ必要な幅で中央配置する。
  固定幅のアクセサリを使ったときの AppKit の警告を解消した。
  付属フォームをパネルへ渡す前に初期表示を確定し、非表示欄を含む古い高さが
  表示直後に採用される問題も修正した。
- キーボード: 暗号化の解除や非対応形式への変更で、隠れるパスワード欄から可視部品へ
  フォーカスを移す。パスワードシートの初期入力先と入力順を指定し、動的なウインドウでは
  `autorecalculatesKeyViewLoop` を有効にした。
- 文書ウインドウ: `fullSizeContentView` とスクロールビューの自動インセットを使用。
  標準ツールバーのスペースで展開・編集・プレビューを分ける。展開のアイコンは
  `tray.and.arrow.down` に揃え、メニューバーと右クリックメニューにも共通の SF Symbols を付ける。
  パスバーには標準の高さと左右の余白を使い、一覧との間に標準の区切り線を置く。
- ようこそ画面: ドロップ領域をシステム色の面と細い実線の枠に整理。
  macOS 27 ではコンテナに追従する角丸 API を使い、26 では従来の角丸で描画する。
  キーボード・VoiceOver・ドラッグ操作、視差効果を減らす設定、コントラスト設定への対応を維持する。
- 設定: 前回整理した標準の設定用ツールバー、グループ、内容に合わせたウインドウサイズを再監査。
  入力フォーカスの自動再計算を追加した。
- ファイル選択・警告・進捗: 標準 `NSOpenPanel` / `NSAlert` / `NSProgressIndicator` の使用を確認。
  長いアーカイブ名や翻訳を含む描画検査を再実行し、独自の装飾を追加する必要がないことを確認した。

設計の根拠は Apple の
[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、
[Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)、
[Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/)。
標準部品の素材・余白・グループ化を使い、OS の外観とアクセシビリティ設定に追従する。

## 検証

実行環境は macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、Apple Silicon。
deployment target は macOS 26.0 を維持し、27 専用 API は availability で分岐する。
Release 実行ファイルの `LC_BUILD_VERSION` も `minos 26.0 / sdk 27.0` であることを確認した。
macOS 26 の実行環境はないため、26 上での描画・実操作は未確認。

- 対象テスト 36 件が成功。ログ: `/tmp/kaitofinder-interface-final-targeted.log`。
- 保存フォームは 26 言語 × 5 形式 × ライト / ダークを、暗号化の有無それぞれで描画・監査。
  設定は全 3 タブ、ようこそは両外観、パスワード・警告・進捗は全言語を再確認した。
- 実際の保存パネルで、暗号化のオン・オフ、入力中の検証、非対応形式への切り替え、
  Tab による確認欄への移動、非表示欄からのフォーカス移動、保存せずキャンセルする操作を確認。
  パネルの伸縮は AppKit の非同期更新完了を待って判定する。
  初回の全件実行で、表示直後の高さが必要な 119 ポイントに対して 279 ポイントになる
  順序依存を再現した。初期表示を確定する処理をパネルへの設定前に移し、表示直後のサイズも検査する。
- 文書ウインドウは 1040 × 600 と 600 × 300 ポイントで両外観を描画し、
  一覧の先頭行がツールバーやパスバーに隠れないことを確認。
- 保存パネル操作と文書ウインドウの確認を `Tools/verify_ui_integration.py` に追加した。
  実行方法は [UI 回帰テスト](../ui-integration-testing.md) を参照。
- Release ビルド成功。ログ: `/tmp/kaitofinder-interface-release.log`。
- 最終の全件テストは 709 件、失敗 0、skip 2、301.781 秒。
  ログ: `/tmp/kaitofinder-interface-verified-full.log`。
  保存パネルの初期サイズ・伸縮のテストも、全件を連続実行する条件で通過した。
  アクセサリ幅の警告と Auto Layout の制約競合は出ていない。
  skip は専用コマンドで検証する履歴のプロセス間確認と、アプリの前面化が必要な Quick Look。
  Quick Look の前面操作はこの環境では未確認。
- 最終の専用 UI 回帰コマンドは 17 件、失敗・skip ともに 0。
  メニュー・保存パネル・文書表示の 13 件と、履歴の登録・再オープン・消去・消去後の再起動を確認。
  ログ: `build/UIIntegrationVerification/e082b916-d86f-43e9-962c-88b3f0f1a383/`。
  初回は履歴データを消去できた後のメニュー表示待ちでタイムアウトした。
  動的メニューは同じ期限内で開き直して再構築を通すよう検証ヘルパーを修正し、
  最終状態の条件を変えずに全経路を再検証した。失敗時には項目・action・有効状態も記録する。
  この最終変更はテストコードのみで、影響するメニュー検証は専用コマンドで再実行した。

## プレビュー

| 画面 | ライト | ダーク |
|---|---|---|
| 保存フォーム | [画像](../../build/InterfaceReview/ja-save-panel-zip-light.png) | [画像](../../build/InterfaceReview/ja-save-panel-zip-dark.png) |
| 暗号化付き保存 | [画像](../../build/InterfaceReview/ja-encryption-save-zip-light.png) | [画像](../../build/InterfaceReview/ja-encryption-save-zip-dark.png) |
| 文書ウインドウ | [画像](../../build/InterfaceReview/archive-window-1040-light.png) | [画像](../../build/InterfaceReview/archive-window-1040-dark.png) |
| ようこそ | [画像](../../build/InterfaceReview/ja-welcome-light.png) | [画像](../../build/InterfaceReview/ja-welcome-dark.png) |

画像は AppKit の実ビューを描画したもの。保存の画像はアプリ側の付属フォームを示す。
暗号化の例は長い選択肢を確認するため ZipCrypto を選んでいる。アプリの既定は AES-256。
タイトルバーや一部の操作部品は非アクティブ時の表示になっている。
OS の合成によるガラスの背景効果や前面状態は、この画像だけでは評価できない。
