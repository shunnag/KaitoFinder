# 文書形式と LaunchServices の実測 — 2026-09-16

## 結果

オーケストレータが開発用 Mac で Release ビルドを登録し、拡張子ごとの識別子と開き手を確認した。
StuffIt / StuffIt X / Zstandard、`.txz` / `.zipx` / `.deb` を含む下表の形式で
KaitoFinder が候補に出た。`.cab` は宣言した識別子が CoreTypes と一致せず、候補に出なかった。
この不一致を `com.microsoft.cab` への変更で修正した。

`.pkg` は macOS 側の制約で候補に出ない。`.taz` は動的な型に解決され、
`.001` の分割ボリュームと `.exe` の自己解凍アーカイブも関連付けられていない。
下表は **CAB 修正前の実測**であり、修正後にオーケストレータが Release を再ビルドして `lsregister -f` で再登録した結果、開発用 Mac で `.cab` → `com.microsoft.cab` の開き手 6 アプリに KaitoFinder が含まれ、既定アプリも KaitoFinder であることを確認した（`.zst` / `.sit` / `.deb` は変化なし）。

## 方法

2026-09-16 にオーケストレータが次の手順で測定した。

1. KaitoFinder を Release 構成でビルドした。
2. 生成した `KaitoFinder.app` を次のコマンドで LaunchServices に登録した。
   `<app>` はその Release アプリのパス。

   ```sh
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f <app>
   ```

3. 拡張子ごとの識別子を調べ、`NSWorkspace.urlsForApplications(toOpen:)` が返す候補に
   KaitoFinder が含まれるかを確認した。既定アプリを記録した拡張子では、その結果も下表に転記した。

生ログは下表に転記した。
候補と既定アプリは、この Mac のインストール済みアプリと関連付けを反映する。
`LSHandlerRank = Default` の宣言だけで、すべての Mac の既定アプリが決まるわけではない。

## 拡張子ごとの結果

「候補」は KaitoFinder が列挙されたかを示す。既定アプリ名はログの `.app` を省いたもの。
「未記録」は生ログにその値がないことを示し、アプリが存在しないという意味ではない。

| 拡張子 | 識別子 | KaitoFinder が候補に出るか | 既定アプリ |
|---|---|---|---|
| `.zip` | `public.zip-archive` | あり | Archive Utility |
| `.z01` | `public.zip-archive.first-part` | あり | 未記録 |
| `.jar` | `com.sun.java-archive` | あり | 未記録 |
| `.cbz` | `jp.coo.cooviewer.cbz` | あり | 未記録 |
| `.cbr` | `jp.coo.cooviewer.cbr` | あり | 未記録 |
| `.zipx` | `com.winzip.zipx-archive` | あり | The Unarchiver |
| `.tar` | `public.tar-archive` | あり | 未記録 |
| `.tgz` | `org.gnu.gnu-zip-tar-archive` | あり | 未記録 |
| `.tbz` | `public.tar-bzip2-archive` | あり | 未記録 |
| `.tbz2` | `public.tar-bzip2-archive` | あり | Archive Utility |
| `.txz` | `org.tukaani.tar-xz-archive` | あり | Archive Utility |
| `.gz` | `org.gnu.gnu-zip-archive` | あり | 未記録 |
| `.bz2` | `public.bzip2-archive` | あり | 未記録 |
| `.xz` | `org.tukaani.xz-archive` | あり | 未記録 |
| `.lzma` | `org.tukaani.lzma-archive` | あり | The Unarchiver |
| `.Z` | `public.z-archive` | あり | 未記録 |
| `.7z` | `org.7-zip.7-zip-archive` | あり | Archive Utility |
| `.rar` | `com.rarlab.rar-archive` | あり | qooViewer |
| `.lha` | `public.lha-archive` | あり | KaitoFinder |
| `.lzh` | `public.lha-archive` | あり | 未記録 |
| `.cab` | `com.microsoft.cab` | なし（修正前） | エクスプローラー |
| `.iso` | `public.iso-image` | あり | 未記録 |
| `.cpio` | `public.cpio-archive` | あり | 未記録 |
| `.ar` | `com.shunnag.kaitofinder.ar-archive` | あり | 未記録 |
| `.a` | `com.shunnag.kaitofinder.ar-archive` | あり | 未記録 |
| `.deb` | `org.debian.deb-archive` | あり | The Unarchiver |
| `.xar` | `com.apple.xar-archive` | あり | 未記録 |
| `.pkg` | `com.apple.installer-package-archive` | なし | 未記録 |
| `.rpm` | `com.redhat.rpm-archive` | あり | The Unarchiver |
| `.sit` | `com.stuffit.archive.sit` | あり | cooViewer |
| `.sea` | `com.stuffit.archive.sit` | あり | cooViewer |
| `.sitx` | `com.stuffit.archive.sitx` | あり | cooViewer |
| `.zst` | `org.zstandard.zstd-archive` | あり | KaitoFinder |
| `.tzst` | `org.zstandard.zstd-archive` | あり | KaitoFinder |
| `.taz` | `dyn.ah62d4rv4ge81k2p4`（動的） | なし | 未記録 |
| `.001` | `dyn.ah62d4rv4ge8xaqbv`（動的） | なし | 未記録 |
| `.exe` | `com.microsoft.windows-executable` | なし | 未記録 |
| `.tar.gz` | `nil` | 未記録 | 未記録 |
| `.tlz` | `dyn.ah62d4rv4ge81k5d4`（動的） | なし | 未記録 |

`.tar.gz` の行は、拡張子として `tar.gz` を照会した結果。候補の測定値は残っていない。
`.ar` / `.a` の識別子の小文字表記もログどおり。
`.zst` / `.tzst` / `.lha` は KaitoFinder が既定だったが、`.7z` / `.zip` / `.txz` / `.tbz2` は
Archive Utility、`.rar` は別のインストール済みビューアが既定だった。

## CAB の原因と修正

CoreTypes は `.cab` を `com.microsoft.cab` として宣言し、`public.data` / `public.archive` に
準拠させ、拡張子タグを `cab` としている。KaitoFinder が使っていた `com.microsoft.cab-archive` は
他に宣言元がなく、拡張子が解決する型と一致しなかった。実測では開き手が **6 アプリ**列挙され、
KaitoFinder は含まれなかった。

`Info.plist` の CAB の `LSItemContentTypes`、`UTImportedTypeDeclarations` の識別子、
展開サービスの `NSSendFileTypes` をすべて `com.microsoft.cab` に統一した。
import は StuffIt と同様に CoreTypes の識別子を参照し、既存の準拠先と `cab` タグを維持する。
`DocumentTypesTests` の `.cab` の期待値と import の表も同じ識別子に合わせた。

## macOS 側の制約

- `.pkg`: `com.apple.installer-package-archive` は CoreTypes で `apple-internal` とされている。
  KaitoFinder の宣言は登録されるが、LaunchServices が候補に挙げるのはインストーラだけだった。
  宣言を維持し、「ファイル > 開く…」または Dock の KaitoFinder アイコンへのドラッグで開く。
- `.taz`（tar.Z）: CoreTypes の `public.z-archive` が持つ拡張子タグは `z` / `Z` だけで、
  KaitoFinder の import の拡張子一覧ではシステム型を拡張できない。動的な型に解決され、
  候補は **0 アプリ**だった。まれな拡張子の制約として残し、「ファイル > 開く…」から開く。
- `.001` の分割ボリュームと `.exe` の自己解凍アーカイブも関連付けの対象外。

手動確認の手順は [手動検証 §13](../manual-verification.md#13-finder-のこのアプリケーションで開く)を参照。
この変更では sandbox 内で `xcodebuild` を実行していない。修正後の `DocumentTypesTests` と
`ArchiveBatchExtractionUITests`、Release 再登録による `.cab` の候補確認はオーケストレータの検証対象。
