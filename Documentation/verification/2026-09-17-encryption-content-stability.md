# 保存ダイアログの伸縮と揺れの修正 — 2026-09-17

暗号化の入力欄を必要なときだけ表示し、保存パネルの高さを滑らかに変える。

## 前回の検査で見逃した原因

保存パネルのアクセサリは別プロセスのホストを介して表示される。
前回はローカルの最外側の presentation layer だけを計測し、0 pt の結果を得ていた。
画面収録による確認では、実ウインドウとホストの高さが別々に更新され、表示された行が動いていた。
そのため、前回のローカルレイヤーの計測結果を、実画面の安定性の証明として扱わない。

フォームの上端を決める基準を、遅れて更新されるホストの bounds から、実際の
`NSSavePanel.frame` とアクセサリ以外の高さへ変更した。
パネルのリサイズ通知でも直ちに配置を補正する。内側の位置にはアニメーションを付けない。

一覧付きの保存パネルは、アクセサリを小さくすると一覧の領域を広げ、ウインドウを縮めなかった。
この場合はウインドウの高さも更新し、通常パネルは上端、シートは中央を基準に伸縮させる。
中間の高さは通常パネルでは整数ポイント、シートでは増分を偶数ポイントに揃える。

描画可能範囲を決めるホストよりサイズ要求が先行すると、位置の補正が正しくても先頭行が欠けた。
実パネルとホストの両方に反映された高さから 8 pt より先へ進めないようにし、上余白より小さい差に抑えた。
0.24 秒の ease-in/ease-out を目標とし、ホストの反映が遅れた場合は目標サイズに達するまで更新を続ける。
透明度も実際に反映する高さへ合わせる。アクセサリ自身の早すぎるクリップを外し、
一覧付きパネルでは表示領域を先に更新してからアクセサリへ反映する。

手動リサイズや一覧の開閉では基準の高さを測り直す。画面の高さを超える場合は即時に切り替え、
一覧の領域調整を標準パネルに任せる。世代番号で古い更新を無効にし、完了・キャンセル・解放時には
display link を停止する。

## 再発防止

`ArchivePasswordUITests.testSavePanelResizesWithoutSlidingContents` は通常パネル・シートと
保存先の一覧の開閉を組み合わせた 4 条件で、実際のチェックボックスを操作する。

- 形式・圧縮レベル・暗号化の行を、実ウインドウの表示領域へ変換して計測する。
- 行とウインドウの基準位置の許容差を 0.01 pt とし、1 ピクセルの往復を見逃さない。
- 幅、原点、途中の高さ、単調な伸縮、アプリが追加するクリップの影響も検査する。
- 各コントロールの visibleRect も検査し、ホスト側の描画範囲から文字が欠けることを検知する。
- 表示直後の動きが収まってから基準位置を取り、切り替え後 650 ms を観測する。
- 一覧の初期状態は別プロセスへ伝わる保存値で指定し、必ず元の値へ戻す。

旧来のホストの高さを使う計算へ一時的に戻したところ、同じ検査は 8 回の切り替えすべてで失敗し、
最大 22 pt のずれを検知した。その後、修正版を復元した。
ログ: `/tmp/kaitofinder-regression-old-host-height.log`。

既存の実パネルのテストは、フォーカス、Tab 移動、入力値の保持、途中の反転、非対応形式、
キャンセル、「視差効果を減らす」を確認する。追加した
`testExpandedSavePanelRebasesAfterNativeResizeAndFitsTheScreen` は手動リサイズ後の切り替えと
画面内への収まりを検査する。

## 実描画の確認

`Tools/verify_save_panel_animation.py` と `Tools/record_save_panel.swift` を追加した。
ユーザーが許可した画面収録を使い、専用 bundle ID の KaitoFinder 検証ウインドウだけを記録する。
画面全体や音声は記録せず、通常アプリの設定や履歴は変更しない。
通常のテストでは録画処理は動かず、画面収録の許可も不要。

録画中は ScreenCaptureKit の標準動画出力を使用し、画像化と比較は録画後に行う。
主スレッドで Core Graphics のウインドウ情報を高頻度に取得すると描画を止めるため、
検査の観測自体で動きを変えないよう、この方式を使わない。

位置が安定した後にも、表示の切り取りで先頭行が数フレーム欠けることを録画で検出した。
間引いた一覧画像だけで判断せず、動画の各フレームを比較して最終確認する。

最終確認はディスプレイ上の固定座標・実ピクセル倍率の収録を使用した。
フィルターに検証アプリのウインドウだけを含め、対象外の領域は映さない。
ウインドウに追従する収録方式では単発の差が残ったため、その結果だけで実画面の安定性を判定せず、
固定座標の収録で照合した。

## 最終結果

- 関連 41 テストが 0 failures / 0 skipped（67.908 秒）。
  `ArchivePasswordUITests` 10 件、`ArchiveCreationUITests` 18 件、`LayoutOverflowTests` 13 件。
  4 条件の On / Off で、行・アクセサリ原点・パネルの基準位置のずれはすべて 0 pt。
  ホストの描画範囲による行の欠けも 0 pt。
  ログ: `/tmp/kaitofinder-save-panel-paced-final-tests.log`。
- Retina 2 倍の固定座標収録で、通常パネル 223、シート 222、一覧付きパネル 225、一覧付きシート 232、
  計 902 フレームを比較した。形式行と名前ラベルとの相対位置、圧縮レベル行と形式行との相対位置は
  全フレームで 0 ピクセルの変化。検出した文字欠けは 0 フレーム。
  映像・メタデータ・比較結果:
  `build/SavePanelAnimationVerification/3039124b-158d-475d-a37e-d16f58ba2d2c/`。
  各フォルダーの `pixel-review.json` に結果、ルートの `pixel-review.py` に当該環境用の比較スクリプトを保存した。
  これはこの検証時の日本語表示・サイズを対象とする比較で、全言語の配置は上記のレイアウトテストで確認する。
  ログ: `/tmp/kaitofinder-save-panel-display-retina-capture.log`。
- UI 結合テスト 21 件が 0 failures / 0 skipped。メニュー操作、最近使った項目の記録、
  再起動後の再オープン、消去、消去後の再起動を確認した。
  ログ: `/tmp/kaitofinder-save-panel-paced-final-ui.log`、
  `build/UIIntegrationVerification/71509435-a60d-4bd7-b4b8-237c0e9bcd23/`。
- Release ビルド成功。minOS 26.0 / SDK 27.0 を確認した。
  ログ: `/tmp/kaitofinder-save-panel-paced-final-release.log`。
  アプリ: `build/InterfaceReleaseDerivedData/Build/Products/Release/KaitoFinder.app`。
  検証後、ようこそ画面だけの旧プロセスを通常終了し、同パスの更新版を起動したことを確認した。

## 検証環境

macOS 27.0（26A428）/ Xcode 27.0（27A266a）/ Apple Silicon / Retina 2 倍。
デプロイ先の最小バージョンは macOS 26.0。macOS 26 の実機表示はこの環境では未確認。

API の参照:
[NSSavePanel](https://developer.apple.com/documentation/AppKit/NSSavePanel)、
[NSView.displayLink](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:))、
[NSView.clipsToBounds](https://developer.apple.com/documentation/appkit/nsview/clipstobounds)、
[SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput)。
