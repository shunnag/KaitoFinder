# 取り消しの実装検証(2026-09-10)

設計 §7.6 の undo モデルを実装した際の検証。仕様の誤りが一つ、実装側の
弱点が一つ見つかっている。

## 1. 退避地点は `commit()` ではなく `willPublish` だった

最初の仕様には「`ArchiveUpdater.commit()` の直前で clone を取る」と書いたが、
これは append 経路の誤読だった。`ArchiveImportTransaction.run` の実際の流れ:

```
23  .KaitoFinder-add-<uuid>/ を書庫の隣に作る
28  copyItem(原本 -> 作業コピー)
29  ArchiveUpdater.open(url: work)     ← updater が触るのは作業コピー
45  updater.commit()                    ← 作業コピーの inode を差し替える。原本は無傷
46  ArchiveReader.open(url: work)
47  try willPublish?()                  ← ★ 正しい退避地点
49  guard identity(archive) == original
54  rename(work.path, archive.path)     ← 原本が置き換わる唯一の瞬間
```

原本は 54 行目まで触られない。`commit()` を基準にすると作業コピーの状態を
退避してしまう。`willPublish` は既に `ArchiveImportTransaction.run` の引数で、
`ArchiveSession.append` も転送済みだったので、**`ArchiveImportTransaction.swift`
は無変更**で済んだ。

## 2. 退避先は実ユーザーのフォルダでも同一ボリュームになる

`2026-09-10-undo-model.md` の測定は `/var/folders` 配下同士だったため、
実利用の条件で測り直した。

```
archive:              /Users/nagash/Downloads/kf-probe/Archive.zip
itemReplacementDir:   /var/folders/…/TemporaryItems/NSIRD_vol_hh2oNd
same volume?          archive dev=16777229  slotdir dev=16777229  -> true
clonefile:            rc=0 errno=0 → 成功
undo swap:            復元後 size=4194304 → OK
ユーザーフォルダの中身: ["Archive.zip"]
```

Apple Silicon の macOS では `/Users` と `/var/folders` が同じデータボリュームに
あるため、`.itemReplacementDirectory` は同一ボリュームに解決される。
代替の置き場所を用意する必要はない。

## 3. 退避地点の変更から出てくる二つの罠

どちらも「テストが緑でも実装が間違っている」形になりうるので明示した。

- **clone 失敗で `willPublish` から throw してはいけない。** throw すると
  rename の前に append 全体が中止される。「このボリュームでは取り消せない」が
  「ファイルを追加できない」に化ける。ENOTSUP / EXDEV では slot を作らず、
  取り消せない旨だけ記録して追加は通す。
- **フック後に失敗したら slot を捨てる。** 49 行の identity 検査と 54 行の
  `rename` はまだ失敗しうり、その場合原本は無傷。公開されたか
  (`addedPaths` が空でないか)で登録と破棄を分ける。

## 4. テストが罠を捕まえることの証明(回帰注入)

25 件のテストが本物か、実装に故意の欠陥を入れて確かめた。三件とも、
**対応するテストだけ**が落ちた。

| 注入した欠陥 | 落ちたテスト |
|---|---|
| `published` の区別を消して常に登録する | `testFailureAfterCloneDiscardsSlotAndRegistersNoUndo` |
| `updateChangeCount` の抑制を外し `super` を呼ぶ | `testUndoRegistrationUndoAndRedoNeverDirtyDocument` |
| ENOTSUP を `nil` でなく throw にする | `testUnsupportedCloneAllowsAppendAndClearsStaleHistory` |

## 5. 未了 — メニュー文言のローカライズ

`ArchiveUndoManager.undoMenuTitle(forUndoActionName:)` と `AppDelegate` の
編集メニュー項目が日本語をハードコードしている。アプリの文字列カタログには
en 訳があるので、英語環境でも「取り消す」が出てしまう。仕様側で
「メニューが『取り消す — 追加』と読めるように」と指示したのが原因。
**M3 の delete / rename UI で同じメニュー周りを触るので、そこで直す。**

素の実行ファイルで AppKit の既定文言を測ろうとしたが、bundle が
再ローカライズされないため両ロケールとも `Undo 追加` を返し、対照にならなかった。
実 .app での表示はこの環境では確認できない(画面収録とアクセシビリティが
拒否されているため)。
