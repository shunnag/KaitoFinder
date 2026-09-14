# 検証: ArchiveRewriter(全面書き直しの更新器)— GyoshukuKit `0c1ee85`

設計書 §7.7 の実装。Codex に仕様(scratchpad `specs/rewriter.md`、134 行)を渡し、
差分を全部読み、自分のシェルで `swift test` を回した上で、守りの分岐が本当に効くかを
注入で確かめた。

## 結果

- `swift test`: **159 件 0 失敗**(新規 35 件)、警告なし。Codex の sandbox は
  `swift build` の manifest 段階で module cache に書けず失敗するため、Codex 側の
  数字は `--disable-sandbox` と cache の付け替えで出したもの。ここでの数字は素の環境。
- 差分: `ArchiveRewriter.swift` 411 行、`ArchiveEditing.swift` 13 行、
  `ArchiveWriter.swift` は `addEntry` を internal に、`appendedPaths` を全形式で記録。
  `ArchiveUpdater` は protocol 適合の 1 行のみ。KaitoKit は無変更。

## 注入で確かめた守り

| 注入 | 期待 | 結果 |
|---|---|---|
| 公開直前の `checkUnchanged` だけを外す | — | 35/35 通る。`finish()` 前の照合が同じ窓を塞いでいる |
| carry 後の照合を**両方**外す | 原本改変の検出テストが落ちる | `testSourceModifiedDuringCarry…` ほか 8 件が落ちた |
| carry を index 降順にする | 順序・solid の検定が落ちる | 6 件(五形式の fixture + solid 7z)が落ちた |
| `perform` の失敗時 `cleanup()` を外す | 後始末の検定が落ちる | 6 件(暗号化・破損・原本改変・O_EXCL)が落ちた |

`finish()` 後の再照合は、前の照合と同じ窓を二重に塞ぐ保険で、単独では検定できない。
残してある(害はなく、`finish()` の間に原本が入れ替わる窓を狭める)。

## 仕様との差

- Codex の質問で決めた点: `tar -cf x.tar .` の root directory(正規化後の名前が空)は
  `entryNames` に残しつつ出力しない。実名へ改名された時だけ通常 directory として運ぶ。
  ファイル・symlink の空名は open 時に `unrepresentable`。
- hard link の参照先は link より**前**の index に限る(KaitoKit の
  `hardLinkTargetIndex` はそうなっている)。後方参照は `unrepresentable`。

## 分かったこと

- KaitoKit は solid 群の decoder を連続した `stream()` の間で保持する(7z は
  folder ごとの `SevenZipFolderCoordinator`、RAR は `solidState`)。index 昇順に
  一つの reader から読めば、solid 群は一度しか復号されない。降順にすると
  solid 7z の変換は落ちる(上の注入)。
- `.tgz` は KaitoKit が `format == .tar` と報告する(実測、probe パッケージ)。
  外側の gzip は KaitoFinder が先頭 magic で判定する。
