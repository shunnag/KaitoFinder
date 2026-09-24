# 分割アーカイブの編集拒否（M0）

検証環境: macOS 27.2、arm64。設計は [分割アーカイブの編集と保存時の書き込み](../pending/2026-09-23-split-archive-deferred-save.md) の M0。

## 再現した問題

- `7zz a -v100k -mx0` で作った `s.7z.001`〜`.005`（各 102400 byte、最終巻 90561 byte）の `.001` を開いて
  ファイルを追加すると、書き直した書庫全体が `.001` だけに rename され（500221 byte）、`.002` 以降は旧いまま残った。
  KaitoKit と 7zz はこのセットを開けてしまい（7zz は Tail の警告 1 件）、破損に気づけない。
- 9728 byte のファイル 4 件の ustar を 30720 byte で分割すると、`t.tar.002` は先頭が header で終端を含む。
  これを単独で開くと `[f4.bin]` だけの tar として編集でき、追加で `.002` だけが 20480 byte に書き直された。
- `zip -s 100k` の `n.zip` は GyoshukuKit の probe で拒否されるが、理由が「SFX付きZIP」になっていた。
  `.zip.001` のバイト分割は「EOCD がありません」で拒否されていた。

## 対策

`ArchiveSplitVolume.isSplitVolumeMember` が名前と同じ親の兄弟（`lstat`）だけで判定する。
3 桁以上の数字拡張子は、値 1 なら同じ桁幅の 2 か 0、それ以外は `.001` か同じ桁幅の 1 の存在で分割セットの一員とする。
`.zNN` / `.zxNN` は名前だけで、`.zip` / `.zipx` は `.z01` / `.zx01`（大文字を含む）の存在で判定する。
`ArchiveCapabilities.inspect` は一時コピーの次に `.splitArchive` で拒否し、
`ArchiveImportTransaction.publish` は開始時と rename の直前、`ArchiveSession.restoreUndoSlot` は swap の前に再判定する。
公開時の拒否は session の編集可否にも記録し、以後の編集を最初から断る。

## 自動検証

```sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/ReviewDerivedData build-for-testing
xcodebuild ... test-without-building -only-testing:KaitoFinderTests/ArchiveSplitVolumeTests \
  -only-testing:KaitoFinderTests/ArchiveCapabilityInspectionTests -only-testing:KaitoFinderTests/WordingAcceptanceTests \
  -only-testing:KaitoFinderTests/ArchiveEditTests -only-testing:KaitoFinderTests/ArchiveRewriteTests \
  -only-testing:KaitoFinderTests/ArchiveUndoStackTests
```

- build-for-testing 成功。`KaitoFinder.debug.dylib` に `ArchiveSplitVolume` のシンボルがあることを確認した。
- 対象 6 クラス: 175 件実行、失敗 0、skip 1（`testHundredThousandEntryZIPSessionOpensInAboutOneParse`、既存の条件付き skip）。
- 全体: 885 件実行、skip 18、失敗 3。失敗はいずれも `CompressionCapabilityTests` の
  `testDMGDecmpfsFileCannotBePreviewed`（2 件）と `testOldGNUAndStarSparseTarFailBeforePublishingAListing`（1 件）。
  変更を stash した main でも同じ 3 件が同じ内容で失敗した。KaitoKit 0.9.0 の decmpfs 対応と旧 GNU sparse の
  エラー変更に、アプリのテストが追従していないことによる（本変更とは無関係、別途修正）。
