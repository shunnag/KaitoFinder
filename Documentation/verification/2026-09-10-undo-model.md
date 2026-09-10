# undo モデルの実測(2026-09-10)

設計書 §12-3「undo をどう持つか」を潰すための実測。候補は当初 2 つ
(`NSFileVersion` による世代 snapshot / entry model 上の undo stack)だったが、
どちらも採らず、**書庫ファイルそのものを APFS clone で退避する**方式に決めた。
以下はその根拠となる 4 つの測定。

## 0. なぜ当初の 2 案を捨てたか

- **`NSFileVersion.addOfItem`** — この API は `NSDocument` の保存周期のためのもので、
  `preservesVersions` を意図的に false にしている本アプリとは前提が合わない。
  実体は `.DocumentRevisions-V100` への**ファイル全体のコピー**で、
  4 GiB 超の ZIP が実在する(`ditto` 破損の件で確認済み)以上、
  1 編集ごとにディスクを食い潰す。
- **entry model 上の undo stack** — 削除を取り消すには entry の byte が要る。
  byte を持たない「メモリ上の undo」は rename にしか使えず、削除に対しては嘘になる。

## 1. `commit()` は必ず inode を差し替える

GyoshukuKit の更新経路は clone → 書き直し → `replaceItemAt` で、
`ArchiveSession.reloadAfterMutation()` のコメントどおり `reopen()` では旧 inode を掴む。
つまり **編集前の書庫ファイルそのものが undo の自然な単位**である。

## 2. `backupItemName` は使えない — 退避先がユーザーのフォルダ

`replaceItemAt(_:withItemAt:backupItemName:options:[.withoutDeletingBackupItem])` は
「コピー無しで編集前ファイルを残す」点では理想的に見えるが、実測すると
**退避物は原本と同じディレクトリに置かれる**。

```
returned URL: …/work/Archive.zip
--- contents of the ORIGINAL's directory after replace ---
    Archive.zip~kf-undo
    Archive.zip
backup inode=87720379 == old original inode? true
```

`Archive.zip~kf-undo` がユーザーの書庫の隣に生える。Finder 上で見えるし、
クラッシュすれば残置される。Finder を名乗るアプリの挙動として不可。
**採用しない。**

## 3. `clonefile` は 1 GiB を 0.2 ms・ディスク 0 で退避する

同一ボリュームの `.itemReplacementDirectory` へ `clonefile(2)` する方式を実測。

```
original size: 1073741824
undo slot volume dir: /var/folders/…/TemporaryItems/NSIRD_clone_mn0F7H
clonefile rc=0 errno=0  elapsed=0.0002s
free delta = 0 MiB  (1024 MiB ならフルコピー、~0 なら clone)
slot size: 1073741824
after undo, original size: 1073741824 → 復元 OK
user directory now contains: ["Big.zip"]
```

1 GiB の書庫で **0.2 ms、空き容量の減少 0 MiB**。undo は
`replaceItemAt(original, withItemAt: slot)` で byte 完全に戻り、
**ユーザーのディレクトリには何も生えない**。退避先が temp なので、
クラッシュ時の残骸は OS が回収する。退避の実コストは
「編集で分岐した extent だけ」になる。

## 4. undo 登録は document を dirty にする — 抑制が要る

`NSUndoManager` に登録すると `NSDocument` が `updateChangeCount` を呼ぶ。
本アプリは `writableTypes` が空(commit は即ディスクに落ちるので「未保存」が存在しない)
なので、dirty になると閉じる際に**満たせない「保存しますか？」**が出る。

`groupsByEvent = false` で明示グループにし、通知が同期で飛ぶ状態にして測った
(run loop の無い素の測定では group が閉じず、通知自体が飛ばないため対照が無効になる)。

```
suppress=false  after register: isDocumentEdited=true   updateChangeCount calls=["0"]
suppress=false  after undo:     isDocumentEdited=false  updateChangeCount calls=["0", "1"]
---
suppress=true   after register: isDocumentEdited=false  updateChangeCount calls=["0"]
suppress=true   after undo:     isDocumentEdited=false  updateChangeCount calls=["0", "1"]
    undoMenuItemTitle=Undo  canRedo=true
```

`updateChangeCount(_:)` を no-op に上書きすると dirty は立たず、
`canUndo` / `canRedo` / メニュー項目名はそのまま生きる。抑制は必要かつ十分。

## 5. 非 APFS ボリュームでは実際に ENOTSUP が返る(実ボリュームで確認)

「clone できない書庫は undo を持てない」という分岐が机上の仮定でないことを、
実際に FAT ボリュームを作って確かめた。`hdiutil create -fs MS-DOS` で 20 MB の
ボリュームを作り、マウントして書庫を置き、KaitoFinder と同じ手順を踏む。

```
非 APFS 上の書庫:      /Volumes/KFTEST/Archive.zip
itemReplacementDir:   /Volumes/KFTEST/.TemporaryItems/folders.501/TemporaryItems/NSIRD_enotsup_LJVCez
同一ボリュームか:      true
clonefile:            rc=-1 errno=45 (Operation not supported)
ENOTSUP=45 EXDEV=18 → 判定対象に該当: true
```

分かったことが二つある。

- `.itemReplacementDirectory` は**ボリュームごとに追随する**。APFS の書庫なら
  `/var/folders/…/TemporaryItems/` を返すが、FAT の書庫では
  `/Volumes/KFTEST/.TemporaryItems/…` を返し、常に同一ボリュームになる。
  したがって `EXDEV` はこの経路では起きにくく、実際に返るのは `ENOTSUP` である。
- `clonefile` は errno 45 = `ENOTSUP` を返す。コードが分岐している値そのもので、
  `canUndoNextMutation` は実際に偽になり、確認ダイアログの経路は到達可能である。

つまり §7.6 の「非 APFS では undo slot を持てないので、commit の前に
取り消せない旨を確認する」は、実在する経路に対する設計であって保険ではない。

## 再現

測定に使った 3 本のプローブは `swiftc -O` で直接ビルドして走らせた。
2 と 3 は `FileManager` と `clonefile` のみ、4 は `NSDocument` のみで、
アプリ本体には依存しない。
