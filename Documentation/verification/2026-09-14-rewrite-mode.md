# 検証: tar / tar.gz / 7z / LHA の再圧縮モード編集 — KaitoFinder `846ceed`

設計書 §7.7 の KaitoFinder 側。Codex に仕様(scratchpad `specs/kf-rewrite-mode.md`)を渡し、
差分を全部読み、自分のシェルで `xcodebuild test` を回した上で、守りの分岐を注入で確かめた。

## 結果

- `xcodebuild test`: **300 件 0 失敗**(新規 26 件)。Codex の sandbox は xcodebuild が
  exit 74 で走らないので、Codex の一回目は 4 メソッド 12 assertion が落ちていた。
  すべて fixture と期待値の側で、製品コードの修正はなかった(下記「分かったこと」)。
- 差分 +186 −39。`publish` は mode で `ArchiveUpdater` と `ArchiveRewriter` を選ぶだけ。
  取り消し(clonefile の slot は同じ `willPublish` で取る)、世代、再読込、UI の門番
  (`canAppend`)は一切変えていない。

## 注入で確かめた守り

| 注入 | 落ちたテスト |
|---|---|
| `publish` の暗号化再検査(capability 検査後の差し替え対策)を外す | `testRewritePublishRefusesEncryptionIntroducedAfterCapabilityProbe` |
| `preserveAttributes`(mode と全 xattr の写し)を呼ばない | `testTarAppendPreservesModeQuarantineAndEveryExtendedAttribute` |
| gzip magic を見ず常に `.tar` にする | tgz の capability / 文書編集 / magic 検定の 3 件 |

## 分かったこと(KaitoKit の挙動、実測)

- **包装 tar の判定は名前に依る。** `x.tar.bz2` / `x.tgz` / `x.tar.xz` / `x.tar.Z` は
  `format == .tar`(外側は区別されない)。同じ byte を `archive.zip` や拡張子なしで
  開くと `.bzip2` の単一ファイルになる。KaitoFinder の capability は先頭 magic で
  gzip だけを `.tarGzip` にし、bz2 / xz / Z / zst / lzma は `tar.bz2` 等の名前で
  読み取り専用にする。テストの fixture 名を `archive.tar.bz2` に直す必要があった。
- **7z の directory は末尾 `/` なし**(`existing`、kind `.directory`、size 0)。
  ZIP / tar は `/` 付き。期待値は kind で持ち、名前は `/` を落として比べる。
- `Localizable.xcstrings` の新しい文字列は `en` と `ja` の両方が要る
  (`testPasswordPromptAndNewMessagesHaveEnglishAndJapaneseTranslations`)。仕様で
  「日本語だけでよい」と書いたのは誤りで、Codex の修正で英訳を足した。

## 設計上の判断

- 暗号化された書庫は rewrite で**平文になる**ので、編集は capability で拒否する
  (`.encrypted`:「暗号化された書庫は、編集すると暗号化が外れるため変更できません」)。
  逃げ道は M6 の変換で、そこでは「新しい書庫は暗号化されません」を確認に含める。
- rewrite は `copyItem` を通らないため、原本の mode と全 xattr(Finder タグ・
  quarantine・空の値)を作業ファイルへ写してから `rename` する。ZIP 経路が
  `copyItem` から無償で得ていたものと揃える。
