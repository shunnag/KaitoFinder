# 保存パネルの伸縮アニメーション — 2026-09-17

この記録の後、伸縮中にフォーム全体がスライドする問題を修正した。
現在の方式と追加検証は [内側の位置の安定化](2026-09-17-encryption-content-stability.md) を参照。
以下は初回の伸縮アニメーション実装時の記録。

暗号化をオンにするとパスワード・確認・形式に応じた暗号化設定を表示し、オフで畳む。
`NSAnimationContext` の 0.24 秒の ease-in/ease-out で高さと透明度を変え、
標準 `NSSavePanel` が内容に合わせて大きさを変える。固定配置方式を置き換えた。

## 表示と操作

- フォームは自然な高さで上端に配置し、伸縮中に入力欄を押し潰さない。外枠で描画をクリップする。
- 閉じる途中の欄はフェードが完了してから取り除く。パネルには遷移先の必要な高さを伝える。
- 連続操作は現在の表示状態から再開し、古い完了通知は無視する。
- オンでは展開後にパスワード欄へフォーカスを移す。待っている間に別の入力先を選んだ場合は奪わない。
  オフ・非対応形式では隠れる入力欄からフォーカスを外す。
- 入力済みの文字と暗号化方式は保持し、オフの保存設定にはパスワードを渡さない。
- 検証メッセージの有無で入力中のパネルを動かさない。
- 「視差効果を減らす」が有効な場合は即時に切り替える。
- 初期表示はアクセサリをパネルに渡す前に決め、不要な空間が初回だけ残る問題を防ぐ。

アクセサリの高さを固定する制約や、フォームの上下を外枠に固定する制約を使わない。
AppKit が高さゼロと判断して固定の代替制約を挿入しないよう、外枠に正の最小高さを設けた。
幅は保存パネルに追従し、内側のフォームを中央に配置する。

## 検証

macOS 27.0 / Xcode 27.0 で実施。macOS 26 の実行環境はこのホストにない。

- 通常の保存パネル、文書に接続したシート、「視差効果を減らす」の実画面テスト三件が成功。
  `CALayer.presentation()` の中間の高さを採取し、展開・縮小と最後のパネルサイズを確認した。
  ログ: `/tmp/kaitofinder-encryption-animation-live.log`。
- フォーカス、Tab、入力値の保持、入力検証、途中での逆転、非対応形式への変更、展開途中のキャンセルも検査する。
- 全 711 テストを実行し、失敗 0・skip 2、301.721 秒で完了。
  ログ: `/tmp/kaitofinder-encryption-animation-full.log`。
  skip は履歴のプロセス分離テストと前面化が必要な Quick Look。履歴は専用コマンドで別途実行し、
  前面での Quick Look はこの環境では未検証のままとする。
- 保存・新規作成・レイアウトの関連 39 テストも上記の全件実行内で成功。
  26 言語 × 全 5 形式 × ライト / ダークで表示を確認。アクセサリの制約競合・高さゼロの警告なし。
- 専用 UI 回帰コマンドは 19 件成功、失敗・skip ともに 0。
  実際のメニュー操作・保存パネルに加え、最近使った項目の登録・再起動後の再表示・消去・再起動後の消去確認を含む。
  ログ: `build/UIIntegrationVerification/9bd94836-0fb4-4610-89a5-e436049140cc/`。
- Release ビルド成功。ログ: `/tmp/kaitofinder-encryption-animation-release.log`。
  `LC_BUILD_VERSION` は minos 26.0 / SDK 27.0。

## 描画

[オフ](../../build/EncryptionAnimationReview/save-encryption-off.png) /
[オン](../../build/EncryptionAnimationReview/save-encryption-on.png)

実際に表示した保存パネルの AppKit アクセサリを描画した静止画。
アニメーションの中間状態は上記の表示レイヤーの計測で確認している。

## 参照

- [NSSavePanel.accessoryView](https://developer.apple.com/documentation/appkit/nssavepanel/accessoryview)
- [NSAnimationContext](https://developer.apple.com/documentation/appkit/nsanimationcontext)

SDK の `NSSavePanel.h` に、アクセサリのフレーム変更（高さのアニメーションを含む）が
パネルへ反映されることが明記されている。`NSAnimation.h` には進行中のプロパティを
`animator()` で再指定すると現在値から再開し、duration 0 で停止する仕様がある。
