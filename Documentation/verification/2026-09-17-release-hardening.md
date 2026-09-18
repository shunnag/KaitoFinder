# リリース前の横断検証（2026-09-17〜18）

対象: KaitoFinder、隣接する KaitoKit と GyoshukuKit の現在の作業ツリー。
環境: macOS 27 / arm64。macOS 26 の実機結果とは区別する。
開始: 2026-09-17。追加検証: 2026-09-18。
開始時点で KaitoFinder の Sparkle 追加と GyoshukuKit の編集予約改善は未コミット。
既存の変更を保ったまま検証する。

## 完了条件と検証範囲

- [x] 3 リポジトリの全テストを実行し、失敗・スキップの理由と対象範囲を確認する。
- [x] 最近使った項目、タブ、複数ファイル・書庫間ドロップ、同名置換、undo、
      保存・暗号化のアニメーション、設定・更新の接続を実 UI 経路で確認する。
- [x] 入力変更・取消し・破損・大容量・パス境界・終了時の後始末を関連処理へ横展開する。
- [x] KaitoKit の形式・コーデックとアプリの可否判定、GyoshukuKit の作成・編集を照合する。
- [x] 確認した不具合は修正前に失敗する回帰テストを用意して修正し、関連・全件検証を通す。
- [x] 性能上の候補を測定し、有効な改善だけを適用する。測定中は他の重い検証を止める。
- [x] 未対応の容器・圧縮方式・出力形式を現行実装と一次資料から棚卸しし、
      追加可能なものの実装方針・優先順・必要な独立検証を文書化する。
- [x] 最終 Release のビルド・署名・起動を確認し、実証できていない範囲を残す。

## 再現・修正した問題

1. **エンジンと画面の対応形式のずれ**。ZIP Zstandard/PPMd と CAB LZX をエンジンが
   読めても、画面がプレビュー・外部アプリで開く操作を拒否していた。
   allowlist を更新し、実 fixture の読み取り結果を独立した SHA-256 と照合する接続テストを追加。
   既存の「未対応 ZIP」テストも、現在対応済みの method 93 から未対応の method 96 に修正。
2. **圧縮 tar の編集可否の誤判定**。先頭 skippable frame のある tar.zst を plain tar として
   編集できる状態になり、逆に `BZh9-...` という名前から始まる plain tar を編集不可にしていた。
   アプリ独自の数バイトの推測をやめ、KaitoKit の構造を調べる `FormatDetector` を使用する。
3. **圧縮 tar の別名の接続漏れ**。`.tar.lzma` / `.tlz` / `.tbz` を展開した tar として開く。
   lc=3/4、大小文字、メモリ／一時ファイル staging、unlink 後の reopen、壊れた入力と上限を検証。
4. **LHA の最後の項目を削除できない**。writer が正しく出力した単一終端 byte の空 LHA を
   reader が拒否し、文書の編集後再読込に失敗していた。`.lha` / `.lzh` の名前 hint と正確な
   1 byte の内容の両方がある場合だけ受理する。無関係なゼロ埋め入力には広げない。
   ZIP / tar / tar.gz / 7z / LHA の空作成・全削除・再追加、アプリの undo/redo を横断検証。
   lhasa は空 LHA を検査成功とする。7-Zip 26.03 は拒否するため、互換性の限界として区別する。
5. **XZ の辞書メモリ上限の接続漏れ**。Apple Compression に上限設定がなく、単体・連結・xar 内部の
   XZ が `ReadLimits.maxDictionarySize` を無視していた。全ブロックの LZMA2 chunk envelope を
   展開せずに走査し、OS に渡す前に辞書サイズを検証する。最初のブロックだけの検査にはしない。
   block/header/Index/footer を確認し、metadata の読み取りは固定容量。内容の検証は従来どおり native decoder が行う。
6. **全件検証で見つかったテスト・表示の取りこぼし**。設定4タブ、アプリメニューの手動更新、
   ドイツ語の省略記号前の NBSP を反映。非表示ウインドウの toolbar に対する検証は、実際に表示して
   visibleItems を確かめてから実行する。`validateVisibleItems()` に非表示 item の更新を期待しない。
7. **大きい LHA 作成時のメモリ増大**。入力と圧縮出力を全体保持していた。
   1 MiB入力と8 KiB履歴を使うストリームへ変更し、bit境界・CRC・stored fallbackを維持。
   圧縮候補は作成直後unlinkする権限0600のspoolへ置き、raw bytesは未完成出力に保持する。
   LHAの新規4回帰ケースと既存のlhasa/7zz照合を含む23件が成功。
   8 MiBのAPFSテストvolumeで32 MiBを追加して容量不足を起こすアプリ側テストも加え、
   原本のbyte・undo・世代・一時領域が保持／削除されることを関連45件で確認した。

修正前に失敗を確認したログ:
`/private/tmp/kaitofinder-release-capability-before.log`、`...-tar-aliases-before.log`、
`...-empty-lha-before.log`、`...-empty-writers-before.log`、`...-empty-document-before.log`、
`...-xz-limits-before.log`（共通 prefix は `kaitofinder-release`）。

関連検証は、アプリの能力・プレビュー・表示・メニュー等122件、編集・置換44件、
圧縮 tar と既存形式32件、LHA 判定等44件（外部コーパス待ち3 skip）、
全 writer の空書庫2件、XZ と既存形式39件、XZ の追加境界5件が成功した。
これは全件検証とは分けて記録する。

## 性能

同名フォルダの内容比較で、全 entry の親パスを繰り返し結合しており、深さの二乗の処理があった。
共通する成分を平坦な trie に登録する処理へ変更。仮想フォルダも含む件数と Unicode 等価性を保ち、
深さ1,024の回帰ケースも追加した。再帰する参照型を使わず、解放時のスタックも深さに比例させない。

`python3 Tools/benchmark_conflict_paths.py` は製品の実メソッドを取り出して `swiftc -O` で計測する。
件数を固定値で照合し、各3回の中央値を報告。重いテストを停止した状態で旧・新を2巡計測した。

| ファイル数 / 深さ | 修正前の2巡目 | 修正後の2巡目 |
|---|---:|---:|
| 1,000 / 8 | 3.60 ms | 1.00 ms |
| 4,000 / 8 | 14.23 ms | 3.50 ms |
| 1,000 / 64 | 108.78 ms | 3.60 ms |
| 4,000 / 64 | 436.63 ms | 14.34 ms |
| 1,000 / 256 | 1,501.04 ms | 13.23 ms |

ログ: `/private/tmp/kaitofinder-release-conflict-paths-{before,after}{,-repeat}.log`。
これは集計関数だけの測定で、ファイル読み取り・圧縮を含む全操作の速度とは区別する。

### LHA writer のメモリ

`python3 Tools/benchmark_lha_memory.py --max-rss-mib 96`。
製品のwriter/encoder等6ファイルを `swiftc -O` でビルドする。driverは要求された小さい入力だけを作り、
入力全体を保持しない。各パターン・サイズを独立プロセスで実行し `getrusage` のpeak RSSを読む。
各出力は lhasa の test を通す。アプリ全体のRSSではなくwriter単体の測定。

| 入力 | パターン | 旧peak RSS | 新peak RSS | 旧 / 新 所要時間 | 旧 / 新 書庫サイズ |
|---|---|---:|---:|---:|---:|
| 16 MiB | repeat | 25.83 MiB | 10.31 MiB | 0.076 / 0.069 s | 4,177 / 678 bytes |
| 64 MiB | repeat | 73.53 MiB | 8.55 MiB | 0.189 / 0.192 s | 4,216 / 990 bytes |
| 256 MiB | repeat | 265.53 MiB | 8.55 MiB | 0.806 / 0.762 s | 4,372 / 2,238 bytes |
| 16 MiB | random | 82.625 MiB | 14.3125 MiB | 0.251 / 0.250 s | 同一 16,777,274 bytes |
| 64 MiB | random | 298.734 MiB | 14.328 MiB | 1.006 / 1.007 s | 同一 67,108,922 bytes |
| 256 MiB | random | 1,163.281 MiB | 14.344 MiB | 4.049 / 4.022 s | 同一 268,435,514 bytes |

ログ: `/private/tmp/kaitofinder-release-lha-memory.log`（旧）と `...-lha-memory-final.log`（新）。
旧sourceに対する96 MiBゲートは64 MiB randomで失敗、新sourceは全6条件で成功した。
ゲートの旧失敗ログ: `...-lha-memory-gate-before.log`。測定中は他の重いテストを止めた。
代わりに作業用ディスクにはraw bytesと圧縮候補が一時的に必要。容量不足時の原本保持を別テストで確かめる。

## 初期の全件実行

修正前の結果:

| 対象 | 件数 | 結果 |
|---|---:|---|
| KaitoFinder | 749 | 1 skip、5テストケース内の134 assertion failure |
| KaitoKit | 1,144 + compat 24 | 45 skip、失敗0 |
| GyoshukuKit | 186 | skip・失敗0 |

アプリの失敗は上記の設定・メニュー期待値・独語表記・非表示 toolbar の検証に対応する。
skip は isolated-process recent-history、外部 LHA/RAR/ar/cpio/CAB/StuffIt 入力、
明示指定の JPEG 大容量・変異入力、InfoZIP build の BZip2 非対応が中心。
後段で recent-history は別プロセス、CAB/StuffIt は利用可能な実 fixture を指定して検証する。

ログ:

- `/private/tmp/kaitofinder-release-finder-baseline.log`
- `/private/tmp/kaitofinder-release-kaitokit-baseline.log`
- `/private/tmp/kaitofinder-release-gyoshuku-baseline.log`

既存の検証記録は調査対象の手がかりとして使い、今回の実行結果とは分ける。

## 最終検証

- KaitoKit: **1,154件、43 skip、失敗0**。Compat **24件、失敗0**。
  CAB LZXの実製品CABをcabextractと比較し、暗号化StuffIt実書庫も指定して成功。
- GyoshukuKit: LHAストリーム化後の全件 **192件、skip・失敗0**（約317秒）。
- KaitoFinder: **758件、1 skip、失敗0**（約424秒）。
  唯一のskipは別プロセス専用のrecent-historyで、下記4回の起動ですべて成功した。
  Quick Lookの前面化は全件実行でもskipされず成功。全件実行の前後ともOSのロック解除を確認した。
  最終LHA変更後の編集・同名置換・容量不足の関連 **45件はskip・失敗0**。
- 追加のRelease検証4件は失敗・skip 0。StuffIt X JPEG **292入力中280全byte一致、12既知の未対応**、
  歴史的書庫7件、敵対入力12,154件、大きい32 MiBの距離境界を含む。
- ASan/UBSan: 19種のseedから **399変異、crash/hang/sanitizer findingすべて0**。
- LHAの追加4回帰テストもASan/UBSan付きで成功し、診断0。
  SwiftPMの列挙helperはASanの遅いロードで起動できなかったため、同じtest bundleを
  `DYLD_INSERT_LIBRARIES` にASan runtimeを指定した `xctest -XCTest GyoshukuKitTests.LHABoundedWriterTests` で実行した。
- pending-work: 4実プロセスが登録した200作業領域を保持し、全owner終了後にすべて回収する検証が成功。
- LHAストリーム化を含む最終Developer IDのReleaseビルドと `codesign --verify --deep --strict` が成功。
  解除後にも署名を再検証し、`build/SparkleDerivedData/Build/Products/Release/KaitoFinder.app` の
  起動完了を確認した（PID 85367）。
- 最終Releaseから更新ZIP・feedを再生成し、実Sparkleのローカルprobeで新バージョン検出、
  同一版の更新なし、改変署名付きfeedの拒否が成功。
  `build/ReleaseHardeningStreamingUpdateVerification` は明示的なtest-only出力。
  GitHubへの公開、notarizeした配布版の実インストール・再起動は今回実施しない。

ログ: `/private/tmp/kaitofinder-release-{finder,kaitokit,gyoshuku}-final.log`、
`...-gyoshuku-final-streaming.log`、`...-extra-corpus.log`、`...-fuzz.log`、`...-lha-asan-run.log`、
`...-pending-work.log`、`...-signed-streaming.log`、`...-codesign-streaming.log`、
`...-update-package-streaming.log`、`...-update-probe-streaming.log`、`...-lha-document-final.log`。
解除後の最終全件・署名・起動は `...-finder-unlocked-final.log`、`...-codesign-final-unlocked.log`、
`...-launch-final.log`。

ロック中の画面結果を誤って成功にしないよう、`Tools/verify_ui_integration.py` にconsole/lockの
事前・事後チェックを追加。Swift helperがロック状態で理由付きexit 1になることを確認。
Quick Lookの前面での操作も結合ツールへ加えた。システムのロック設定や権限は変更しない。

### ロック解除後の実画面（2026-09-18）

ユーザーの解除連絡後、OSからも解除済みと確認した。
解除前の実行は757件・2 skip・3ケース内の4 failureだった。
conflict sheetのReturn、保存パネルのfocus、タブのkey windowで失敗し、Quick Lookの前面化もskipされた。
その時点で `CGSSessionScreenIsLocked=1` を確認しており、画面検証の成功には数えなかった。
`Tools/verify_ui_integration.py` は操作系49件と別プロセスのrecent-history 4件、
合計 **53件、失敗・skip 0**。前回失敗した置換シートのReturn、保存パネルのfocus、
タブのkey windowも成功した。Quick Lookの前面化もskipされず成功。
ログ: `/private/tmp/kaitofinder-release-ui-final.log`、
`build/UIIntegrationVerification/da597252-6759-43a8-ad2d-420501fa140c/`。

`Tools/verify_save_panel_animation.py` で通常パネル／シートと一覧あり／なしの4条件を再録画した。
Retina 2倍の固定座標で **657フレーム**（167 / 166 / 135 / 189）を比較し、
名前ラベルに対する形式行、形式行に対する圧縮レベル行の相対位置変化は全フレーム **0 pixel**。
検出した文字欠けも **0フレーム**。これは今回の日本語・画面倍率・サイズでの実描画検証で、
全言語の配置検査とは分ける。
録画ツールにもconsole/lockの事前・事後検査を横展開した。
映像と各 `pixel-review.json`:
`build/SavePanelAnimationVerification/87504d10-41b8-4af4-90f3-acdfeaafe644/`。
ログ: `/private/tmp/kaitofinder-release-save-panel-final.log`、`...-save-panel-pixels.log`。

内容比較はQuick LookのXPC描画が通常のview snapshotには含まれないため、
検証用の比較ウインドウだけをScreenCaptureKitで別に撮影した。
左の `original` と右の `new contents` が読めることを画像で確認し、置換・undoのテストも成功。
画像と実行スクリプト: `build/ReleaseHardeningConflictPreviewVerification/`。
更新設定のライト／ダーク、タブと保存アクセサリのsnapshotは `build/ReleaseHardeningUIReview/` に保存。

アプリ全件は `/private/tmp/kaitofinder-release-finder-unlocked-final.log` に記録し、758件の実行が成功。
署名済みReleaseの起動も確認した。3リポジトリの変更ソースのSHA-256は
`build/ReleaseHardeningEvidence/tested-source-manifest.json` に保存し、検証終了時にも一致を確認した。

未対応codec・出力形式の追加方針は[圧縮形式の追加計画](../compression-roadmap.md)を参照。
macOS 26 / Intel、未提供の外部コーパス、既知の未対応profileは今回の実機成功範囲には含めない。
