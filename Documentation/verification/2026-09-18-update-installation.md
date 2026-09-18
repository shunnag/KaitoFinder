# Sparkleのインストール・再起動検証（2026-09-18）

macOS 27.2 / Apple Silicon / Xcode 27.0 / Sparkle 2.10.0で実行した。
現在の作業ツリーから別出力先にDeveloper ID署名・hardened runtime有効のReleaseをビルドし、
そのコピーを更新先として使用した。公開・notarizationは行っていない。

## 追加した検証

`Tools/verify_update_installation.py` と専用user driver、アプリ制御helperを追加した。
既存の情報取得テストに加え、実際のSparkle installerによる置き換えと起動まで確認する。
製品の更新UIや署名条件を変更するためのhookは追加していない。

- 入力Releaseは全ファイルのhashを前後で比較し、変更しない。
- 旧版は検証専用の `SPUUserDriver` を組み込んだversion 0のコピー、
  更新先は今回のKaitoFinder Release実行ファイルを持つversion 1のコピー。
  同じUUID付きbundle IDとDeveloper ID、既存Sparkle鍵で署名する。
- コピーから書庫の関連付け・Services・UTType宣言を除き、専用の設定ドメインを使う。
  welcomeを表示しない設定で起動する。秘密鍵はキーチェーン内で使用し、書き出さない。
- フィードとZIPは公式 `generate_appcast` / `sign_update` で生成・検証し、
  `127.0.0.1` にだけbindしたHTTPサーバーから配信する。製品のHTTPS条件は変更しない。
- アプリ制御helperはUUID付きbundle IDと専用ディレクトリが一致するコピーだけを操作する。
  画面収録・AXクリック・実利用中のアプリの終了には依存しない。

実装は [SPUUserDriver公開API](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html)
と [Sparkleの導入・テスト手順](https://sparkle-project.org/documentation/)に基づく。

## 成功した3条件

| 条件 | 確認した結果 |
|---|---|
| 手動の更新・再起動 | 署名付き約7.7 MBのZIPを取得し、version 0を1へ置換。旧PID 36922終了後、Sparkleが新PID 36927を起動し、起動完了を確認 |
| 自動取得・終了時インストール | background checkでユーザーへの更新選択通知なしに準備。旧PID 36958の終了後にversion 1へ置換。2秒間自動再起動がないことを確認し、その後の明示起動でPID 36982の起動完了を確認 |
| 改変ZIP | フィード署名とファイル長を保ち、配信ZIPの1 byteを変更。署名不一致 `SUValidationError`（3002、外側は4005）で拒否。version 0の全ファイル・リンク・権限が変更前と一致し、インストール開始と再起動がないことを確認 |

成功時は更新先bundleの全ファイルSHA-256・シンボリックリンク先・ファイル権限が
署名した参照コピーと一致した。置換後の `codesign --verify --deep --strict` も成功した。
全検証コピーを終了し、UUID付きの設定値を削除し、残存しないことを確認した。
macOSが空の設定ドメインを返す場合も、値が空であることを確認する。
確認時に残っていた実KaitoFinderのPIDは、作業前と同じ96890であった。

初回の改変テストでは、`didExtractUpdate` の通知が署名エラーより先に届くことが分かった。
この通知だけを展開・インストール成功の根拠にしていた検証条件を修正した。
最終判定はinstallerの署名エラー、インストール開始通知の不在、旧bundle全体の一致を使う。

## 実行と証跡

3条件を同じ最終版のverifierで実行し、すべて成功した。
Python構文検査、Objective-C/Swift helperのコンパイル、`git diff --check` も成功した。
今回の製品コード変更はなく、直前の両エンジン全件とアプリ関連テストは
[LZ4 legacy検証](2026-09-18-lz4-legacy.md)に記録している。

- Release: `build/UpdateInstallDerivedData/Build/Products/Release/KaitoFinder.app`
- 元の実行ファイルSHA-256: `77185657973fa009edcde1f1248e9768c41add8d6cc8a76b8acf9cb5e193716d`
- 結果: `build/UpdateInstallationVerification/b921b68c-7206-42bc-9b57-21537f08e73c/result.json`
- 各条件のevents・置換後manifest・HTTP要求記録は同じディレクトリ内。
- ビルド・実行ログ: `/private/tmp/kaitofinder-update-install-{release,all}.log`
- 上記結果ディレクトリにログのコピー、対象ソースのSHA、OSセッション状態も保存した。

旧版のdriverは検証専用であり、過去に配布したKaitoFinderそのものではない。
標準更新ダイアログの操作、公証済み旧版からの更新、GitHub Releases経由の取得は未検証。
09:56:31 JSTの最終確認でも、console UID 501はロック中で前面はloginwindowだった。
保存ダイアログの確定操作・タブキー操作は、OSのロック解除後に実画面で確認する。
この成功を画面検証の代わりにはしない。コミット・push・公開は行っていない。

18:38 JSTの解除後、保存の確定とタブ操作を再開した。午前のロック待ち以降の結果は
[保存パネル・UIの検証記録](2026-09-18-native-save-panel.md)を参照。
