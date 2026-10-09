# KaitoFinder 開発者向け情報

利用者向けの案内は[README](../README.md)、詳しい操作は[利用ガイド](user-guide.md)を参照。

## 方針と構成

KaitoFinder は「一覧のできる圧縮ソフト」ではなく、**名前空間が書庫の中身である
ファイルマネージャ**として作る。Finder と同じ外観・操作感が第一の要件であり、
他のすべてはそれに従属する。

読み取りは [KaitoKit](https://github.com/shunnag/KaitoKit)(解凍Kit)、
書き込みは [GyoshukuKit](https://github.com/shunnag/GyoshukuKit)(凝縮Kit)。
解凍と凝縮を対にした、独立した二つの framework を使う。

## バージョン

KaitoFinder 0.7.0（build 10）、KaitoKit 0.12.1、GyoshukuKit 0.9.0、Sparkle 2.10.0。
同梱版と変更点は[0.7.0 のリリースノート](releases/0.7.0.md)を参照。

## 配布

Sparkleによる自動更新に対応する。「設定」›「アップデート」で自動確認と自動ダウンロード・インストールを選び、
最終確認日時を確認できる。アプリメニューの「アップデートを確認…」から手動でも確認できる。
自動確認は既定で有効、自動ダウンロード・インストールは選択式。
更新フィードの公開・署名と初回配布の手順は[自動更新と配布](software-updates.md)を参照。

sandbox なしで配布する。Developer ID による署名と notarize の手順・実施状況は
[設計書 §11.5](design.md#115-配布sandbox-なしnotarize-済み-2026-09-15)を参照。
リリースビルドは、下記の build コマンドに `-configuration Release` と Developer ID の
`CODE_SIGN_IDENTITY`・`DEVELOPMENT_TEAM` を指定して作成する。開発時は Debug を使う。

## 開発

関係する checkout は `~/Github/` に並べる。

```text
~/Github/KaitoKit     解凍。読み取り
~/Github/GyoshukuKit  凝縮。書き込み
~/Github/KaitoFinder  本 repo
```

`.xcodeproj` はこの二つを `../KaitoKit` と `../GyoshukuKit` の local SwiftPM
package として静的リンクする。ビルドには **Xcode 27** が必要（Swift 6.4、arm64 専用）。
macOS 27 SDK の API を使うが、実行環境は **macOS 26 以上**、配備先は `26.0` を維持する。

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' build
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' test
```

メニュー・操作経路の変更では `python3 Tools/verify_ui_integration.py` も実行する。
実メニューの操作と、最近使った項目の保存・再起動・消去を専用アプリで検証する。
確認範囲とテストの書き方は [UI の回帰テスト](ui-integration-testing.md)を参照。
ファイル一覧のクリック・キー操作の変更では `python3 Tools/verify_finder_interactions.py` も実行する。
実マウス入力での名称変更と既存の書庫間ドラッグを専用アプリで確認する。

リリース前は両ライブラリの `swift test` も実行し、選択した UI テストだけで全体の成功を判断しない。
[横断検証の記録](verification/2026-09-17-release-hardening.md)に
全件・スキップ・実書庫・性能の結果をまとめ、[圧縮形式の追加計画](compression-roadmap.md)に
読み取り・書き込みの不足と追加時の検証条件を記す。
ZIP 20/95 の追加と暗号化入力の効率化は [追加検証](verification/2026-09-18-zip-methods.md)を参照。

アプリの「ファイル > 開く…」、または実行ファイルへのアーカイブのパス引数で開く。
テストはアーカイブを実際に生成し、参照実装（`unzip`、`7zz`、`ditto`、`bsdtar`）と
KaitoKit の往復で検証する。

設計上の判断は [設計書](design.md)、各段階の実測と自動検証できなかった範囲は
[検証記録](verification/)に残している。
Finder や実際のウインドウで確認する操作は [手動検証手順](manual-verification.md)を参照。

## CI

[CI](../.github/workflows/ci.yml) は main / tag への push、pull request、手動、週次で実行する。
Xcode 27 で Debug のアプリと app-hosted tests をビルドし、macOS 27 で試験する。
別の job では同じビルド成果物と Xcode 27 の XCTest ランタイムを macOS 26 へ運び、
再コンパイルせず試験する。兄弟 repo は main を取得し、転送先ではビルド時の SHA と
ソース・DerivedData の絶対パスを照合する。Sparkle は `Package.resolved` の 2.10.0 を使う。

実ドラッグの 3 class、`Tools/` の実 HID GUI driver、性能 probe、実際の自動更新、
署名・notarization は Mac mini で検証する。CI との分担・ログの判定は
[UI の回帰テスト](ui-integration-testing.md#ci-と-mac-mini-の分担)を参照。

## アーカイブ処理の技術詳細

利用者向け文書から分離した実装上の補足。0.7.0 の挙動と旧READMEの情報を保持する。

### 読み取りと形式の補足

- LZ4 は現行 frame の独立／連続ブロック・チェックサムと、8 MiB ブロックの legacy frame・連結に対応する。外部辞書は未対応。新規作成には現行 frame を使う。
- ZIP 内の XZ は method 95、旧 Zstandard は method 20。Shrink / Reduce 1〜4 / Implode、7z の Zstandard coder も展開・プレビューに対応する。
- Finder 製 ZIP は 0.1.0 と同じく `__MACOSX` の付随ファイルを保った一覧で表示・編集する。
- tar.xz・7z LZMA2・ZIP XZ のレベル 6 は従来の Apple エンコーダーを使う。
- 対応範囲の全表は[KaitoKit の対応状況](https://github.com/shunnag/KaitoKit/blob/main/Documentation/formats.md#対応状況)を参照。

### 読み取り制限とアクセス権

圧縮 tar（tar.gz / tar.bz2 / tar.xz / tar.zst / tar.lz4 / tar.lzma / tar.lz / tar.br / tar.Z）は、開くときに内側の tar を一時展開する。
64 MiB を超えると一時ファイルへ保存するため、起動ボリュームに展開後の tar とほぼ同じ空き容量が必要。
一時ファイルの書き込み中に空き容量が 1 GiB を下回ると、開く操作を中止する（KaitoKit の `stagingFreeSpaceReserve`）。
KaitoKit 既定の reader 制限は、1,000,000 項目 / 保持するメタデータ 256 MiB、RAR / `.001` セットの128巻、コーデック辞書 1 GiB。
項目ごと・全体の展開サイズはアプリで制限せず、展開先の空き容量に従う。
パーミッションが格納されていない項目には、プラットフォーム既定の mode（ファイル 0666 / フォルダ 0777 に umask を適用）を使う。

### 一時コピーと原本の確認

- drag out は file promise を使い、ドロップ先が受け取るときに展開する。⌘C は一時領域へ明示的に展開した実ファイルをクリップボードへ渡す。
- 元のアーカイブの quarantine（隔離属性）を展開物へ引き継ぐ。path traversal（`..`）や展開先外への symlink を拒否する。
- 単一ファイルの即時編集前の原本を同じボリュームの一時領域へ `clonefile` で退避し、取り消し時に戻す。
  外部変更の検出はファイルの実体（デバイス・inode）・サイズ・更新日時に基づく。同じ inode・同じサイズで上書きして更新日時も戻した変更は検出できない。
  利用者への説明は[取り消しと外部からの変更](user-guide.md#取り消しと外部からの変更)に記す。
- 強制終了やクラッシュで残った作業ディレクトリ（`.KaitoFinder-add-*` / `.KaitoFinder-new-*`）は、`~/Library/Application Support/KaitoFinder/pending-work.json` の台帳に基づいて次回起動時に回収する。

## English

### Architecture

It is not "a compressor that can show a list" — it is a file manager whose
namespace happens to be the inside of an archive. Looking and behaving like
Finder is the first requirement, and everything else is subordinate to it.

Reading uses [KaitoKit](https://github.com/shunnag/KaitoKit) (解凍Kit, the extraction kit);
writing uses [GyoshukuKit](https://github.com/shunnag/GyoshukuKit) (凝縮Kit, the compression kit).
These two independent frameworks pair extraction with compression. MIT licensed.

### Distribution

The app is distributed without a sandbox. See [design §11.5](design.md#115-配布sandbox-なしnotarize-済み-2026-09-15)
for Developer ID signing, notarization, and their current verification status.
Sparkle provides automatic updates. Settings › Updates controls automatic checks and downloads,
shows the last check time, and offers a manual check. Automatic checks are enabled by default;
automatic downloads and installation on quit are optional.
See [Software updates](software-updates.md) for signed feeds and the initial release setup.
For a release build, add `-configuration Release` and specify your Developer ID
`CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM`. Use Debug for local development.

### Development

Place the KaitoKit, GyoshukuKit, and KaitoFinder checkouts beside each other under
`~/Github/`. The Xcode project statically links `../KaitoKit` and `../GyoshukuKit`
as local SwiftPM packages. Build with Xcode 27 (Swift 6.4) for arm64; the app
runs on macOS 26 and later with deployment target 26.0. The two
`xcodebuild` commands above build and test with the explicit arm64 destination.
Open through File > Open… or pass archive paths to the executable.
Tests build real archives and check them against reference implementations
(`unzip`, `7zz`, `ditto`, `bsdtar`) and a KaitoKit round trip.
See the [design document](design.md), [verification records](verification/),
and [manual verification steps](manual-verification.md).
CI builds only with Xcode 27 and runs the app-hosted tests on macOS 27 and,
without recompiling, macOS 26. Real drag/HID drivers, performance probes,
software update verification, signing, and notarization run on the Mac mini.

### Technical notes

- LZ4 supports current frames with independent or linked blocks and checksums, plus concatenated legacy frames with 8 MiB blocks. External dictionaries are unsupported; creation uses current frames.
- ZIP XZ is method 95 and legacy Zstandard is method 20. Shrink / Reduce 1–4 / Implode and the 7z Zstandard coder also support extraction and previews.
- Finder-created ZIPs retain `__MACOSX` companion files for listing and editing, as in 0.1.0. Level 6 for tar.xz, 7z LZMA2, and ZIP XZ retains the Apple encoder path.
- Compressed tar stages its inner tar when opened. Above 64 MiB, staging uses a temporary file and needs roughly the expanded tar size on the startup volume; opening stops below 1 GiB of free space (`stagingFreeSpaceReserve`).
- KaitoKit reader defaults are 1,000,000 entries / 256 MiB of retained metadata, 128 volumes for RAR / `.001` sets, and a 1 GiB codec dictionary. There is no app-level per-entry or total extraction-size cap; destination space governs extraction.
- Entries without stored permissions use platform defaults: files 0666 and folders 0777, with umask applied.
- Dragging out uses a file promise; ⌘C explicitly extracts temporary real files for the clipboard. Quarantine propagates to extracted files; path traversal and links outside the destination are refused.
- Before single-file immediate edits, `clonefile` backs up the original on the same volume for undo. External-change detection checks device, inode, size, and modification time; an in-place overwrite retaining the same inode and size and restoring the timestamp is undetected.
- Working directories `.KaitoFinder-add-*` / `.KaitoFinder-new-*` left by force quit or crash are recovered at next launch using `~/Library/Application Support/KaitoFinder/pending-work.json`.
