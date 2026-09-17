# 設定画面の整理 — 2026-09-17

## 変更

macOS の設定用ツールバー (`NSWindow.ToolbarStyle.preference`) を使い、一般 / 圧縮 / 展開を切り替える。
関連項目をシステム色の枠でまとめ、左側のラベルと右側の操作部品を整列した。
展開は「保存場所とフォルダ作成」「展開後の動作」の二組に分けた。
圧縮は ZIP / tar.gz / tar の設定をそれぞれまとめ、レベルの数値を控えめな等幅数字にした。

幅は全タブで共通、高さは各タブの内容に合わせる。上辺を保ってサイズを変え、画面下端を越える
場合はウインドウを上へ移す。「視差効果を減らす」が有効な場合はアニメーションしない。
既存の設定値・翻訳・即時保存・他の画面から変更した際の同期は引き継ぐ。

構成の参考: [Apple Human Interface Guidelines — Settings](https://developer.apple.com/design/human-interface-guidelines/settings)。

## 描画と操作の確認

- 設定関連の 9 テストが成功。設定保存、他画面との同期、設定メニュー、実ツールバーの action による切り替えを確認。
- 26 言語 × 3 タブ × 2 外観の 156 描画で、文字と部品のはみ出しなし。
  展開の全選択肢、スライダーの数値変更、タブ往復後のサイズも検査した。
- 画面下端近くに置いたウインドウを実ツールバーから切り替え、全体が画面に収まることを確認。
- 最終の対象テストログ: `/tmp/kaitofinder-settings-verified-layout.log`。Auto Layout の制約競合なし。
- UI 回帰検証コマンド: 15 件、失敗・skip ともに 0。
  ログ: `build/UIIntegrationVerification/d87d77dc-5da3-403a-a6e2-9cc2e161bedf/`。
- 全件テスト: 707 件、失敗 0、skip 2、297.953 秒。
  ログ: `/tmp/kaitofinder-settings-full.log`。
  skip は専用コマンドで別途通過した履歴のプロセス間検証と、前面化が必要な Quick Look。
  Quick Look の前面操作はこの環境では未確認。
- Release ビルド成功。ログ: `/tmp/kaitofinder-settings-final-release.log`。
  最終調整で旧式 NSBox 専用の非推奨 setter を取り除き、設定の 9 テストと Release を再確認した。
  保存した 12 枚のウインドウ画像は、setter 除去前後で同一だった。

日本語のウインドウ全体（ツールバーを含む）は次の大きさ。

| タブ | 幅 × 高さ（ポイント） | プレビュー |
|---|---|---|
| 一般 | 609 × 284 | [ライト](../../build/SettingsReview/ja-settings-general-light-window.png) / [ダーク](../../build/SettingsReview/ja-settings-general-dark-window.png) |
| 圧縮 | 609 × 580 | [ライト](../../build/SettingsReview/ja-settings-compression-light-window.png) / [ダーク](../../build/SettingsReview/ja-settings-compression-dark-window.png) |
| 展開 | 609 × 330 | [ライト](../../build/SettingsReview/ja-settings-extraction-light-window.png) / [ダーク](../../build/SettingsReview/ja-settings-extraction-dark-window.png) |

プレビューは AppKit の実ビューをテスト内で描画したもの。テストホストが非アクティブなため、
タイトルバーと操作部品は非アクティブ時の表示になっている。
