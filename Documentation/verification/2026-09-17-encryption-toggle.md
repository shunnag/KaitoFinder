# 暗号化 On / Off の切り替え — 2026-09-17

この記録は途中段階の固定配置方式。現在は必要なときだけ項目を表示する方式へ変更した。
最新の実装・検証は [伸縮アニメーション](2026-09-17-encryption-animation.md) を参照。

保存パネルを伸縮させる方式では、パネルと入力欄が別々に動いて切り替えが落ち着かないため、
ZIP / 7z の暗号化欄は常に同じ位置に置く構成へ変更した。
Off では標準の無効なコントロールとラベル色を使い、On で入力可能にする。
On / Off だけではアクセサリのサイズ変更を要求しない。
パネル全体・形式・圧縮レベル・チェックボックス・パスワード欄の位置を保つ。

On にするとパスワード欄へフォーカスを移す。Off では無効な入力欄からフォーカスを外し、
入力検証メッセージを消す。入力済みの値は保持するが、Off の保存設定にはパスワードを渡さない。
tar / tar.gz / LHA への形式変更では、従来どおり非対応の入力欄を隠して説明を表示する。

## 検証

macOS 27.0 / Xcode 27.0 で実施。

- 関連 37 テストが成功。保存パネル・新規作成・全言語レイアウトを確認。
  ログ: `/tmp/kaitofinder-encryption-toggle-tests.log`。
- 実際の保存パネルで On / Off を連続操作し、パネルのフレームと各コントロールの位置が
  同一であることを検査。Tab、入力値の保持、エラーの解除と再表示、Off での保存検証、
  非対応形式への切り替え、キャンセルも確認した。
- 26 言語 × 全 5 形式 × ライト / ダークの描画監査を通過。
  アクセサリ幅の警告、Auto Layout の制約競合なし。
- UI 回帰コマンドは 17 件、失敗・skip ともに 0。
  ログ: `build/UIIntegrationVerification/d7275f64-17f6-4262-a858-3cf62d84dd75/`。
- Release ビルド成功。ログ: `/tmp/kaitofinder-encryption-toggle-release.log`。

## 実際の保存パネル内のフォーム

[Off](../../build/EncryptionToggleReview/save-encryption-off.png) /
[On](../../build/EncryptionToggleReview/save-encryption-on.png)

AppKit の実ビューを描画したもの。On の画像は Tab で確認欄へ移動した状態。
