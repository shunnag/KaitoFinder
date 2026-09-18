# Sparkle 自動更新と設定画面

環境: macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、arm64。
ビルド対象は macOS 26 以降。macOS 26 の実行環境では検証していない。

## 実装

- Sparkle 2.10.0 を SPM で追加し、解決結果をリポジトリに保持する。
- アプリ起動時に単一の updater を開始し、Sparkle 標準の更新 UI とスケジューラを使用する。
- 設定に「アップデート」タブを追加。自動確認、自動ダウンロード・インストール、最終確認日時、手動確認を配置。
- アプリメニューの手動確認も同じ updater を呼ぶ。実行可否と設定変更を KVO で追従する。
- 26言語を追加。起動時は既定値を保存済みの選択に書き戻さない。
- HTTPS、更新書庫の Ed25519 署名、フィード署名を要求する。
- 専用鍵はログインキーチェーンの account `com.shunnag.KaitoFinder` に生成。公開鍵だけを Info.plist に格納。
- GitHub Releases 向けの生成ツールと[配布手順](../software-updates.md)を追加。

## 検証結果

設定関連の12テスト成功。最初の表示検査で見つかった説明ラベルの幅制約の競合を修正した。
全26言語のライト／ダークで、文字とコントロールのはみ出しがないことを検査した。
設定タブを切り替えても幅を保ち、確認日時や設定変更ではウインドウをリサイズしない。
日・英・独の設定画面を画像でも確認した。
ログ: `/tmp/kaitofinder-sparkle-settings-tests.log`。
画像: `/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/KaitoFinderSnapshots/2026-09-17T12-47-48.710Z/`。

最終結合検証は **52件成功、失敗・skipとも0**。
操作系48件と、最近使った項目の記録・再表示・消去・消去後の再起動確認4件を実行した。
既存の保存パネル、タブのホバー、複数項目のコピー・置き換え、メニューも含む。
ログ: `build/UIIntegrationVerification/cfe972f7-5b90-427a-bc1a-00dfb9307b0c/`。

実 Sparkle から開いた設定画面への KVO 同期も、追加の確認項目を加えて再実行し成功。
ログ: `/tmp/kaitofinder-sparkle-kvo-tests.log`。

Release ビルド成功。ライセンス同梱も確認した。
ad-hoc 署名の起動では Library Validation が Sparkle の読み込みを拒否したため、
利用可能な Developer ID をビルド時に指定した。アプリと Sparkle が同じ Team ID で署名され、
hardened runtime を有効に保ったまま起動できることを確認した。`codesign --verify --deep --strict` も成功。
ログ: `/tmp/kaitofinder-sparkle-release-signed.log`、`/tmp/kaitofinder-sparkle-launch.log`。
起動した更新版は `build/SparkleDerivedData/Build/Products/Release/KaitoFinder.app`（PID 39443）。

`Tools/prepare_update.py --test-only` で更新ZIPと署名付きappcastを生成し、両方の署名、URL、サイズ、ビルド番号を検証した。
ログ: `/tmp/kaitofinder-sparkle-package.log`。
続いて `Tools/verify_software_updates.py` を実行し、一時アプリと loopback サーバーを使って実 Sparkle で次を確認した。

- 古いビルド番号0から、配布物のビルド番号1を検出。
- 同じビルド番号1からは更新なし（`SUNoUpdateError` / 1001）。
- 署名後にタイトルを改変したフィードを拒否（`SUSparkleErrorDomain` / 1000）。

ログ: `/tmp/kaitofinder-sparkle-probe.log`。インストールは開始していない。
ローカル生成物は `build/SparkleUpdateVerification/` にあり、配布不可のテスト用であることをファイルでも明示している。

## 2026-09-18の横断検証

ZIP追加前のコードでアプリ全758件（履歴の別プロセス用1 skip）、UI結合53件が失敗0。
最終Releaseの署名・起動と、そのアプリから作った更新ZIP・feedによる実Sparkleの3条件も再検証した。
結果とログは[リリース前の横断検証](2026-09-17-release-hardening.md)を参照。

同日のZIP 20/95追加後も、アプリ全763件・UI結合54件、最新署名Releaseで実Sparkleの3条件を検証した。
skipの内訳を含む結果は[ZIP追加検証](2026-09-18-zip-methods.md)を参照。

## 配布前に必要な確認

GitHub の初回フィードと正式リリースは未公開。公開までは製品の手動確認は取得エラーになる。
Developer ID 署名・notarization・staple を完了した配布版と、一つ前の配布版の間での
実インストール・再起動は今回の検証に含めていない。公開手順と確認範囲は[自動更新と配布](../software-updates.md)に記す。
