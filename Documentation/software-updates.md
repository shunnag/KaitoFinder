# 自動更新と配布

Sparkle 2.10.0 を Swift Package Manager で組み込む。解決した版は
`KaitoFinder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` に記録する。
アプリは従来どおり sandbox なし、Release は hardened runtime を有効にする。
Sparkle のライセンスはアプリの `Sparkle-LICENSE.txt` に同梱する。
開発時は Debug を使用する。Release の起動検証には Developer ID または Apple Development の署名を指定する。
ad-hoc 署名の Release では、hardened runtime の Library Validation により Sparkle を読み込めない。
このために配布版の Library Validation を無効にしない。

## 利用者向けの動作

設定の「アップデート」タブに、自動確認、自動ダウンロード・インストール、手動確認、最終確認日時をまとめる。
アプリメニューの「アップデートを確認…」も同じ updater を使う。

- 自動確認は既定で有効。確認間隔は Sparkle 標準の1日。
- 自動ダウンロード・インストールは既定で無効。有効にすると、取得した更新を終了時にインストールする。
- 自動確認を無効にすると自動ダウンロードの設定も操作できなくなるが、選択値は保持する。
- 自動確認を無効にしていても手動確認は使える。実行可否は Sparkle の `canCheckForUpdates` に従う。
- 設定の保存と更新周期は Sparkle に任せる。起動時に保存済みの選択を既定値で上書きしない。
- 更新ダイアログから設定が変更された場合も、KVO で開いている設定画面へ反映する。
- 不正な配布設定や updater の初期化失敗では更新コントロールを無効にし、利用できない旨を表示する。

テストホストでは自動起動しない。テスト用 updater と設定ドメインを注入し、実利用者の設定・アプリを更新しない。

## フィードと署名鍵

現在のフィードは `https://github.com/shunnag/KaitoFinder/releases/latest/download/appcast.xml`。
GitHub Releases の最新の正式リリースに `appcast.xml` と、そのフィードが参照するZIPを配置する。
GitHub の `releases/latest` はリリース対象コミットの `created_at` を基準に選ばれる。
固定フィードURLが 404 にならないよう、各リリースには公開前に必ず `appcast.xml` を添付する。
生成する appcast は最新の1項目だけを含むため、旧系統の保守リリースを「latest」にしない。
`Tools/prepare_update.py --previous-appcast <path>` に前回のローカルフィードを渡すと、
署名ツールを呼ぶ前に、今回の `CFBundleVersion` が前回の最新ビルドより大きいことと、
`CFBundleShortVersionString` が前回以上であることを検査する。省略可能で、フィードのダウンロードは行わない。

アプリには HTTPS のフィードURLと Ed25519 公開鍵が必要。
`SURequireSignedFeed` と `SUVerifyUpdateBeforeExtraction` を有効にし、更新情報とダウンロードした書庫を検証する。

この Mac では、Sparkle の `generate_keys --account com.shunnag.KaitoFinder` で専用の鍵を作成済み。
秘密鍵はログインキーチェーンにあり、リポジトリや更新ファイルには含めない。
`SUPublicEDKey` に対応する鍵を、今後の更新でも継続して使う。
別の Mac に配布作業を移す場合は、Sparkle 公式の鍵移行手順で安全に引き継ぐ。
公開鍵だけを作り直して差し替えると、既存利用者への更新がつながらなくなる。

## リリースの準備

1. `MARKETING_VERSION` を次のバージョンにし、`CURRENT_PROJECT_VERSION` は以前の配布版より増やす。
   Sparkle の新旧判定は `CFBundleVersion` を使う。テスト用ビルド番号を正式版へ流用しない。
2. [配布手順](design.md#115-配布sandbox-なしnotarize-済み-2026-09-15)に従って、Developer ID で署名し、
   notarize してアプリに staple する。Sparkle.framework と内部のヘルパーも含めて署名する。
3. staple 後のアプリから、次のツールでZIPと署名付きフィードを作る。

```sh
python3 Tools/prepare_update.py \
  --app build/export/KaitoFinder.app \
  --sparkle-bin build/SparkleDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin \
  --output build/updates/0.2.0 \
  --notes Documentation/releases/0.2.0.md \
  --previous-appcast build/updates/0.1.0/appcast.xml
```

バージョンとパスは例。`--notes` と `--previous-appcast` は省略可能。初回リリースでは前回フィードの指定を省く。`--sparkle-bin` は実際に依存解決した DerivedData の場所に合わせる。
このツールはコード署名・Gatekeeper・staple・公開鍵の一致を検査し、Sparkle 公式の `generate_appcast` で
署名付きZIPとフィードを生成する。最後に双方の署名、URL、サイズ、ビルド番号を再検証する。
生成と検証は出力先と同じ親ディレクトリの一時フォルダで行い、成功した一式だけを出力先へ確定する。
途中のエラーや通常の中断では一時フォルダを削除するため、同じ出力先で再実行できる。
既存の出力先は、シンボリックリンクや作成中に別の処理が作った空フォルダを含めて上書きしない。
アプリ自身の中を出力先にする指定も受け付けない。ネットへのアップロードは行わない。

4. 生成物を確認してから、対応する `v0.2.0` の下書き GitHub Release に `KaitoFinder-0.2.0.zip` と
   `appcast.xml` を添付する。両方のアップロード後に最新の正式リリースとして公開し、上記の固定フィードURLから取得できることを確認する。
   リリースノートはフィード内に埋め込まれる。公開後にフィードを手編集せず、変更する場合は再署名する。
5. 一つ前の配布版で「アップデートを確認…」からインストール・再起動まで検証する。

初回は Sparkle を含む配布版を手動で配布する必要がある。Sparkle がなかった旧版へ、この仕組みだけで追加はできない。
初回フィードを公開するまでは、GitHub の更新URLは利用できず、手動確認では取得エラーになる。
初回リリース 0.1.0 (build 2) は 2026-09-19 に公開済み（`verification/2026-09-19-release-review.md` の「初回リリース」節）。

## ローカルの検証

更新ファイル作成時の失敗、中断、再実行、同時作成の回帰テストは次で実行する。
外部の署名ツールは代替し、macOSの実ファイルシステムで出力先の確定と後片付けを検査する。

```sh
python3 -m unittest discover -s Tools/tests -p 'test_prepare_update.py' -v
```

[失敗後の再実行と実署名ツールでの検証結果](verification/2026-09-18-update-preparation.md)を参照。

`SoftwareUpdateTests` は実 Sparkle の設定保存、設定コントロールとメニューの同期、無効状態、
26言語とライト／ダークのレイアウトを検査する。`Tools/verify_ui_integration.py` に含める。

配布ファイルの生成とフィードの検出は、署名済みのローカル Release ビルドでも検証できる。

```sh
python3 Tools/prepare_update.py \
  --app build/SparkleDerivedData/Build/Products/Release/KaitoFinder.app \
  --sparkle-bin build/SparkleDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin \
  --output build/SparkleUpdateVerification --test-only
python3 Tools/verify_software_updates.py \
  --app build/SparkleDerivedData/Build/Products/Release/KaitoFinder.app \
  --prepared-update build/SparkleUpdateVerification
```

`--test-only` の生成物は配布しない。検証は一時 bundle と loopback HTTP サーバーだけを使い、
実 Sparkle の `checkForUpdateInformation` で新しい版・同じ版・改変フィードを調べる。
インストールは行わない。製品のURL要件は HTTPS のままで、HTTP は一時テスト bundle にだけ設定する。
Developer ID・notarization を含む実配布環境での最終インストール検証は、上記の配布手順で別途行う。

ローカルで置き換えと再起動まで確認する場合は、次の専用ツールを使う。

```sh
python3 Tools/verify_update_installation.py \
  --app build/UpdateInstallDerivedData/Build/Products/Release/KaitoFinder.app \
  --sparkle-bin build/SparkleDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin \
  --identity "Developer ID Application: Name (TEAMID)"
```

`--identity` は使用する既存のDeveloper ID証明書に置き換える。
入力のReleaseは読み取り専用とし、UUID付きの検証コピーを作って署名する。
コピーはファイル関連付け・Servicesを登録せず、専用の設定ドメインを使う。
署名付きloopbackフィードで、手動更新と再起動、自動取得後の終了時インストール、
改変ZIPの署名エラーと旧アプリの保持を確認する。
置き換え後は全ファイル・シンボリックリンク・パーミッションとコード署名を照合し、
新しいプロセスの起動完了を確認して検証コピーだけを終了する。

結果は `build/UpdateInstallationVerification/` に保存する。生成物は配布しない。
これは検証専用のuser driverによるローカルインストールであり、
標準更新ダイアログの操作、GitHub経由の配布、公証済み旧版からの更新は別途確認する。
[2026-09-18の実行結果](verification/2026-09-18-update-installation.md)を参照。

公式資料: [導入](https://sparkle-project.org/documentation/)、
[設定画面](https://sparkle-project.org/documentation/preferences-ui/)、
[既定値と設定](https://sparkle-project.org/documentation/customization/)、
[配布と署名](https://sparkle-project.org/documentation/publishing/)。
