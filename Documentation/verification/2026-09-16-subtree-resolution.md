# フォルダ選択の解決を線形にする — 2026-09-16

## 発端

50 万件(`dNN/sN/tN/fNNNNNN.txt`、トップレベル 50 フォルダ)の ZIP を一括展開すると、
Debug ビルドでは 60 秒以上たっても 1 ファイルも書き始めなかった。`sample` の 99% が
`ArchiveEntryPayload.resolve(in:generation:)` → `Array.filter` → `ExtractionPath.components` で、
フォルダ payload ごとに全 entry を走査し、その中で毎回パスを分解していた。「すべて展開」と
一括展開は `root.children` の数だけフォルダ payload を作るので、コストは
O(トップレベルのフォルダ数 × 全 entry 数 × パスの分解) になっていた。

## 変更

`ArchiveEntryPayload.SubtreeIndex` が entry ごとに一度だけパスを分解し、フォルダのパス →
配下の entry の位置を持つ trie を作る。`ArchiveSession.resolveForExtraction` は最初のフォルダ
payload で index を一度だけ作り、以降の payload はそれを引く。選択の意味(prefix 一致、
フォルダ自身の record を含む、`..` などの不正な子も含めて展開層で失敗として報告する)は変えて
いない。計算量は O(N × 深さ + P × 深さ + 返す件数)、メモリは O(N × 深さ)。

## 実測

- 回帰テスト `ScenarioScaleTests.testFiveThousandFolderPayloadsResolveAllEntriesWithinFiveSeconds`
  (トップレベル 5,000 フォルダ × 4 ファイル = 20,000 entry を 5,000 個のフォルダ payload で解決):
  変更前 **231.2 s**(失敗)、変更後 **約 1.6 s のテスト全体で解決自体は 1 秒未満**(Debug)。
- 実機(Release、50 万件の一括展開): 変更前は書き始めなかったものが、開始 5 秒で書き始め、
  約 190 秒で 50 万ファイルを書き終えた(CPU は 1 スレッドで約 100%、RSS 1.8〜2.2 GB)。
  参考: 同じアーカイブを `unzip -q` は 38 s(ほぼ全て sys)、`ditto -x -k` は 73 s。

## 残る伸びしろ(未着手)

Release の書き込み中の `sample`(5 秒)では、worker の時間の内訳が
`ExtractionDestination.validate`(`isInside` の成分ごとの `lstat`)19%、親ディレクトリの
`openat`(ファイルごとに開き直す)19%、ファイルの `openat` 16%、`fchmod` + `futimens` 8%、
`fremovexattr`(新規作成ファイルでも隔離属性を外しに行く)5%、`URL` の生成 7% だった。
親ディレクトリの descriptor と解決済みパスを兄弟間で使い回せば、小さなファイルが多い
アーカイブで 1.5〜2 倍は見込める。並列展開(design §12-4)とは別の、直列のままの改善。
