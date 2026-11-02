# RAR5 version 1 の大きな辞書をアプリで扱う設定 — 2026-11-02

`cooViewer-aayi`。KaitoKit 0.19.0 が対応した RAR5 compression version 1 の実書庫を、KaitoFinder の reader オプションでも展開できるようにする。

## 設計

- 既定は従来の 1 GiB。`ArchiveExtractionDictionaryLimitGiB` に 1 / 8 GiB を保存し、型・整数・選択肢を検証する。
- 8 GiB は物理メモリが 32 GiB 以上の Mac だけで選択できる。保存値が 8 GiB でも、それ未満では 1 GiB を使う。
- 8 GiB では展開とパスワード確認を直列にし、reader 数による辞書メモリの増殖を抑える。1 GiB では従来の並列条件を変えない。
- 設定は次に開くアーカイブから有効。`ArchiveSession` は開いた reader の上限を保持し、パスワード採用・保存後の reload・分割 reader の差替えでも更新する。
- `ArchiveVerifiedOutput` は検証時の `ReaderOptions` から実上限を運ぶ。設定を変更したり、保存済み reader を採用したりしても、現在の UserDefaults だけで worker 数を決めない。
- 設定画面の「パフォーマンス」に選択肢を置き、2 つの新しい表示文字列を 26 言語へ追加した。「次に開くアーカイブから有効」の注記は既存の翻訳を使う。

これは 5 GiB の非2の累乗辞書が 8 GiB へ確保される実 RAR5 version 1 書庫を対象にする。8 GiB を超える辞書、RAR4 unpack 15/20/26 / custom VM、CAB Quantum は別の残課題。

## 自動検証

- `xcodebuild ... build`: 成功。
- `DictionaryLimitPreferenceTests`: 保存値、32 GiB 境界、通常 / verification reader、設定 popup、展開 / パスワード確認の直列化を確認。
- 関連 72 tests: 初回は成功。reader 差替え対応後は `ArchivePasswordVerificationTests.testPromptRetriesSeriallyBeforeParallelCandidateVerification` が 1 件失敗したが、同メソッドの個別再実行は成功した。
- 最終のパスワード・辞書設定・reader adoption・import verification 43 tests: **43 tests / 0 failures**。実 RAR5 version 1 の 1 書庫もこの実行に含む。
- `ArchiveReaderAdoptionTests`: **16 tests / 0 failures**。8 GiB で開いた後に設定を 1 GiB へ戻し、reader 採用では 8 GiB / 直列を保持し、1 GiB の新規 reader へのフォールバックでは並列へ戻ることを確認。
- `ArchivePreferencesUITests.testSettingsStringsHaveAllTwentySixTranslations`: 成功。
- `Localizable.xcstrings`: `python3 -m json.tool` で JSON として検証。
- 標準の全テストは **1,795 tests / 34 skipped / 4 failures**。4 件は日本語・フランス語・欧州ポルトガル語の新しい文言規約違反で、圧縮・展開の失敗ではない。修正後に `WordingAcceptanceTests` **50 tests / 0 failures**、`ArchivePreferencesUITests` **29 tests / 0 failures** を確認した。この全テストの後に追加した adoption 回帰テストと文言修正は PR の CI でも検証する。

## 実 RAR5 version 1 書庫

`DictionaryLimitPreferenceTests.testActualRAR5VersionOneUsesConfiguredDictionaryLimit` を使用する。
Xcode のテストプロセスへ渡すため、指定は `TEST_RUNNER_KAITOFINDER_RAR5_V1_ARCHIVE` と
`TEST_RUNNER_KAITOFINDER_RAR5_V1_SHA256`。変数がない通常の全テストでは skip する。

`.kaitoFinder` の保存設定を 8 GiB にして開き、1 MiB buffer で SHA-256 を計算した。
2026-11-02 の実行では、次の 2 書庫とも出力 5,368,709,120 byte と期待 SHA-256 が一致した。

| 書庫 | 出力 SHA-256 |
|---|---|
| `/tmp/kaito-rar5-v1-small/pattern-5g-v70.rar` | `2a3623bd4ff86f93545aac013ddb90cb15148831179c3f7dfb0e0145529d52dd` |
| `/tmp/kaito-rar5-v1-small/zero-5g-v70.rar` | `7f06c62352aebd8125b2a1841e2b9e1ffcbed602f381c3dcb3200200e383d1d5` |

ログ: `build/dictionary-rar5-v1.log`。`KAITOFINDER-RAR5-V1` の行と 2 回の `TEST SUCCEEDED` を確認した。
