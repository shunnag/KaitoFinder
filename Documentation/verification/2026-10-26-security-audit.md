# セキュリティ・堅牢性監査の検証（2026-10-26）

`Documentation/2026-10-26-audit-instructions.md` の指示書に沿って実施した。HEAD は `10a7331`。
`../KaitoKit` は branch `fix/security-audit-2026-10-26`（検査開始時 `32205fc`。検査中に 0.17.0 候補の修正が入った。第 5 節）、
`../GyoshukuKit` は `6a0941a`。ローカルビルドは 0.17.0 候補に対して解決されるが、**CI は `main`（v0.16.0 相当）を
浅く clone する**（`Tools/ci/common.sh:20-27`）ので、0.17.0 の型や既定値に依存するテストは 0.17.0 が公開されるまで
CI でコンパイルできない。

**体制**: 7 領域に 1 エージェントずつ（読解と read-only コマンドのみ。ビルド・計測・GUI 駆動・commit は禁止）、
確認された所見ごとに敵対的反証 2 観点（`reachability` と `arithmetic`）で合計 45 エージェント。
実測は orchestrator が逐次実行した。

## 1. 判定表

| ID | 主張 | 判定 | 実リスク | 重大度 | 対応 |
|---|---|---|---|---|---|
| F-4.3-2 | 一括展開が作る包み folder が `com.apple.quarantine` を継承しない | **正しい**（反証 2/2 で生存） | 書庫のファイル名由来の名前を持つ `.app` bundle の **root に印の無い**状態を、既定設定の 1 操作で組み立てられる。中身には印が付くが root には付かない | 中 | **修正** |
| 4.6-F1 | 書庫が決めた entry 名が破壊的操作の確認ダイアログの**太字見出し**に無処理で入る | **正しい**（反証 2/2 で生存） | 名前に改行を入れると見出しの先頭行を攻撃者の文に差し替え、本物の「置き換えますか？」を下へ押し下げられる（`hasDestructiveAction` のボタンがある） | 中 | **修正** |
| 4.6-F5 | 書庫由来の文が改行ごと `informativeText` に入る | 正しい | 同じ helper で畳める | 低 | **修正** |
| 4.6-F3 | `design.md:1363` が「RLO 偽装拡張子を検出して警告する」を §9 の要件として書いているが実装が無い | **正しい**（反証 2/2 で生存） | 文書と実装の不一致。bidi の処理はソース全体で 0 件 | 低 | **文書を実装に合わせた**（裁定） |
| 4.6-F2 | RLO / 不可視文字で一覧の表示上の拡張子を偽装できる | 部分的 | icon と「種類」列が既定で真の型を示す | 低 | 文書化 |
| F4.4-8 | 0400 でも書庫型 intercept でも止まらない型が残る（`.terminal` の CommandString、`.sparseimage` / `.cdr` の mount、`.webloc` / `.url` / `.inetloc`） | **正しい**（反証 2/2 で生存） | 外部で開く経路に拡張子・kind の検査が無い。一時コピーは 0400 で quarantine を継承する | 低 | 文書化 |
| KDF-1 | reader を複数持つので KaitoKit の鍵導出予算が多重化する | 正しい（機構） | 「全選択 → 展開」1 回で新 reader は **V + 1 + P** 個（既定で 10 core 機 21 個 / 16 core 機 33 個）。総 CPU は core 数で並列化され、progress から中断できる | 低 | 文書化（KaitoKit 側で既定値と意味論を見直した） |
| KDF-7 | 0.17.0 の予算は正しい password の利用者も弾く（逆方向の回帰） | 正しい | 旧既定（`4 × 2^24`）では distinct-salt 書庫で起きた。**KaitoKit 側の修正で解消**（第 5 節） | 低 | 文書化 |
| F-4.2-E | thumbnail cache に上限も eviction も無い | 正しい | 一覧を長く操作すると単調に増える。1 件は 8 MiB 以下の画像の thumbnail | 低 | 対応不要（`limitations.md:16` の既存記載で足りる） |
| F-4.2-F | `EntryTree.swift:72-113` に cancellation 検査が無い | 部分的 | 100 万 entry の tree 構築中は中断できない。`tree(from:)` は Task 外の同期呼出も持つ | 低 | 対応不要 |
| F-4.2-G | `ArchiveDocument.swift:243` の read に Progress も cancellation も無い | 部分的 | 開く処理が固まったとき窓が出ない経路がある | 低 | 対応不要（要実測と記録） |
| F-4.3-8 | 包み folder の名前は攻撃者が選べる | 正しい | F-4.3-2 の quarantine 付与で `.app` 経路の実害は閉じる | 低 | 対応不要 |
| CI-5 | 差分検査の oracle（7zz / xz / zstd）の版が記録されない | 正しい | oracle が変わった日の緑/赤を後から説明できない | 低 | **修正**（KaitoKit の T1 と同じ 2 行） |
| CI-13 | 同一 run の 3 job が独立に兄弟 repo を clone するので、shard 間で異なる KaitoKit を試験した緑の run ができる | 正しい | 窓は数秒で、`common.sh:23-26` が各 job で 3 repo の HEAD を印字するので事後に検出できる | 低 | 対応不要 |
| CI-6 | GitHub Actions が tag pin（@v5 / @v4）で SHA pin されていない | 部分的 | 運用コストの判断。KaitoKit の T2 と**同じ 1 つの決定** | 低 | 利用者の裁定待ち（3 プロジェクトで揃える） |
| **4.2 の中心仮説** | 「1 MiB と宣言して数十 GiB 展開される ZIP entry を、一覧をスクロールして視界に入れるだけで temp に書ける」 | **誤り** | thumbnail の gate は `guard let size = entry.uncompressedSize, size <= 8 MiB`（`UI/ArchiveThumbnailProvider.swift:71-75`）で、**サイズ未宣言（nil）は guard を落ちる**。宣言サイズのある entry は KaitoKit が宣言値で打ち切る | — | — |
| F-V5 | 誤 password の再入力ごとに reader の予算が全額復活する | 正しい（機構） | vault 側の寄与は ×1。予算超過は再入力に化けない（下記） | なし | KDF-1 に統合 |
| CI-1〜CI-4、CI-12 | 署名・notarization が CI で扱われる / CI に秘密がある / permissions が広い / self-hosted runner で fork PR が走る / 供給連鎖の入口 | **誤り** | CI は GitHub ホスト runner のみ、secret 0 件、token は read-only、配布物を作らない。署名・notarization・Sparkle の鍵はすべて利用者の Mac の Keychain にある | — | — |
| 4.4 / 4.5 の他 16 件 | quarantine の伝播漏れ、vault からの横取り、log への password 漏れほか | 誤り・到達不能・既存の緩和策 | vault の key は解決済み path の完全一致で、列挙 API が存在しない。password は Keychain にあり log にも crash report にも出ない | — | — |

退けた所見は 49 件（うち「誤り」19 件、「設計判断として文書化済み」「到達不能」30 件）。

## 2. 実証した事実

### 2.1 thumbnail 経路は爆弾にならない（4.2 の中心仮説の反証）

- gate: `UI/ArchiveThumbnailProvider.swift:71-75` の `guard let size = entry.uncompressedSize, size <= 8 * 1024 * 1024`。
  `guard let` なので **nil は落ちる**。種類判定（`isImage`）より前にある。
- 既存テストで固定済み: `KaitoFinderTests/Extraction/ArchiveThumbnailTests.swift:203` が `entry("unknown.png", size: nil)` を
  列挙し、`:206-208` で `thumbnail(for:)` が nil・`isIdle` が true・temp root が作られないことまで検査している。
- KaitoKit 側（orchestrator が確認）: 宣言サイズのある entry は `Reader/EntryStream.swift:49` で `bytesRemaining = length` と
  なり `:146` で減算されるので、**宣言 1 MiB の entry が 1 MiB を超えて吐くことは不可能**。
- `uncompressedSize` が nil になるのは **gzip / bzip2 / xz / compress / brotli**（`Formats/SingleFile/SingleFileReader.swift:35-77`。
  zstd・lz4・lzma・lzip・pbzx はサイズを確定する）、recovery で extent 不明の ZIP entry（これは `isIncomplete` が必ず true）、
  RAR5 の `unpackedSizeUnknown` flag。いずれも thumbnail の gate で落ちる。
- 結論: サイズ未宣言の entry は `maxEntrySize: .max` / `maxTotalUncompressedSize: .max`（`Model/Session/ArchiveReaderOptions.swift:29`、
  製品判断として `Documentation/limitations.md:12-14` と `Documentation/development.md:102-109` に明記）の下で実際に無制限だが、
  到達するのは**利用者の明示操作**（preview / QuickLook / 外部で開く / drag out / ⌘C / 展開）だけで、
  いずれも `UI/ArchiveMaterializationController.swift:86-88` が Progress とシートを出し `:124` で cancellation を張る。
  ENOSPC は `Extraction/ExtractionDestination.swift:201-210` が投げ、`:178-181` の defer が部分出力を unlink する。
  残る欠点は「サイズ未宣言 entry では進捗 bar が出ない」こと（`Extraction/ExtractionService.swift:456-459`）。

### 2.2 鍵導出予算の実効倍率（KDF-1）

「全選択 → 展開」1 回で新しい reader は **V + 1 + P** 個できる。

| 段 | 新 reader 数 | 根拠 |
|---|---|---|
| password 検証 | V = `min(threads, entry 数)` | `Model/Session/ArchivePasswordVerification.swift:62` → `:37-52` → `:76` の `reader.reopen()` |
| 展開 snapshot | +1 | `Model/Session/ArchiveSession.swift:1058` |
| 並列展開 | P = `min(threads, bucket 数)` | `Extraction/ExtractionService.swift:213-216` → `Extraction/ParallelExtraction.swift:9-31`、`:76` |

`threads` は `ArchiveSession.swift:264-266`（既定で `min(activeLogicalCPUs, physicalMemory/1GiB)`）。
10 core 機で **21 個**、16 core 機で **33 個**。小さい書庫（< 64 entry かつ < 8 MiB）では P = 1 になる
（`ParallelExtraction.swift:26` の guard は AND、検証側 `:50` は OR）。drag out は主 reader 1 + slot 4 = 5 個。

付随して確定した事実:
- **誤 password の再入力に上限も backoff も無い**（`ArchiveSession.swift:201-251` の外 `while true` / 内 `while true`、`:218` が `open`）。
  ただし `Model/ArchivePasswordChallenge.swift:7-13` は `.passwordRequired` / `.wrongPassword` だけを再入力に写し、
  **`.limitExceeded` は throw する**ので自動で回り続けることはない。
- **password を入れずに一覧を見るだけでは entry の鍵導出は走らない。** thumbnail は await の前に暗号化 entry を除外する
  （`ArchiveThumbnailProvider.swift:70-72`。コメントが「session の password prompt に到達させない」と明記）。
- ただし**例外が 1 つある**: locked 文書を開くと `UI/ArchiveWindowController.swift:486` が `unlockArchive` を自動起動し、
  `Documents/ArchiveDocument.swift:272-284` が vault の password を自動投入する。header 暗号化 7z や暗号 catalog の `.sitx` では
  **ファイルを開くだけで追加入力ゼロの鍵導出が 1 回**走る。vault の key は解決済み path の完全一致（`Persistence/ArchivePasswordVault.swift:15-18`、`:58-61`）で
  列挙 API が無いので、**試行回数の乗数にはならない**（1 件 1 回）。外れたら vault から削除して実 prompt に落ちる。
- `hasEncryptedHeaders` の second reader（`ArchiveSession.swift:865-877`）は **鍵導出に到達しない**。`:872` の open は
  password nil で、`SevenZipFolderPipeline.swift:311` の `guard let password else { throw .passwordRequired }` が
  `keyCache.key`（`:316`）より前にある。コストは header の二重 parse だけ。
- **`.sitx` は document type として open 時に password prompt に到達する**ので、`maxStuffItXKDFWork` は
  指示書が仮定した「無関係」ではなく**影響あり**（指示書の仮説を反証）。

## 3. 修正（本記録の時点。commit はしていない）

1. **F-4.3-2**: `Extraction/ArchiveBatchExtraction.swift:130-133` で包み folder を作った直後に、書庫から取った
   quarantine を `ExtractionQuarantine.apply(_:to:)` で folder へ適用する。印の無い書庫では何もしない。
2. **4.6-F1 / 4.6-F5**: `Extraction/ArchiveFailureReport.swift` の局所関数 `singleLine` を `static` に引き上げ、
   `UI/ArchiveConflictPrompt.swift:24` の名前と `Model/ArchiveAlertText.swift:6` の文に適用した。
   既存の畳み方（1,024 文字で切り、改行を空白へ）をそのまま再利用し、新しい sanitize 規則は作っていない。
   **`Model/ArchiveErrorText.swift` の文言は変えていない**（wording のテストに触らないため）。
3. **4.6-F3**: `Documentation/design.md:1363` の未実装要件を削り、「表示名の双方向制御文字・不可視文字は加工しない」ことを
   §9 の制限として書き直した。`Documentation/limitations.md` に日本語と English で 1 行ずつ追加した。
4. **F4.4-8 / KDF-1 / KDF-7**: `Documentation/limitations.md` と `Documentation/development.md` に事実を記録した。
5. **CI-5**: `Tools/ci/common.sh` の `require_fixture_tools` が oracle の版を印字する（pin はしない）。

回帰テストは `KaitoFinderTests/Extraction/ArchiveBatchExtractionTests.swift`（quarantine の継承）と
`KaitoFinderTests/UI/ArchiveConflictUITests.swift`（改行入りの名前で見出しと説明文が 1 行になること）に追加した。
**修正前に 3 件すべてが失敗する**ことを確認している（quarantine が nil、見出しと説明文が日英とも 2 行）。

## 4. 検査の限界

- エージェントはビルド・計測・GUI 駆動を禁止されていたので、所見は「コード読解で確定」か「要実測」である。
- **GUI では駆動していない。** NSAlert の実描画（太字見出しの改行が複数行になり、本物の問いが下へ押し下げられること）は
  headless の unit test で「1 行に畳まれること」を固定する形に置き換えた。`.terminal` の CommandString が macOS 27.2 でも
  open 時に実行されるか、`.sparseimage` が mount されるかは**未実測**（細工書庫は `$TMPDIR` に用意済み）。
- `.app` の root に quarantine が無い場合に Gatekeeper と app translocation がどう振る舞うかは**未実測**。
  修正は「engine 自身の適用規則と一貫させる」ことを根拠にしており、OS の挙動に依存しない。
- 4.2 の規模（100 万 entry の open / tree / 初回描画、圧縮 tar staging の予備容量）は既存の記録
  （`Documentation/verification/2026-09-16-scale.md`）の範囲を越えて測っていない。
- xcodebuild の全 suite は orchestrator が実行した（結果は本記録の末尾に追記する）。

## 5. KaitoKit 0.17.0 の 4 変更に対する影響（必須の横断チェック）

| 変更 | 影響 | 根拠 |
|---|---|---|
| `maxSevenZipEntryKDFWork`（既定 `16 × 2^24`、**reader と password の組ごと**） | **影響あり** | 実効倍率 V+1+P（21〜33）。予算は別の password を設定すると戻り、`reopen()` / `open()` は満額で始まる。旧既定 `4 × 2^24` では distinct-salt 書庫で正規利用者が弾かれた（KDF-7）が、新しい既定と意味論で解消 |
| `maxStuffItXKDFWork`（既定 `2^22`） | **影響あり**（指示書の「無関係」仮説を反証） | `.sitx` は document type で、open 時に password prompt に到達する |
| `ExtractionOptions.preserveSetUserIDBits` | **無関係** | `grep -rn "ExtractionOptions" KaitoFinder/` が 0 件。KaitoFinder は独自の writer を持ち KaitoKit の展開器を呼ばない |
| resource fork entry が既存 data fork の metadata を書き換えない | **無関係** | 同上 |

依存は `KaitoFinder.xcodeproj/project.pbxproj:428-437` のローカル path 参照で**版の pin が無い**。
CI は兄弟 repo を unpinned `main` で clone する（`Tools/ci/common.sh:21-26`。`ci.yml:44-46` と
`development.md:83` が意図的な上流破壊検知だと明記）。**したがって 0.17.0 の公開前は、0.17.0 に依存する回帰テストを
CI に置けない**（リリース順序の制約）。
