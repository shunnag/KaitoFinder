# 大きな書庫の編集で書き換える量を最小にする計画と、見送り項目の実装順（2026-09-24）

[総合レビューの計画](2026-09-24-review-plan.md)の「見送り」を順に実装する。中心は、大きな書庫へファイルを追加・削除・
改名したときに、実際に書き換えなければならない場所・量・再圧縮の範囲を最小にすること。
調査は 6 観点の読み取り専用の調査と反証（13 エージェント）で行い、主張はコードの行で反証にかけた。一部の数値
（500k 件の tar の open 1,633 ms、tar.gz の区切りの試作など。試作は liblzma と 4 MiB の block で代用）は再現待ちで、
各段の前に実測で確かめる。

## いまの動作（要点）

- ZIP の即時編集（updater）は再圧縮しない。追加は既に最小（APFS の clone 上で旧 CD の位置へ新しい record を書き、CD と EOCD を書く）。
  削除・長さの変わる改名は、最初の変更より後ろの record を 1 件ずつ pread / seek / write で移し、CD を 1 件ずつ組み直す。
  50 万件で 1 件削除 7.3 s のうち、バイト量（数十 MB）ではなく件数ごとの固定費が大半（open 1.55 s、commit 3.5 s、
  公開前の検証と再読み込みで各 0.45 s）。
- tar / tar.gz / tar.bz2 / tar.xz / 7z / LHA の編集は、どの操作でも全 entry を復号して再圧縮する（ArchiveRewriter）。
  改名 1 件でも同じ。7z の solid は非 solid に、LHA は level 2 に、tar の uid/gid は 0 に変わる。
- 公開前の検証が浅い: `foo.tar.gz` などは作業ファイルが `archive.gz` になり、中身の tar を読まずに magic だけで公開する。
  ZIP は CD だけ（local header は遅延）、7z / LHA は header だけ。単一ファイルの公開では、出力の entry を計画と照合しない。
- 既存の不具合: MacLHA の MacBinary の member を含む LHA は、書き込み可能と判定されるのに保存で必ず失敗する
  （-pm2- や未対応の 7z coder も同様）。改名した ZIP の entry は、無効化した Unicode Path extra に古い名前が残る。

## 書き換えなければならない最小量

| 形式 | 追加 | 削除 | 改名 |
|---|---|---|---|
| ZIP | 新しい record + CD + EOCD（既存の record は読まない・動かさない） | 最初に削除した record より後ろを詰める（再圧縮なし）+ CD + EOCD | 長さが同じ: local header と CD の該当部分だけ。変わる: 後ろを詰める / ずらす + CD |
| tar | 終端の 2 block と詰め物を切り、新しい member を末尾へ | 後ろの member を詰める（再圧縮なし） | header の block 数が同じなら header だけ。変わるなら後ろをずらす |
| tar.xz（自前の出力） | 終端を含む block（≦16 MiB。終端が二つの block にまたがることがある）だけ再圧縮 + index | 変更を含む block だけ再圧縮し、他の block は圧縮済みのまま移す + index | 同じ |
| tar.bz2（自前の出力） | 終端を含む stream（≦4.5 MB。二つにまたがることがある）だけ再圧縮 | 変更を含む stream だけ再圧縮 | 同じ |
| tar.gz（自前の出力） | 終端を含む 1 MiB の区切りから再圧縮 | 変更を含む区切りから、変更の終わり + 32 KiB 以降の最初の同期点まで再圧縮。以降は圧縮済みのまま移し、CRC32 は結合で求める | 同じ |
| 他ツールの tar.gz / 単一 stream の bz2 / 単一 block の xz | 最初の編集だけ全体を再圧縮して自前の区切りに変換し、以降は上の通り | 同じ | 同じ |
| 7z | 新しい packed stream を header の前へ + header と開始 header | 後ろの packed stream を詰める（再圧縮なし）。directory や空ファイルなど stream のない entry は header だけ。solid folder の一部を消すときはその folder だけ再圧縮（非 solid に分けると大きくなり後ろが上へずれるため、その場では動かさず新しいファイルへ書く） | header と開始 header だけ |
| LHA | 終端の 0 byte を切って member を追加 | 後ろの member を詰める | header の長さが同じなら header だけ（level 0/1 は level 2 で書き直す） |

さらに自前の書き込みを「区切りを member の先頭でだけ切り、tar の終端を独立した最後の区切りに置く」形にすると
（サイズの差は実測で +0.01〜−0.17%）、追加は古いデータを一切再圧縮せず、区切りを丸ごと持つ member の削除は
xz / bzip2 で再圧縮なしになる。

採らない方式: 削除した record を穴として残す（削除した中身がファイルに残り、local header を順に読む展開器が止まる）、
旧 CD の後ろへ追記する、原本を直接書き換える（原子性を失う）、xz の stream padding や gzip の複数 member で穴を埋める
（Python tarfile などが途中で黙って止まることを実測）。

## 方針（この計画で決めたこと）

1. 検証は書き換えた量に比例させ、弱めない。公開前に、再圧縮した区切りは復号して確かめ、そのまま運んだ範囲は
   原本と digest を比べ、出力の entry の件数・名前・種類・サイズを計画と照合する。作業ファイルは元の拡張子
   （`.tar.gz` など）を保つ。
2. 触らない member はバイト単位でそのまま運ぶ（tar の uid/gid・uname・xattr・拡張 header、7z の solid・フィルタ、
   LHA の header level）。「所有者 ID を保存」の設定は、ディスクから追加する member にだけ働く（設計どおりの意味に戻す）。
3. tar / LHA / 7z の追加は末尾へ（tar -r と同じ）。いまは先頭に置いている。
   2 と 3 は既定の動作の変更（格納順の列と、既定で 0 にしていた tar の uid/gid）。2026-09-25 に利用者の了承を得た。
   どちらも推奨の動作を既定にし、設定で従来の動作へ切り替えられるようにする（P2 で追加し、P4・P5 でも同じ設定に従う）。
   - 追加した項目の位置: 末尾（既定。追加だけなら既存のデータを書き直さない）/ 先頭（従来。書庫全体を書き直し、
     圧縮 tar・7z・LHA では全体を再圧縮する）。
   - 変更しない tar 項目の所有者 ID: そのまま保つ（既定）/ 0 に戻す（従来。全項目の header を書き直すため、
     圧縮 tar では全体を再圧縮する）。既存の「所有者 ID を保存」は、ディスクから追加する項目にだけ働く設定として
     文言を区別する。
6. 暗号化の設定・変更・解除は再圧縮しない。ZipCrypto / AES は圧縮済みの payload を包むだけなので、復号して
   暗号化し直すだけにする（いまは全 entry を deflate し直している）。7z の AES も同じ考え方で P5 に含める。
7. 編集は公開用の作業ファイル 1 つへ直接書く（いまは作業コピーと updater の clone の 2 つ。APFS 以外では全体の
   コピーが 2〜3 回）。mode・quarantine・xattr の復元はアプリ側で行う（既存の試験で担保されている）。
4. 他ツールの圧縮 tar は、最初の編集で自前の区切りへ変換する（その回は今と同じ費用）。ビット単位の継ぎはしない。
5. 出力のバイト一致の試験は、出力が変わらないと約束する経路（ZIP の書き直しの高速化、LHA の並列圧縮など）に使う。
   出力の形を変える経路（tar の区切り、追加位置）は、他の展開器での互換試験で担保する。

## 実装の順番

依存関係と効果の大きさで並べる。各段は計測 → 仕様 → Codex による実装 → 全件テストと計測 → コミットの順に進める。
P3 の仕様の前に、区切りの継ぎの試作を GyoshukuKit の実際の出力で再実行する。

| # | 内容 | リポジトリ |
|---|---|---|
| P0 | 公開前の検証を実質化する（元の拡張子の作業ファイル、ZIP の local header の検証（`lazyLocalHeaders: false`）、entry の計画との照合、検証した記述子での同一性の取得）。書き込み可能の判定と保存の不一致（MacBinary、未対応の方式）を直す。改名後の Unicode Path extra の古い名前を 0 で埋める | KaitoFinder, GyoshukuKit |
| P0b | 計測: 各段（updater の open・remove・commit、置換、公開前の検証、再読み込み、保存時モードの計画と保存後の準備）の時間を PerformanceProbeTests に出し、commit を sample する。tar / 7z / LHA の編集も 10 万・50 万件と大きな本文で測る | KaitoFinder |
| P1 | ZIP の大規模編集: KaitoKit の型付き raw 範囲 API（entry の同一性検査を省くなら SPI）と formatSpecific の共有、CD の一括読み取りと検証結果の再利用、連続範囲の一括移動とバッファ付きの CD 出力、削除だけのときの名前表の省略、置換は「詰めてから追記」にして二重書き込みを解消（KaitoKit による追記分の照合は残す）、作業ファイル 1 つへの直接の書き込み、検証した reader の再利用、保存時モードの全体検査は残して安くする（key の一度だけの計算、formatSpecific を複製しない） | 3 つとも |
| P1b | 暗号化の設定・変更・解除を再圧縮なしで（ZIP）。AES の鍵の導出（entry ごとの PBKDF2）を並列にする | KaitoKit, GyoshukuKit, KaitoFinder |
| P1c | 編集前の全件のパスワード確認（`verifyBeforeEditing`）の鍵の導出を並列にする（50 万件の AES で直列 152 s）。[KaitoFinder 実装・検証](../verification/2026-09-25-p1c.md)。完了（a113d94） | KaitoKit, KaitoFinder |
| P1d | 50 万件の ZIP の編集に残る全件の名前表の作り直しを無くす。GyoshukuKit bfb2980（P1d-G）、KaitoFinder 7b623b4（段 A0）・96a2bc5（S33 段 A1–A6、保存前の全件検査を差分の検査に置き換え。利用者の判断 3）[実装と検証](../verification/2026-09-26-p1d-a.md)。完了。受入計測 AA5–AA9 合格（500k の改名の mutate 470 → 60 ms、5 件の保存 5.2 → 2.5 s） | GyoshukuKit, KaitoFinder |
| P2 | 非圧縮 tar の updater（追加・削除・改名を再圧縮なしで）。GyoshukuKit efdb651・da0af7b（FAT32 / exFAT の修正）、KaitoFinder S13 [実装と検証](../verification/2026-09-26-p2-tar-update.md)。受入計測も合格（B-P2 を採り直して比較） | GyoshukuKit, KaitoFinder |
| P3 | 圧縮 tar の区切り単位の編集。KK d35f2da / GK d5c51b3、KF S16 [実装と検証](../verification/2026-09-26-p3-compressed-tar-update.md)。受入計測も合格（tar.bz2 の 10 万件の open の短縮 0.93 倍は見込み 0.7 倍に届かず、記録） | 3 つとも |
| P4 | LHA: member ごとの並列圧縮、raw のまま運ぶ編集。KaitoKit d171f27（P4-K）、GyoshukuKit 5faab4b（並列 LH5）・6e7cd9b（LHAUpdater）、KaitoFinder ac5cab9（S21）[実装と検証](../verification/2026-09-26-p4-lha-update.md)。完了。受入計測は payload の `updater_open` が約 5 ms 超過（逸脱として報告）のほかは合格（ce96ec5） | 3 つとも |
| P5 | 7z: header だけの改名、追記だけの追加、詰めるだけの削除（solid の一部削除はその folder だけ再圧縮）、AES の掛け直しを再圧縮なしで。KaitoKit ef06e22（P5-K）、GyoshukuKit 52655cb（P5-G。属性の無い書庫への追加は 7zz と同じく属性を付けない）、KaitoFinder 786ec4c（S25）[実装と検証](../verification/2026-09-26-p5-7z-update.md)。完了。KaitoFinder の受入計測も合格（7a77a08。本文 256 MiB のパスワードの変更 11.6 s → 0.49 s） | KaitoKit, GyoshukuKit, KaitoFinder |
| P6 | 取込み・新規作成・移動の進捗のバイト化。GyoshukuKit b9da4bc（P6-G）・a5cb92c（AC-G7 の記録）、KaitoFinder 0e770d4（P6-A）・6aff545（受入計測）[G の記録](../../../GyoshukuKit/Documentation/verification/2026-09-27-p6g-progress.md)・[A の記録](../verification/2026-09-27-p6a-progress.md)。完了。AC-G7 は `--progress` の tgz small 1.38 倍・headers 1.25 倍（上限 1.25）を報告、S38 だけの lha +4.5 % は S40 で解消 | GyoshukuKit, KaitoFinder |
| P7 | 小ファイル多数の作成の並列先読み（上限 4 本、Step 0-P7 の門に合格）。GyoshukuKit 244a9c2（P7-G）・8e35eba（修正: ZIP の出力の一括の書込み、空の一括追加は何もしない）・1223a61（AC-G7）、KaitoFinder 9aa3872（P7-A）・a0b0354（受入計測）。完了。5 万件の zip の作成 1.28 s（7zz 1.63 s）、取込み・作成の mutate は zip 0.43 倍・tar.gz 0.46–0.59 倍。7z の mutate 1.05 倍と、txz・7z の batch を recursive と比べる条件（列挙の分を含む）は報告 | GyoshukuKit, KaitoFinder |
| P8 | 検索の絞り込みを MainActor 外で計算。KaitoFinder b450765（S34）[実装と検証](../verification/2026-09-26-p8-search.md)。完了。AC-M は M6 の 1 行（負荷 22–26 の回の 1.32 倍、上限 1.3）のほかは合格 | KaitoFinder |
| P9 | 圧縮の並列数の設定。S27 [実装と検証](../verification/2026-09-26-p9-threads.md)。完了（500ce7a） | KaitoFinder |
| P10 | 現在のフォルダへの移動（戻る・進む）と ⌘J の表示オプション。既定は「フォルダに移動」（利用者の判断）。KaitoFinder 4d4be0b（S35 = P10-a）・41d48f0（S36 = P10-b）[実装と検証](../verification/2026-09-26-p10-navigation.md)。完了。実のキー入力（AC-a5）と host を前面にする GUI の試験は、利用者が Mac の空いた状態で `Tools/verify_ui_integration.py` と `Tools/verify_finder_interactions.py --focused` を流す。AC-a7 は合格（50 万件で移動 2.4 ms・戻る 0.5 ms・⌘↑ 0.7 ms） | KaitoFinder |
| P11 | zstd の復号。KaitoKit 823ad46（Stage 1–3、256 MiB の tar.zst の open 0.56 倍、5 万件の method 93 ZIP の展開 0.39 倍）[検証](../../../KaitoKit/Documentation/verification/2026-09-26-zstd-p11.md)。完了 | KaitoKit |
| P12 | 分割巻の保存で重複する全体の読み取りを減らす（設計上必要な証明は残す）。完了（71549c2・e48d8ad、反証レビューと受入計測に合格） | KaitoFinder |
| P13 | tar の `\` を含む名前の展開（tar ではただの文字として扱う）、変換で受け取る名前の規則を出力形式の決定後に適用。完了（54c2b8d） | KaitoFinder |
| P14 | tar.xz の block の大きさ。[仕様](specs-2026-09-26/P14.md)（利用者の判断: 4 MiB に詰める上限と 16 MiB の片の二つ）。GyoshukuKit b132551・67a22e8（受入計測の記録）。完了。受入計測は全 AC 合格（小さなファイルの多い tar.xz の中央の削除・改名 4.7–5.6 s → 0.9 s、payload の改名 21 ms、作成 small 0.50 倍・payload 0.68 倍、サイズ +3.4〜11.8 %） | GyoshukuKit |

分割巻の一部の巻だけを書き直す公開は、クラッシュ時の整合性の中核に触れるため、P12 の後に改めて判断する。


## 状態（2026-09-27 08:20）

P0–P14 は全て実装・検証・コミット済み（push・main への merge・release はしていない）。最終の組 KaitoFinder a0b0354（製品は 9aa3872）・
GyoshukuKit 1223a61（製品は 8e35eba）・KaitoKit 823ad46 で、アプリの全件 1,701 件（予期しない失敗は、host を前面にする必要のある GUI の試験と
ネイティブのドラッグなど 8 件だけ）、GyoshukuKit の全件 583 件（失敗 0）。
利用者の確認（2026-09-27）: `python3 Tools/verify_ui_integration.py` は全ての組が成功（commands 75 件・native-save 5 件・履歴の 4 件）、
`python3 Tools/verify_finder_interactions.py --focused` は 15 件すべて成功。前面に頼っていた GUI の試験 3 件と、ANSI の位置のキーコードを固定していた
キー入力の試験を直した（86d92e4・1e58a79）。逸脱の一覧は最終報告（会話）と各検証記録。

## 状態（2026-09-27 00:05）

Codex の利用上限の後、利用者がクレジットを足して作業を再開した（2026-09-26 13:37）。利用者の判断（同日）: P10 の既定は「フォルダに移動」、
P1d の判断 3 は差分の検査に置き換え、P14 は二つの上限、P5-A の新しい注意書きは加える。
コミット済みの先頭: KaitoKit 823ad46（P11 まで）、GyoshukuKit 67a22e8（P5-G 52655cb、P14 b132551）、KaitoFinder は S21 ac5cab9・ce96ec5、
S33 96a2bc5、S34 b450765、S35 4d4be0b、S36 41d48f0、S25 786ec4c。最新の三つの組での全件は、96a2bc5 の時点で 1,563 件・失敗 0。
残り: S38（P6-G、実行中）→ S39（P6-A）→ Step 0-P7 → S40（P7-G）→ S41（P7-A）、
利用者の GUI の確認（`Tools/verify_ui_integration.py`、`Tools/verify_finder_interactions.py --focused`）。
`~/GitHub/KaitoKit-p11` は worktree の登録を外したが、sandbox の制限で directory を消せなかった（中身は不要）。

## 状態（2026-09-26 10:00）

実装は Codex の利用上限（`try again at Sep 29th, 2026 8:40 AM`）で止まっている。コミット済みの段はそれぞれの検証記録にある。残りの段の仕様と指示文は [specs-2026-09-26](specs-2026-09-26/README.md)、計測のデータは [verification/data/2026-09-26](../verification/data/2026-09-26/README.md)。再開の順:

1. GyoshukuKit: branch `feature/2026-09-24-review` の 6e7cd9b で `git stash pop`（stash の名前は「S24 (P5-G) WIP …」。
   `SplicedArchiveOutput` に一時ファイルの範囲の区間 `.scratch` を足す途中の修正と fixture の取り込み）。途中の編集なので、戻した直後は
   `swift build` が通らない可能性がある。同じ Codex thread に、まず `.scratch` の実装と試験を仕上げてから build するよう指示して P5-G を続ける。オーケストレータの判断（ORDER-P4-P5 §1.1 の改訂）: `.scratch(SplicedScratchFile, Range)` を足し、
   同じ一時ファイル・同じ範囲の区間を「変わらない prefix」として扱う。`generated` は従来どおり変わったとみなす。
2. KaitoKit-p11（P11 = S37）: Stage 3 の実装と絞った試験までは済んだが、しきい値の掃引の途中で止まった。**掃引の script
   （`.build/p11/stage3/build-sweep.sh`）は source の定数を書き換える**ので、`ZstdSequenceTable.swift` の `defaultPairTableThreshold` が
   掃引の途中の値（2048）のままになっている（第 2 回で選んだ値は 32,768。Stage 2 の source の控えは `.build/p11/stage2-source`）。
   thread を再開するときは、最初にこの定数を確かめて戻させ（掃引をやり直すなら script が最後に選んだ値を書き戻すこと）、その後で
   掃引・V1–V8・最終の門を続ける。この worktree は中途の状態のままコミットしない。
3. KaitoFinder: S21（P4-A）→ S33（P1d-A。S21 の後に B-P1d を採り直す）→ S34（P8）→ S35・S36（P10、利用者の了承が要る）→ S25（P5-A）→
   S38–S41（P6・P7）。P14-G（GyoshukuKit）は仕様あり・利用者の判断待ち（S24 の後、S38 の前の案）。
（確認: 本線の組み合わせ KaitoFinder 31509ff・GyoshukuKit 6e7cd9b・KaitoKit 0cbd809 で、アプリの全件 1,531 件。失敗は画面ロック中の既知の GUI 系 9 試験だけ）

4. 実 disk の試験（hdiutil の FAT32 / exFAT / HFS+）は Codex の sandbox では動かず、オーケストレータの検証でだけ実行される（efdb651 の exFAT の不具合はそこで見つかった）。各段の検証で必ず回す。
