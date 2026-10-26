# KaitoFinder セキュリティ・堅牢性監査の指示書（2026-10-26）

この文書は**検査の手順書**であり、検査結果ではない。結果は
`Documentation/verification/2026-10-26-security-audit.md` に、本プロジェクトの検証記録の形式
（`# <題>（YYYY-MM-DD）`、日本語、再現コマンドと実出力つき。`2026-09-10-extraction-safety.md` が見本）で書く。

**この検査は KaitoKit 0.17.0 のリリース判定の前提条件**である。KaitoKit 側（`../KaitoKit`、branch
`fix/security-audit-2026-10-26`）の修正は、KaitoFinder・GyoshukuKit・cooViewer の 3 プロジェクトの検査が
終わるまでリリースしない。

## 1. 背景: KaitoKit 側で何が見つかったか

2026-10-26 に外部の AI エージェントが KaitoKit の監査報告（34 指摘）を提出した。独立検証（16 群の triage +
確認済み各件に敵対的反証 2 観点、計 81 エージェント）の結果は
`../KaitoKit/Documentation/verification/2026-10-26-security-audit.md` にある。要点:

- 監査が「高」とした 2 件はどちらも重大度が誤り。実際に深刻だったのは「中」とされた 2 件。
- 本物だったのは **鍵導出の CPU 枯渇** 2 件（salt が異なる 7z folder ごとに予算未課金の鍵導出 ≈ 0.42 秒/回、
  無制限 / StuffIt X の鍵導出が二次で 225 byte の書庫が 425 秒）。いずれも**利用者が password を入力した時
  だけ**（誤った password でも全額）発生する。
- **展開 metadata の意味論** 2 件（setuid/setgid を既定で復元していた / resource fork だけの entry が、自分が
  作っていない既存ファイルの mode と mtime を書き換えていた）。
- **argv の秘密**（CLI の `-p`）、**bidi 制御文字による表示偽装**（entry 名が未 escape）。
- 誤りだった 3 件、既に設計判断として文書化済みだった複数件、到達不能だった 2 件。

**この検査で再利用すべきは「何が見つかったか」より「どう判定したか」**（第 2 節）である。

## 2. 検査の方法（ここが本題）

1. **主張を鵜呑みにしない。** 本書の問いも含め、すべて現物のコードで確認する。行番号は HEAD で検証する
   （本書の行番号は 2026-10-26 の `10a7331` 時点。ずれていたら直して記録する）。
2. **再現できたものだけを「実証済み」と呼ぶ。** 細工ファイルを自分で作り、実際に走らせ、`/usr/bin/time -l`
   などの実測値と実出力を記録に貼る。再現できなかった主張は「未実証」と明示する。
3. **既に守られていないかを先に探す。** 上流の検査、呼出側の契約、既定値、`ReadLimits`、既存の検証記録、
   `Documentation/limitations.md` の明記された製品判断。**「設計判断として文書化済み」「到達不能」は正しい
   結論**であり、成果である。各領域の「既にある緩和策」を読み、再報告しない。
4. **重大度は「既定設定で誰が引き起こせるか」で決める。** 攻撃者が書庫を渡せば済むのか、利用者が特殊な操作を
   するのか、呼出側が異常な option を渡した場合だけか。GUI プロセスでは「ハングが見える」ことも実害に数える。
5. **提案は最小の変更に絞る。** 「文書化だけ」「対応不要」も推奨として正当。修正案が released な意味論や
   既存テストを壊さないかを必ず書く。
6. **過大評価を自分で疑う。** 監査報告は高を 2 件挙げて両方外した。重大度を上げる前に、反証を一度書いてみる。

## 3. 前提: KaitoKit 0.17.0 候補の変更とこのプロジェクトへの影響

| 変更 | KaitoFinder への影響 |
|---|---|
| `ReadLimits.maxSevenZipEntryKDFWork`（既定 `4 × 2^24` SHA-256 rounds、reader 単位） | **影響あり。最重要（第 4.1 節）** |
| `ReadLimits.maxStuffItXKDFWork`（既定 `2^22` MD5 圧縮、reader 単位） | 影響の有無を要確認（`.sitx` は読取専用） |
| `ExtractionOptions.preserveSetUserIDBits`（既定 `false`。file の setuid/setgid を除去） | **無関係**。KaitoFinder は `ExtractionOptions` を構築せず、KaitoKit の展開器を呼ばない（独自の writer を持つ）。grep で確認してから「無関係」と記録する |
| resource fork entry が既存 data fork の metadata を書き換えない | **無関係**（同上） |

依存は `../KaitoKit` / `../GyoshukuKit` の**ローカル path 参照で、版の pin が無い**
（`KaitoFinder.xcodeproj/project.pbxproj:428-437`）。CI は両者を `main` の浅い clone で再構成する
（`Tools/ci/common.sh:21-26`）。したがって**ローカルでは既に audit branch の KaitoKit で動いている**可能性が
ある。検査開始時に `git -C ../KaitoKit log --oneline -1` を記録せよ。

## 4. 検査領域（優先順）

各領域の「問い」は決着可能な形にしてある。答えを yes/no と根拠（file:line か実測）で書く。

### 4.1 KDF 予算の多重化（最優先・KaitoKit 修正の実効性の検証）

KaitoKit の `KDFWorkBudget` は **reader 単位**で、`SevenZipReader.reopened` は予算を引き継がない
（`../KaitoKit/Sources/KaitoKit/Core/KDFWorkBudget.swift:2-19`、
`../KaitoKit/Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift:154-160`）。KaitoFinder は reader を
複数持つため、予算が倍になる疑いがある。

起点: `KaitoFinder/Model/Session/ArchivePasswordVerification.swift:76`（worker ごとの `reader.reopen()`）、
`:36-50`（並列化の条件）、`Extraction/ParallelExtraction.swift:76`、
`Extraction/ArchivePromiseExtractionQueue.swift:41`（4 slot）、
`Model/Session/ArchiveSession.swift:205-250`（`while true` の password prompt loop。:218 は `open`）、
`:143-152`、`:872`（`hasEncryptedHeaders` が無 password の second reader を開く）。

答えるべき問い:
- 1 回の利用者操作で `maxSevenZipEntryKDFWork` の実効倍率はいくつか（worker 数 × slot 数）。M4（10 core）での
  実数を書く。
- 誤った password を N 回入れると N 倍の予算を消費するか。prompt loop に試行回数の上限や backoff はあるか。
- 予算は一覧の前か後か。**password を入れずに browse するだけで鍵導出が走るか**。
- `hasEncryptedHeaders` の second reader は鍵導出まで到達するか、その前に失敗するか。
- 対策は `ArchiveReaderOptions.kaitoFinder` で上限を下げるのが小さいか、verification で reader を共有するのが
  小さいか（`sending ArchiveReader` の isolation 設計を踏まえて）。

再現: `../KaitoKit/Tests/Fixtures/sevenzip-kdf/generate.py` で folder 数を増やした `distinct.7z` を作り、
KaitoFinder で開いて**誤った** password を 1 / 3 / 10 回入れ、各回の wall と CPU を測る（線形なら予算の
持ち越しが無い証拠）。compression threads の設定を 1 と最大で A/B して worker 倍率を直接測る。
正しい password を vault に覚えさせた場合と比較して、鍵導出のコストと展開コストを切り分ける。
`.sitx` が UI で password prompt に到達し得るかを確認し、到達しないなら `maxStuffItXKDFWork` は
「このプロジェクトでは無関係」と反証として記録する。

既にある緩和策（再報告しない）: `workerCount` は solid group / サイズ不明 entry では並列化せず、64 entry か
8 MiB 未満では並列化しない。prompt loop は誤った候補を保持しない（`:229-232`）。progress からの
cancellation は `verify` まで通っている（`ArchivePasswordVerification.swift:57-61`、`ArchiveSession.swift:253-259`）。

### 4.2 外した上限の下での最悪値

`ArchiveReaderOptions.kaitoFinder` は `maxEntrySize: .max` と `maxTotalUncompressedSize: .max` を**意図的に**
設定している（`Model/Session/ArchiveReaderOptions.swift:29`。製品判断として `Documentation/limitations.md:12-14`
と `Documentation/development.md:102-109` に明記）。よって問いは「上限があるか」ではなく
**「残った上限の下での最悪値はいくらか」**。

最優先の問い: 自動 thumbnail は**書庫が宣言した** `uncompressedSize` だけを見て 8 MiB 以下なら生成に進み
（`UI/ArchiveThumbnailProvider.swift:73`）、その先の展開は宣言サイズで打ち切らない
（`Extraction/ExtractionDestination.swift:183` のコメント）。**1 MiB と宣言して数十 GiB 展開される ZIP entry を、
一覧をスクロールして視界に入れるだけで** temp に書けるか。CRC 検証は書き込みの後なので嘘は最後まで判らない。
止まるとしたら何が止めるか（空き容量、QuickLook の timeout、temp directory の quota は無いように見える）。
失敗時に部分出力は unlink されるか（`:170-177`）。

ほかの問い: `Model/Listing/EntryTree.swift:72-113` は 100 万 entry でも cancellation 検査が無い。peak RSS と
wall はいくらか。KaitoKit 側の 256 MiB metadata 上限はアプリ側の tree を縛らないのではないか。
`Documents/ArchiveDocument.swift:243` の `read` は Progress も cancellation も無い。開く処理が固まったとき
利用者は中止できるか（window が出ないのか、Cmd-. が届くのか）。圧縮 tar の staging の 1 GiB 予備は
staging volume で見ているか。

再現: 宣言サイズを書き換えた ZIP を image 拡張子で作り、folder を開いてスクロールし、
`$TMPDIR/com.shunnag.KaitoFinder.Extraction` を `du -sh` の loop で監視する。100 万 entry の書庫で open /
tree / 初回描画を計測し、停止中に `sample` で main thread を見る。ハングの可視性は headless の
Mac mini（`ssh Mac-mini-M4.local` + `gui-run`）で `screencapture` を撮って証拠にする。

既にある緩和策: 上記の上限撤去は両言語で文書化済みの製品判断。thumbnail は暗号化・不完全・solid entry を除外し
最大 2 並列（`:71-98`）。`Documentation/verification/2026-09-16-scale.md`、
`KaitoFinderTests/Extraction/LargeArchiveTests.swift`、`KaitoFinderTests/UI/ScenarioScaleTests.swift` が
規模を既に扱っている。**thumbnail 経路だけは、どの文書も触れていない。**

### 4.3 展開先の決定と書き込み

syscall 規律（per-component `O_NOFOLLOW`、`safeComponents` 相当）は丁寧に書かれているので、価値は
**展開先の「選択」ロジック**にある。安全な writer でも向き先が違えば問題になる。

起点: `Extraction/ExtractionPath.swift:15-31`、`:48-86`、`Extraction/ExtractionDestination.swift:28-41`、
`:57-87`、`:167-196`、`:208-240`、`:264-281`、`:302-317`、`Extraction/ArchiveBatchExtraction.swift:12-26`、
`UI/ArchiveBatchExtractionController.swift:55-73`、`Model/Preferences/ArchivePreferences.swift:36`、`:106`、
`Extraction/ExtractionTemporaryDirectory.swift:12-54`。

中心の問い: `ArchiveBatchPlan.destinationFolder` は、top-level 名が 1 つで既定方針
`.whenMultipleTopLevelItems` のとき `base` を**包む folder を作らずに**返す。`extractionDestination != .ask`
では `base` が nil で、書庫の隣に展開される。**top-level が 1 つの書庫は、書庫のあるディレクトリに任意の名前を
直接書けるか**。home や Desktop から展開したとき、その名前が `.zshenv` / `.ssh` / `Library` / `*.app` になり得るか。
実物の書庫で決着させる。

### 4.4 quarantine と外部で開く

KaitoFinder は `com.apple.quarantine` を伝播し、ある分岐では**削除**する。さらに展開した temp を
`NSWorkspace.open` に渡す（拡張子で起動される）。起点: `Extraction/ExtractionQuarantine.swift:7-13`、`:34-39`、
`:46-52`、`Model/Session/ArchiveSession.swift:132`、`Extraction/ExtractionDestination.swift:52-53`、
`UI/ArchiveWindowController.swift:2290-2318`。
問い: quarantine を外すのはどの条件か、その判断は書庫の内容に影響されるか。`NSWorkspace.open` に渡る前に
拡張子や kind の検査はあるか。`.app` / `.command` / `.dmg` が渡り得るか。

### 4.5 password の扱いと vault

CLI の argv に当たるものが無いので、GUI での等価物を見る。起点: `Model/Session/ArchivePasswordVault.swift:14-25`、
`:43-46`、`:145-166`、`:168-194`、`UI/ArchivePasswordPrompt.swift:9`、`:19-21`。
問い: password はどこに、いつまで残るか。Keychain か memory か。vault の scope（書庫単位か全体か）は何で、
悪意ある書庫が他の書庫の password を引き出せる経路はあるか。log や crash report に出ないか
（KaitoKit 側では未発見だった）。

### 4.6 書庫が決めた名前の UI 表示

bidi / 不可視制御文字の処理は**ソース全体で 1 箇所も無い**（`202A|202E|2066|2069|200E|bidi|sanitiz|escape` の
grep が空）。GUI では terminal と実害が違うので、そこを分けて論じる。起点:
`UI/ArchiveConflictPrompt.swift:25`、`:37-40`、`UI/ArchiveEntryFormatter.swift:33`、
`UI/ArchiveEntryCellView.swift:16-19`、`UI/ArchivePasswordPrompt.swift:26-30`、`Model/ArchiveImportPlan.swift:73`。
問い: 名前が**確認ダイアログの文**に入るか（「上書きしますか」の対象名が偽装できるなら実害）。名前が
path 構築に使われる箇所はどこか。表示のみの偽装と、破壊的操作の同意を誤らせる偽装を区別して重大度をつける。
NSTextField の既定の bidi 処理で何が起きるかを実際に見る（スクリーンショットを証拠に）。

### 4.7 CI と配布経路

起点: `Tools/ci/common.sh:20-27`（兄弟 repo を unpinned `main` で clone）、`.github/workflows/ci.yml:95-100`、
`:50-52`、`KaitoFinder.xcodeproj/project.pbxproj:416-425`、committed `Package.resolved`（Sparkle 2.10.0 を
revision で pin）、`Info.plist:33-44`。
問い: 署名・notarization・Sparkle の feed と鍵はどこで扱われるか。CI に秘密はあるか、workflow の permissions は
何か。兄弟 repo を unpinned で引くのは意図的な上流破壊検知か（KaitoKit では意図的だった）。
pin する/しないは**運用コストの判断**なので、結論ではなく選択肢と費用を書く。

## 5. 必須の横断チェック

1. `../KaitoKit` の HEAD を記録する（audit branch で動いているかどうかで結果が変わる）。
2. KaitoKit 0.17.0 の 4 変更それぞれについて「影響あり / 無関係（根拠）」を**明示的に**書く。無関係の根拠は
   grep 結果でよい。
3. 4.1 の実効倍率を数値で出す。**これが KaitoKit 側の修正設計（reader 単位の予算）を見直すべきかの判断材料**に
   なる。倍率が大きい場合は、KaitoKit に共有予算の API を足すべきかの意見を書く。

## 6. 成果物の形式

`Documentation/verification/2026-10-26-security-audit.md` に次を含める。

- 判定表: `ID | 主張 | 判定（正しい / 部分的 / 誤り / 未実証）| 実リスク（誰が・既定設定か・最悪の結果）|
  重大度 | 対応（修正 / 文書のみ / 対応不要 / 裁定待ち）`
- 実証済みの各件に、再現コマンドと**実出力**（整形しない）。
- 「既に文書化済み / 到達不能 / 設計判断」として退けた項目とその根拠。
- 自分の検査の限界（調べていない領域、GUI で駆動できなかった経路、計測の揺らぎ）。
- 修正した場合は、修正前に失敗する回帰テストを添える（本プロジェクトのテスト規約に従う）。

## 7. 禁止事項

- `git commit` / `push` / branch 作成をしない。結果は作業ツリーと記録文書に残す。
- `brew install` その他のインストールをしない。必要なら指示書に「必要」と書いて止まる。
- 第三者の書庫実装 source を読まない（`../KaitoKit/Documentation/design.md` §10 の clean-room 規則は
  KaitoFinder 側の判断にも引き継ぐ）。黒箱としてツールを走らせるのは可。
- repository を汚さない（細工ファイルは `$TMPDIR` 以下に作る。KaitoKit の検査では別エージェントが repo root に
  試験書庫を 6 個残した）。
- `.app` を `open -a` で起動しっぱなしにしない（headless の mini では野良インスタンスが後の click を奪う）。
- GUI を駆動する前に画面を塞ぐものが無いか確認する（`~/.claude/CLAUDE.md` の Mac mini の節）。

## 8. 完了条件（リリース判定）

- 全領域について判定が書かれている（「対応不要」も判定）。
- 重大度 高 / 中 が残っていない。残る場合は、修正済みか、利用者の裁定待ちとして明示されている。
- 4.1 の実効倍率が数値で出ている。
- KaitoKit 0.17.0 の 4 変更に対する影響の結論が出ている。

## 9. 想定工数と最初の 30 分

全体で 5〜8 エージェント日。配分は 4.1 と 4.2 に半分、4.3 と 4.4 に 1/4、残りに 1/4。

最初の 30 分でやること: (1) `git -C ../KaitoKit log --oneline -1` と `git log --oneline -1` を記録。
(2) `Documentation/limitations.md` と `Documentation/verification/` の既存記録（特に `2026-09-10-extraction-safety.md`、
`2026-09-16-scale.md`）を読む。(3) `ArchiveReaderOptions.swift` を全部読む。
(4) 4.1 の「browse するだけで鍵導出が走るか」を先に決着させる（yes なら優先度が上がる）。
