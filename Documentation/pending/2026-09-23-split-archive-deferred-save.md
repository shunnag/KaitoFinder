# 分割アーカイブの編集と「保存時にまとめて書き込む」モード（設計）

状態: 実装中（ブランチ feature/split-archive-editing）。M0〜M6 を今回の範囲とし、M7（ZIP 本来の分割 .z01…/.zip の書き込み）は範囲外。
M7 までは `.zNN` / `.zip`（`.z01` あり）のセットは読み取り専用のままとする。

## 決定事項（2026-09-23）

1. 既定のモードは「すぐに書き込む」。「保存時にまとめて書き込む」は設定で選ぶ。
2. 0.2.0 の不具合で壊れたセットの救済（「この巻だけで開く」）は作らない。
3. すぐに書き込むモードでも M6 で分割セットを編集できるようにする。取り消せない編集として、編集の種類によらず確認する。
4. 巻サイズが揃っていないセットは、保存時にシートで巻サイズを選んでもらう。
5. file provider・同期フォルダ、FAT / exFAT、ネットワークボリューム上の分割セットの公開は、既定では拒否し、明示的な同意で許可する。
6. ZIP 本来の分割は M7 で作る。結果が 1 巻に収まるなら単一のアーカイブにする（M7、今回は範囲外）。

## リリース時の確認事項

- KaitoKit の tag（0.10.0、`ArchiveVolumeSet` を含む）を GyoshukuKit の tag より先に打つ。
- GyoshukuKit の Package.swift の fallback（`from: "0.8.1"`）を 0.10.0 に上げる。隣に KaitoKit がない環境
  （利用側の SwiftPM 解決、CI、release）では、0.8.1 に `ArchiveVolumeSet` がないためビルドできない。
- KaitoFinder は `../KaitoKit` / `../GyoshukuKit` の path 依存のまま。release の手順に従い参照先を確認する。

## 既存の失敗（本変更と無関係）

- ArchivePreviewSidebarTests.testMenuToolbarAndKeyboardToggleTheActiveArchive と ArchiveTabSpringLoadingTests の 3 テストは、
  2026-09-23 のセッションでは M0（4ec3d77）でもロック解除後に失敗した（GUI 環境依存。M0 の全体実行時には通っていた）。
  release 前に操作していない GUI セッションで再確認する。

以下の本文は調査時点（KaitoKit 0.9.0 / GyoshukuKit 0.4.2 / KaitoFinder c2c1572）の設計。付録 2 は本文より優先する。
行番号は調査時点のもので、実装とともにずれる。


表記: KF=`KaitoFinder/KaitoFinder/`、KK=`KaitoKit/Sources/KaitoKit/`、GK=`GyoshukuKit/Sources/GyoshukuKit/`。行番号は調査時点のもの（KaitoKit 0.9.0 / GyoshukuKit 0.4.2 / KaitoFinder main c2c1572）。「実測」は scratchpad 内の使い捨てプローブで確かめた結果。

2 人の審査は deferred-document 案と risk-first-publish 案に割れました。ただし両者が挙げた移植案は同じ形にまとまるので、本書はそれに従います。

- 骨格: deferred-document（文書モデル、UX、モード）
- 安全の核: risk-first の公開部品 VolumeSetPublisher
- 範囲の切り方: minimal-incremental の M0 と GyoshukuKit の修正

## 1. 結論

**ご提案の方式で、分割対応はしやすくなります。ただし、しやすくなるのはコストと取り消しです。分割対応の核心は両モードに共通で、キューだけでは解決しません。**

| | すぐに書き込む | 保存時にまとめて書き込む |
|---|---|---|
| 再圧縮と再分割 | 操作ごと（今も書き直し形式は操作ごとに全体を再圧縮している。KF/Import/ArchiveImportTransaction.swift:474-490） | 保存 1 回ごと |
| 保存前の取り消し | 全巻を退避する slot が要る（今の slot は 1 ファイル。KF/Model/ArchiveUndoStack.swift:100-122） | 予約の値を戻すだけ。原本の byte がディスクに残っているので、design.md:886-889 が項目単位の undo を退けた理由は当てはまらない |
| 非原子的な多巻の置き換え | 操作・undo・redo のたび | 保存 1 回ごと |
| 巻の検出、同じ巻サイズでの再分割、N 個のファイルの公開とクラッシュからの回復、全巻の外部変更検査、余った巻の削除 | **必要** | **同じく必要** |

したがって、次の順で進めます。

1. 共通の部品（巻の検出 API と VolumeSetPublisher）を UI から切り離して先に作る。
2. 分割編集の主な経路は、保存時にまとめて書き込むモードにする。
3. すぐに書き込むモードでは、分割セットを正しい理由を示して拒否する。これはご要望で許容された範囲です。余力があれば、後から「取り消せない編集」として解禁します。

これとは別に、**今起きている静かな破損を最優先で止めます（M0）。**
- 流れ: s.7z.001 が `.rewrite(.sevenZip)` と判定される（KF/Model/ArchiveCapabilities.swift:109）→ 作業ファイルが .001 の上にだけ rename される（KF/Import/ArchiveImportTransaction.swift:505）。
- 結果: .001 が 500221 byte の完全な書庫になり、.002〜.005 は旧いまま残る。
- KaitoKit も 7zz もこのセットを読めてしまい、壊れていることに気づかない（7zz は Tail Size の警告を 1 件出すだけ）。

「同じサイズ」の意味は分割の種類で違います。
- バイト分割: 最後の巻以外はちょうど N。
- ZIP 本来の分割: 仕様上、各巻は N 以下になる（APPNOTE 8.5.2。Info-ZIP も同じ）。
- 共通: 再圧縮で全体のサイズが変わるので、巻数は増えることも減ることもある。7z は solid が non-solid になる（実測で Blocks=1→9）。

## 2. モード設計

### 設定
- 値: `ArchivePreferences.SaveBehavior { immediate, onSave }`。UserDefaults のキーは `ArchiveSaveBehavior`。
- 既定値: `immediate`。Finder-first（design.md:5-7）と、「文書が未保存状態にならない」前提の既存テストを守るため。
- 画面: 一般タブに「変更の書き込み: すぐに書き込む / 保存時にまとめて書き込む」を置く。`OpeningBehavior` と同じ形にする（KF/Model/ArchivePreferences.swift:10, 28, 77, 112-113, 133、KF/UI/PreferencesWindowController.swift:95, 164, 255-257）。
- 反映のタイミング: 文書を開いた時点で一度だけ読み、その文書の `nonisolated let` として固定する。
  - 前例は「アーカイブを開くとき」の設定（KF/UI/ArchiveWindowController.swift:458-481）。
  - let にするのは、`writableTypes(for:)` が nonisolated だから（KF/Documents/ArchiveDocument.swift:135-137）。
  - 途中で切り替えないのは、予約が残っている文書でモードを変えたときの意味を定義できないため。
- 位置づけ: 保存時にまとめて書き込むモードは分割専用ではありません。単一の 7z や tar.xz にも同じ利点がある、独立した機能として扱います。

### 文書モデル（保存時にまとめて書き込むモードの文書だけ）
NSDocument の古典的な保存モデルに乗せます。
- `autosavesInPlace` と `preservesVersions` は false のまま（ArchiveDocument.swift:124-125）。true にすると、自動保存のたびに全体が再圧縮されてしまう。
- `updateChangeCount` から super を呼ぶ（今は何もしない。:99-101）。`writableTypes(for: .saveOperation)` は `[fileType]` を返す。
- `save(to:ofType:for:completionHandler:)` を唯一の入口にする。⌘S も、閉じるときと終了時のシートの「保存」も、ここを通る。
  - 実測（docprobe）で確認したこと: 保存パネルを出さずにこの上書きへ届く。閉じるときに標準のシートが出る。文書が 2 つあると「変更内容を確認…」が出る。
  - 注意（同じ実測）: super を呼ばない上書きでは、変更数も `fileModificationDate` も元に戻らない。そのため次の保存で AppKit が「別のアプリケーションで変更されています」と誤って警告した。成功したら自分で `updateChangeCount(withToken:for:)` を呼び、`fileModificationDate` を gate 巻の mtime に合わせる。
- `revert(toContentsOf:ofType:)`:
  - 全巻の同一性が変わっていなければ、予約・staging・undo を捨てるだけにする。reader は開き直さない。
  - 変わっていれば `reloadAfterMutation`（KF/Model/ArchiveSession.swift:440-462）を呼ぶ。
- undo の登録は、既存の `registerUndo` の grouping（ArchiveDocument.swift:405-412）をそのまま使う。`groupsByEvent=false`（:74）なので、`registerUndo(withTarget:)` を単独で呼ぶと例外になる。
- メニュー: 「保存」（⌘S）を「別名で保存…」（KF/App/AppDelegate.swift:381-383）の前に置き、「戻す…」も足す。使えるかどうかは `validateUserInterfaceItem`（ArchiveDocument.swift:458-468）で明示的に判定する。

### 動作マトリクス（形式 × 分割の種類 × モード）

| 書庫 | すぐに書き込む（M0〜） | すぐに書き込む（M6 以降・任意） | 保存時にまとめて書き込む |
|---|---|---|---|
| 単一 ZIP | 今どおり Updater で操作ごとに公開 | 同じ | 保存時に Updater を 1 回使う。暗号化を変えるときは rewriter を使う（ArchiveSession.swift:395-398 と同じ判断） |
| 単一の tar 系・7z・LHA | 操作ごとに全体を書き直す | 同じ | 保存時に 1 回だけ書き直す（M3） |
| バイト分割の .7z / .tar* / .lzh の .001（巻サイズが揃っている） | 読み取り専用（正しい理由を表示） | 操作ごとに書き直し、同じ予定表で分割し直す。取り消せない | 保存時に 1 回（M5） |
| .zip.001 | 読み取り専用 | 操作ごとに連結 → Updater → 分割し直す | 保存時に連結 → Updater → 分割し直す。残す entry は再圧縮しない（M5） |
| 巻サイズが揃っていないセット | 読み取り専用 | 読み取り専用 | 保存時に巻サイズを選ぶシートを出す |
| 兄弟の巻がない単独の .001 | 今どおり単一ファイルとして扱う | 同じ | 同じ。KaitoFinder が書いた xattr があれば、その予定表で分割する |
| ZIP 本来の分割（.z01…/.zip） | 読み取り専用（「分割 ZIP」と表示し、別名で保存で単一 ZIP への変換を提案） | M7 | M7 |
| RAR・CAB・WIM・ARJ・StuffIt の多巻 | 読み取り専用（形式として書けない） | 同じ | 同じ |

「別名で保存」は、保存時にまとめて書き込むモードでは予約を含めて書き出し、新しいファイルへ切り替えます（原本は変えない）。分割セットからの別名で保存は、保存パネルの「分割: しない / 元と同じ / サイズを指定」で決めます（M6）。

保存時にまとめて書き込むモードでは、各操作は次のように予約になります。
- 追加・ペースト・ドロップ: 追加元を staging に退避してから予約する。
- 削除・改名・移動・新規フォルダ: 予約するだけ。削除の確認は出さない。いつでも取り消せるからで、design.md:388-393 の「確認は取り消せないときだけ」とも合う。
- 書庫内コピー（⌥ドラッグ）: 項目を複製する API がないので、予約した時点で staging へ展開する。
- パスワード: 出力の設定として予約する。

取り返しのつかない瞬間は「保存」の 1 点だけになります。

## 3. 分割の扱い

### 検出 API
- 現状: KaitoKit は巻を組み立てるが、公開 API では何も返さない。volumeCount は計算されるが（KK/Reader/SplitVolumeSet.swift:18-21）、KK/Reader/ArchiveReader.swift:443-450 で捨てられる。型 ZipDiskLayout は internal（KK/Reader/ZipSplitVolumeSet.swift:5）で、ArchiveReader の保持プロパティは private（KK/Reader/ArchiveReader.swift:83）。
- 対策: `ArchiveReader.volumeSet` を足す（§6）。
- 巻ごとの同一性は、KaitoKit が保持している fd を fstat して取る（KK/Core/ByteSource.swift:41-44）。後からディレクトリを列挙すると、実際に組み立てた巻とずれる恐れ（TOCTOU）があるため。
- アプリ側はこの API から次の 2 つを作る。
  - `ArchiveVolumeLayout`: scheme、巻、gate、予定表。
  - `ArchiveSetIdentity`: 全巻の {名前, dev, ino, size, mode, mtime} と、「次の番号の名前が存在しない」こと。

### 巻サイズの推定と再現（巻の長さを L1…Ln とする）

| 形 | 扱い |
|---|---|
| L1=…=L(n−1)=S かつ 0<Ln≤S（7zz の単一の -v、split、全体がちょうど S の倍数の場合） | 自動で扱う。最後の巻以外はちょうど S。空の最終巻は作らない。1 巻に収まったら `<stem>.001` だけにする |
| 揃っていない（7zz で -v を複数指定したもの、0.2.0 の不具合で壊れたものなど） | 自動では扱わない。長さだけでは、壊れた状態（.001=500221 > .002=102400）と `7zz -v500k -v100k` の正当なセットを区別できないため。保存時のシートで選んでもらう: 元の予定表を再現（i<n は Li、i≥n は max(L(n−1), Ln)）／最も多い長さ／1 ファイルにする／サイズを指定。KaitoKit に consumedLength が入れば、「consumedLength ≤ L1 なら後ろの巻は残骸」と判定して修復を案内できる |
| n=1（兄弟の巻がない） | 単一ファイルとして扱う（KK/Reader/SplitVolumeSet.swift:87）。KaitoFinder が公開した .001 には xattr `com.shunnag.KaitoFinder.volume-layout`（scheme と予定表）を書いておく。これで、保存で 1 巻に縮んだ後も、次の保存で元の予定表に戻せる |
| ZIP 本来の分割 | S=max(L)。header は巻の境界をまたがないので、各巻は S 以下になる。S が 64 KiB 未満（APPNOTE 8.5.1 に反する）なら利用者に確認する |

### 命名
- `fileName(forVolumeAt:)` を使い、KaitoKit と同じ規則にする（KK/Reader/SplitVolumeSet.swift:37-44、KK/Reader/ZipSplitVolumeSet.swift:83-87）。
  - 桁幅は元のまま保ち、あふれたら伸ばす（.999 → .1000、.z99 → .z100）。
  - Z / ZIP の大文字・小文字も保つ。
- 分割の種類は暗黙に変えない。
- .000 から始まるセットは、KaitoKit が分割として扱わないので対象外。
- 作業ファイル名は `archive.001`（KF/Import/ArchiveImportTransaction.swift:475-476）をやめ、.001 を除いた名前（例: archive.tar.gz）にする。名前による形式の手がかりを残すため。

### 余った巻の削除
- 読み手は、欠番が出るまで巻を連結する（KK/Reader/SplitVolumeSet.swift:77-86）。
- 巻数が減ったら、新しい巻数 +1 から欠番までの旧巻を、**同じ公開の中で**退役させる。
  - 残すと、圧縮した tar は KaitoKit では開けなくなり、7zz ではエラー（data after the end、終了コード 2）付きで中身を取り出せる（実測）。
  - 最終巻がちょうど満杯の .zip.001 では、KaitoKit が古い中央ディレクトリを採用し、読めない一覧を出す（実測）。
- 巻数が増えるときは、公開の前に「旧巻数 +1」から「新しい巻数 +1」までの**全部の**名前（ZIP 本来の分割では大文字・小文字の別名も）が存在しないことを確かめる。存在すると、無関係なファイルが連結されるか上書きされる。
- 公開した後も、巻数が一致することと、次の番号の名前が存在しないことを確かめる。残骸が付いていても開けてしまう（実測）ので、「開けること」は検証にならない。

### 巻数の上限
- 上限は 128 のまま変えない（KK/Core/ReadLimits.swift:104）。
- アプリの reader（KF/Model/ArchiveReaderOptions.swift:22）も、rewriter が内部で開く reader（GK/ArchiveRewriter.swift:82-85。上限を渡していない）も 128 なので、アプリ側だけ引き上げても保存できない。
- 新しい巻数が 128 を超える見込みなら、書き込む前に拒否し、「別名で保存」で巻サイズを大きくするよう案内する。

### 途中の巻を開いた場合
- バイト分割の途中の巻（.003 など）は、7z・zip・圧縮 tar では KaitoKit が「Unsupported archive format」で失敗する。巻き戻さないのは仕様（KaitoKit/CHANGELOG.md:222）。**ただし素の tar と LHA では、先頭がヘッダーの巻（特に最後の巻）が単独の書庫として開け、編集もできてしまう**（オーケストレータが再現: t.tar.002 を単独で開いて追加すると .002 だけが書き直された）。M0 で .001 を持つ番号付きの巻をすべて拒否する。
  - アプリは `parse(fileName:)` で .001 を求め、開き直すことを提案する。
  - .001 がなく、同じフォルダに `.KaitoFinder-vol-*` がある場合は、中断した保存の回復を提案する（§4）。
- ZIP 本来の分割は .z03 からでも組み立てられる（KK/Reader/ZipSplitVolumeSet.swift:89-157）。そこで fileURL を gate の .zip に正規化し、同じセットが 2 つの文書として開かれるのを防ぐ。
- なお .001（design.md:661）と .z01（Info.plist に宣言なし）は、文書型として関連付けられていない。

### 巻ごとの属性
- 新しい巻 k が旧巻の数以内なら、旧巻 k の mode と全 xattr を写す。それを超える巻には、旧 gate の値を写す。今の preserveAttributes（KF/Import/ArchiveImportTransaction.swift:509-539）を巻ごとに行う形。
- quarantine は 1 つの値なので和集合は定義できない。全巻を .001 から順に見て最初に見つかった値を採り、全巻に付ける。展開物へ伝える印も同じ値にする（今は .001 だけを見ている。KF/Model/ArchiveSession.swift:78, 449）。

## 4. 保存時の公開手順と安全性

単一ファイルの書庫は、今どおり rename(2) 1 回で公開します（KF/Import/ArchiveImportTransaction.swift:503-505）。分割セットは、次の gate 方式で公開します。

gate 方式の根拠:
- KaitoKit も 7zz も、gate（バイト分割は .001、ZIP 本来の分割は最終巻の .zip）から組み立て、欠番で止まる。
- そのため、gate が無い状態は「開けない」で済み、安全。
- 危険なのは、gate が別の世代になっている、新旧が混ざった状態。素の tar ではこれを検出できない（実測: AABBA などの混在で、b.bin の SHA が新旧のどちらとも一致しないのに、7zz t は OK を返した）。
- そこで、旧 gate を最初に退かせ、新 gate を最後に置く。

| 段 | 内容 | 取り消し |
|---|---|---|
| S0 事前検査 | 次を確かめる。全巻が S_IFREG で、uchg / schg / uappnd がなく、書き込めること（今の検査は .001 と親フォルダだけ。ArchiveCapabilities.swift:113-122）。ローカルボリュームであること（ネットワークは §8）。空き容量が「W＋1 巻＋余裕」あること（.zip.001 を非 APFS で扱うなら 2W。今は空き容量を一切確かめていない）。新しい巻数が 128 以下で、次の番号の名前が存在しないこと。fd の予算が足りること。RENAME_EXCL が使えるかを 1 回だけ probe する。FAT32 で W が 4 GiB 以上になる見込みなら、作業ファイルを起動ボリュームに置く | 可 |
| S1 | 親フォルダに `.KaitoFinder-vol-UUID/{work,new,old}`（0700）を作り、回復索引に登録する。登録の保存に失敗したら中止する（今の「NSLog を出して続行」、:451-452 は持ち込まない） | 可 |
| S2 | work/ に単一の書庫 W を作る（rewriter、または .zip.001 なら巻を連結して ArchiveUpdater）。rewriter は URL から巻を組み立て直し、checkUnchanged は .001 しか見ない（GK/ArchiveRewriter.swift:82-87）。そこで `ArchiveRewriter.volumeSet` を session の SetIdentity と照合してから、計画を再生する | 可 |
| S3 | W を後ろから巻ごとに new/ へ切り出し、そのたびに ftruncate する（追加の容量は約 1 巻）。巻ごとに属性を付け、fsync する | 可 |
| S4 | new/ の gate を ArchiveReader.open で開き、巻数・次の番号の名前がないこと・entry 名を計画と照合する（今の検証 :497 は archive.001 を単一の巻として開くだけ） | 可 |
| S5 | journal に phase=prepared と新しい巻のハッシュを書き、F_FULLFSYNC する。SetIdentity を再照合する。**ここが取り消せる最後の点**。この後は進捗を取り消し不能にし、臨界区間のカウンタに入り、sudden termination と automatic termination を止める | ここまで |
| S6 | phase=retiring。旧 gate を old/ へ移す | 不可 |
| S7 | 残りの旧巻と余った巻を、1 巻ずつ dev/ino を確かめながら old/ へ移す | 不可 |
| S8 | phase=placing。gate 以外の新しい巻を配置する | 不可 |
| S9 | 新しい gate を最後に配置する。親フォルダを同期して F_FULLFSYNC する。phase=placed | 不可 |
| S10 | gate から開き直して検証する。fileURL と fileModificationDate を gate の値へ明示的に合わせる | — |
| S11 | phase=done。old/ と作業領域を削除し、索引から外す | — |

S6〜S9 の途中で失敗したら、その場で元に戻します（新 gate を最初に外し、旧 gate を最後に戻す）。戻すことにも失敗したら何も消さず、利用者に知らせます。

### 名前の排他（FAT / exFAT）
FAT と exFAT では、宛先が無くても RENAME_EXCL が ENOTSUP になります（実測 fsrel/fl.c）。S0 の probe の結果で、S6〜S9 と回復処理のすべてを「fstatat で不在を確かめてから renameat」に揃えます。巻ごとの RENAME_SWAP は、新旧が混ざる窓が残り FAT / exFAT / HFS+ で使えないので採りません。

### NSDocument の fileURL がずれる問題
- NSDocument は autosave が無効でも NSFilePresenter として登録されている。そのため gate を old/ へ rename すると、presentedItemDidMove によって fileURL が隠しフォルダへ付け替わり、新しい gate を置いても戻らない（実測 uxprobe/presenter.swift）。
- 対策: S6 と S9 の移動は `NSFileCoordinator(filePresenter: document)` の `.forMoving` / `.forReplacing` で行い、文書自身を通知の対象から外す。これで fileURL が変わらないことを presenter2.swift で確認した。
- 保険として、公開中だけ `presentedItemDidMove(to:)` を無視し、S10 で明示的に同期する。
- なお今の即時モードの上書き rename では presentedItemDidChange が来るだけで、fileURL は変わらない。

### journal とクラッシュからの回復
- **正とするのは staging の中の journal**。索引は手がかりとしてだけ使う。
- 索引は PendingWorkRegistry とは**別のファイル**にする。PendingWorkRegistry には次の問題があるため。
  - 壊れていると [] として読まれる（KF/Persistence/PendingWorkRegistry.swift:129-130）。
  - ボリュームが未マウント（ENOENT）の項目や dev が一致しない項目を、黙って落とす（:97-103）。
  - 旧版は、知らない接頭辞の項目を台帳から落とす（:95）。
- 作業領域の接頭辞は `.KaitoFinder-vol-` にする。旧版の sweep はこれを削除しない。`add-` を使うと、旧版が臨界区間の残骸を丸ごと消してしまう。
- 同一性の照合:
  - st_dev はマウントし直すと変わりうる（保証されない。再実測では変わらなかった）。そのため journal は、ボリュームの UUID（volumeUUIDStringKey）と ino・size・mtime で照合する。
  - FAT32 は mtime が 2 秒単位（exFAT は秒未満も持つ）で、ino は開始クラスタから決まり、削除後に再利用される。これを補うため、新しい巻ごとに先頭と末尾 64 KiB のハッシュも記録する。
- 回復の入口は 3 つ。
  1. 起動時の sweep。
  2. `NSWorkspace.didMountNotification`（USB を挿し直したとき）。
  3. 分割セットを開くとき。途中の巻や、.001 の無いセットを開いて失敗したときも含む。
  - (3) は `read(from:)`（メインスレッド）の副作用にはしない。エラーの回復提案（「中断した保存を完了して開く」）から、非同期に実行する。
  - 並行実行は journal への flock で直列化する（FAT / exFAT でも flock が効くことを実測）。
  - 所有プロセスが生きていれば触らない（今の kill(pid,0) の規則を保つ）。
- 判断の規則:
  - phase=prepared: rename はまだ起きていないので、staging を削除する。
  - 新しい巻がすべて揃っている（new/ か配置先にあり、ハッシュが一致する）: 前進する。
  - そうでなく、旧巻がすべて揃っている: 後退する。
  - どちらとも確定できない、または本来の名前が無関係なファイルで塞がれている: 何も消さず、「フォルダを表示」ボタン付きで知らせる。
  - 前進した後の旧セットはゴミ箱へ移す（§8）。
- 耐久性:
  - 各巻は fsync する。journal の phase を更新するたび（1 回の保存で 5 回）に F_FULLFSYNC する。
  - F_FULLFSYNC はドライブのキャッシュ全体を流すので、その前に fsync した巻もこれで確定する。
  - 今の writer は fsync しかしていない（GK/TarWriter.swift:83 など）。

### 終了
- 呼び出し順は reviewUnsavedDocuments → canClose → 保存の完了 → applicationShouldTerminate（前半は実測、後半は NSApplication の文書に基づく。M3 の着手前に実測する）。
- そのため、終了時のシートから始まった保存は、10 秒の打ち切り（KF/App/AppDelegate.swift:28, 163-166）より前に終わる。この保存に免除は要らない。
- 免除が要るのは、すでに臨界区間にいる公開だけ。finishTermination（:170-175）は、カウンタが 0 でない間は応答しないようにする。
- 準備段階の処理は、今どおり取り消す。

### fd の予算
- KaitoKit は巻ごとに fd を持つ。rewriter も別に巻を組み立てるので、session・rewriter・S4 の検証を合わせて 3n 個になる（実測: 122 巻で 370 個）。
- GUI アプリの soft limit は 256 で、3 つのリポジトリのどこにも setrlimit はない。
- 対策: 起動時に `setrlimit(RLIMIT_NOFILE)` で soft limit を上げる。S0 で「開いている reader の巻の合計 ＋ 3n ＋ 余裕 < rlim_cur」を確かめる。

### 外部での変更
- SetIdentity を照合する時点:
  - 開いたとき
  - 予約操作のたび（全巻を lstat するだけ）
  - ウインドウが key になったとき
  - 保存を始めるとき
  - S5
- 今は .001 しか見ていないため、.003 の 1 byte の変更は 7z では commit 時の CRC でしか検出されなかった（実測）。素の tar には内容の CRC がないので、検出されずに新しい書庫へ運ばれる。
- 変更を見つけたら保存を拒否し、「変更を破棄して読み直す / キャンセル」を出す。予約は旧い index を参照しているので、新しい内容とは合成しない。
- 旧い内容から「別名で保存」して救うには、GK に `ArchiveRewriter.open(reader:)` が要る（M8）。
- AppKit も保存の前に fileURL（.001）の mtime を比べて警告する。そのため fileModificationDate は常に gate の値に合わせておく。本当に外部で変更された場合に警告が 2 回出るのは許容する。

### 取り消し
- 保存時にまとめて書き込むモード: 保存前はメモリ上で取り消す。保存に成功したら履歴を消す（予約は保存前の index を参照しているため）。
- すぐに書き込むモードでの分割編集（M6）:
  - willPublish で slot を作らない（ArchiveDocument.swift:350-355）。
  - recordMutation(nil) を呼び、canUndoNextMutation を false にする（:84-90）。
  - これで、既存の「取り消せません」の確認（KF/UI/ArchiveWindowController.swift:965-984, 1425, 1535）に流れる。
  - .001 だけを clone して戻す方式は禁止する。新旧が混ざったセットを作るため。

### 残るリスク
S6〜S9 の間に kill -9 や停電が起きると、回復するまで .001 が見えません（データは隠しフォルダに残ります）。外部の読み手（Finder のコピー、7zz での大きな展開、同期クライアント）は、読み取りが S6〜S9 をまたげば、時間の長さによらず新旧の混ざった巻を受け取りえます。KaitoKit は後で seqlock を入れて塞げますが、外部ツールは塞げません。FAT / exFAT の journaling の欠如と、ネットワーク・file provider の扱いは §8 で決めます。

## 5. 保留中の変更の扱い

### モデル
- 値型の `ArchivePendingChanges` を、文書が持つ `@MainActor` の編集器に置く。中身は `removed: Set<Int>`、`renamed: [Int: String]`、`additions: [PendingAddition]`、`outputEncryption?`、`revision`。
- undo は一つ前の値に戻すだけで、ディスク I/O はない。

### ツリー表示
- 基底の entries に予約を重ねた「投影」を作る。
  - 削除を予約した項目は除く。
  - 改名を予約した項目は、名前だけを差し替える。
  - 追加は合成した entry にする。KaitoKit の public な memberwise init（KK/Model/ArchiveEntry.swift:53-85）を使い、index は基底の件数以上にし、formatSpecific に目印を入れる。
- `EntryNode.tree(from:)`（KF/Model/EntryTree.swift:35-68）はそのまま使う。
- 既存の計画関数は、投影を `existing:` に渡して再利用する。結果は origin（基底の index か追加の id）で予約に翻訳する。対象は ArchiveEditPlan.build（KF/Import/ArchiveImportTransaction.swift:102-200）、ArchiveImportPlan、ArchiveNewFolderPlan（:309-338）、衝突の判定（KF/Import/ArchiveImportConflict.swift:138-148）。
- 保存時に再生する計画は、投影ではなく基底の entries と予約から作る。verifyNames が件数の一致を求めるため（:265-270）。
- 未保存の状態は、閉じるボタンの点と、通知欄の「未保存の変更 3 件（追加 2・削除 1）」で示す。行を斜体にするなどの印は、Finder の見た目から外れるので既定では付けない。

### 保存時の畳み込み
- 追加してから削除した項目は捨てる。追加してから改名した項目は、最終的な名前で追加する。
- フォルダの改名は子孫へ展開する。updater の改名は子に付いてこないため（GK/ArchiveUpdater.swift:119-120）。
- 再生の順番は「削除 → 改名 → 追加」。改名は衝突グラフのトポロジカル順に並べ、循環は一時名を経由して断つ。a と b を直接入れ替えると duplicatePath になる（実測）。
- editor は一度失敗すると使えなくなる（GK/ArchiveRewriter.swift:439-446、GK/ArchiveUpdater.swift:267-274）。そこで validateChanges（KF/Import/ArchiveImportTransaction.swift:227-253）を、追加分と予約の順番まで含めるように広げ、再生前に完全に検証する。
- rewriter は追加した項目を先頭に出力するので、entry の並び順は変わる（実測）。

### 追加元の確保
- 予約した時点で、アプリが所有する `.KaitoFinder-stage-UUID`（書庫と同じ親フォルダ、0700）へ退避する。既存の `.KaitoFinder-add-` と同じ置き方。
- itemReplacementDirectory は、OS が回収しうる（design.md:897）ので使わない。
- 追加元が同じボリュームにあれば clonefile する（フォルダは再帰的に）。別のボリュームならコピーする。大きい場合は参照と stamp にする案もある（§8）。
- URL の参照のまま数時間持つと、元のファイルが変わっただけで保存全体が失敗する（stamp の照合、KF/Import/ArchiveImportConflict.swift:91-125）。
- file promise で受け取ったものと、書庫内コピーで展開したものは、ArchiveIncomingFiles の deinit で消える（KF/Import/ArchiveIncomingFiles.swift:101-103）。その前に staging へ移す。
- 保存を始めるときに、退避したものの存在と stamp をもう一度確かめる。
- 回復索引に kind=stage として登録する。所有プロセスが死んでいる stage は、起動時の sweep で削除だけして回収する。保存成功・戻す・「保存しない」で閉じる（ArchiveDocument.swift:575-598）ときに削除し、`needsTerminationCleanup`（:97）にも含める。

### Quick Look・ドラッグアウト・展開
- payload（KF/Model/ArchiveEntryPayload.swift:30-47）に revision と origin を足す。
- 保存時にまとめて書き込むモードでは、名前による引き直し（:42-46）を使わない。a と b を入れ替える改名で、別の項目の中身を返してしまうため。
- 取り出し方:
  - 基底の項目: reader から取り出す。
  - 改名した基底の項目: ExtractionService の出力名の対応（KF/Extraction/ExtractionService.swift:146-159, 181）に、投影上の名前を渡す。
  - 予約中の追加: staging から clone またはコピーする。
  - 両方が混ざるフォルダ: ExtractionService.run に、ディスク上のファイルを入力にする経路を足す。
- 世代が上がるのは reloadAfterMutation のときだけ（KF/Model/ArchiveSession.swift:443）。そのため、Quick Look のキャッシュと file promise は revision で失効させる。
- reader は開いたときの fd を持ち続けるので、保存するまでの閲覧と展開は元の巻と整合したまま動く。

### 競合
- 予約中の追加が既存の側になる場合、比較元は `.file(staged URL)` にする（ArchiveImportConflict.swift:24-35）。

### パスワード
- `outputEncryption` として予約する。新しい鍵は、保存に成功した後にだけ採用する（ArchiveSession.swift:399-402 と同じ規則）。
- 単一 ZIP の門番（:395）は、予約した時点で確かめる。
- .zip.001 は、.001 単体に EOCD がない（GK/ZipUpdateLayout.swift:136）。今の門番に通すと、恒久的な拒否として記録されてしまう（publishing、:409-416）。そのため、保存時に連結したファイルに対して確かめる。

## 6. 各リポジトリの変更点

### KaitoKit（0.10.0）

```swift
public struct ArchiveVolumeSet: Sendable, Equatable {
    public enum Scheme: Sendable, Equatable {
        case numbered(stem: String, width: Int)                                    // .001
        case zipSpanned(stem: String, volumePrefix: String, lastExtension: String) // .z01…/.zip
        case rarParts, rarOld, stuffItParts                                         // 表示専用（第 2 段）
    }
    public struct Volume: Sendable, Equatable {        // 保持している fd の fstat
        public let url: URL, length: UInt64, device: UInt64, inode: UInt64, mode: UInt16
        public let modificationSeconds: Int64, modificationNanoseconds: Int64
    }
    public let scheme: Scheme
    public let volumes: [Volume]           // 論理順
    public let openedVolumeIndex: Int
    public var gateIndex: Int { get }      // numbered は 0、zipSpanned は最終巻
    public func fileName(forVolumeAt index: Int) -> String
    public static func parse(fileName: String) -> (scheme: Scheme, index: Int)?  // I/O なし
}
extension ArchiveReader { public var volumeSet: ArchiveVolumeSet? { get } }
```

- volumeSet が nil になるのは、単一ファイル、Data / ByteSource から開いた場合、兄弟の巻がない .001、先頭の巻が symlink の場合。
- 実装: Assembled に、実際に開いた名前・長さ・fstat の結果を持たせる（KK/Reader/SplitVolumeSet.swift:18-21, 88-96、KK/Reader/ZipSplitVolumeSet.swift:5-24, 89-157）。それを init（KK/Reader/ArchiveReader.swift:108-115, 393-412）、open（:443-450）、reopen（:568-611）に通す。
- ReadLimits の既定値 128 は、cooViewer と共有しているので変えない。
- 任意: `consumedLength`（残骸の巻を判定するため）、組み立てた後に gate を確かめ直す seqlock。

### GyoshukuKit（0.5.0 以降）
- 門番の判定順を直す: disk 欄の検査（GK/ZipUpdateLayout.swift:145-147）を、先頭 4 byte の検査（:138-141）より前へ移す。
  - これで、分割 ZIP は「分割 ZIP は編集できません」と正しく拒否される。
  - UpdateGatekeeper に case を足さないので、アプリの網羅的な switch（KF/Model/ArchiveCapabilities.swift:41-53）は壊れない。
- `ArchiveRewriter.volumeSet: ArchiveVolumeSet?` を足す。内部の reader が組み立てた巻を返し、S2 の照合に使う。
- 後の段階で足すもの:
  - `ArchiveUpdater.commit(didCarry:)`: 進捗の報告。今できるのは rewriter だけ（GK/ArchiveUpdater.swift:155 と GK/ArchiveRewriter.swift:218 の差）。
  - `ZipVolumeJoiner` / `ZipVolumeSplitter`（M7）: 既存の ArchiveUpdater は変えず、「連結 → 編集 → 分割」の順で使う。
  - `ArchiveRewriter.open(reader:)`（M8）: 巻の二重の組み立て、fd の倍増、外部変更後の救済をまとめて解消する。
  - `VolumeSetOutput`（任意）: 巻をまたいで pwrite する出力。FAT32 の 4 GiB 制限を避け、コピーを 1 回省ける。

### KaitoFinder
- 新規ファイル:
  - Model/: ArchiveVolumeLayout、ArchiveSetIdentity、ArchivePendingChanges、ArchiveProjection、ArchiveSavePlan
  - Import/: VolumeSplitter、VolumeSetPublisher、ArchiveStagingArea
  - Persistence/: VolumePublishJournal、RecoverableWorkIndex、VolumePublishRecovery
- 既存コードの変更:
  - ArchiveCapabilities.inspect（:78-130）: 分割の判定を形式の switch より前に置く。`Refusal.splitArchive` を足し、全巻を検査し、layout を持たせる。
  - identity の利用箇所をすべて SetIdentity に置き換える（KF/Model/ArchiveSession.swift:77, 87, 113, 447-453, 472-478、KF/Import/ArchiveImportTransaction.swift:448-449, 500）。
  - publish（:440-507）: 分割の分岐を足し、作業ファイル名を直す。
  - updatePassword（ArchiveSession.swift:379-405）。
  - ArchiveDocument: :84-90, 97, 99-101, 135-137, 350-355, 458-468, 477-542, 575-598 と、save / revert の上書き。
  - ArchiveCreationTransaction:
    - 同一ファイルの検査（KF/Creation/ArchiveCreationTransaction.swift:42-44）を、全巻と保存先の続きの番号まで広げる。
    - :70-73 に、削除・改名・任意のパスへの追加の再生を足す。
    - :100 の rename を publisher の create に置き換える。
  - 保存パネルの付属ビュー（KF/UI/ArchiveSavePanel.swift:369-412）に「分割: しない / 元と同じ / サイズを指定」を足す。
  - AppDelegate: メニュー（:363-398）、終了（:139-186）、setrlimit、マウントの通知。
  - ArchiveEntryPayload、ExtractionService、EntryMaterializer、設定。
- 文書の改訂:
  - design.md の :5-7, 224-230, 320-325（revertToContentsOfURL の記述と実装のずれも直す）, 355-362, 388-393, 886-889, 909-914, 995-1000, 1102-1117（:1116 の「⌘W は確認しない」を含む）
  - undo-model と quit-during-work の検証記録

## 7. マイルストーン

| M | 内容 | 検証 |
|---|---|---|
| M0（0.2.1、アプリだけ） | inspect の中で、一時コピーの判定（:80）の直後・形式の switch の前に分割を判定し、`.splitArchive` で拒否する。暫定の規則は 3 つ: (1) 拡張子が 3 桁以上の数字で値が 1、かつ桁幅を保った兄弟の .002 が lstat(NOFOLLOW) で存在する。(2) 拡張子が .zNN または .zxNN。(3) .zip / .zipx で、兄弟の .z01 / .zx01 がある。同じ判定を公開の直前（ArchiveImportTransaction.swift:503-505）にも繰り返す（Finder で巻をコピーしている途中に .001 を単独で開いた場合に備える）。変換の提案に分割用の形式名を足す（KF/UI/ArchiveCreationController.swift:114-125）。「SFX付きZIP」の誤表示は、アプリ側の先行判定で避ける | 7z・tar・tar.gz・lzh・.zip.001・.z01 のセットで、追加・削除・改名・パスワード変更が拒否され、全巻の byte が変わらないこと。理由の文言に「SFX」を含まないこと。兄弟のない .001 は今までどおり編集できること |
| M1 検出の土台 | KaitoKit の volumeSet。GyoshukuKit の判定順の修正と rewriter.volumeSet。SetIdentity をすべての照合点に入れる。quarantine を全巻の和から取る。M0 の暫定判定を API に置き換える。setrlimit。分割セットはまだ読み取り専用 | volumeSet の値（.001 のセット、兄弟なし・symlink・Data では nil、.z01 / .z03 / .zip から開いたときの openedVolumeIndex）。.999 → .1000 と z99 → z100。reopen の後も同じ値。y.zip が「分割 ZIP」、本物の SFX が sfxPrefix になること。開いた後に .003 を 1 byte 変えると、書き込む前に拒否されること |
| M2 公開の部品（UI なし） | VolumeSplitter、VolumeSetPublisher（S0〜S11）、journal、回復索引、回復の 3 つの入口、臨界区間と終了処理、EXCL の probe | phase フックで S6 / S7 / S8 / S9 のそれぞれの間に throw と exit() を注入し、前進・後退・保留のいずれかになること、gate を持つセットが常に 1 世代で新旧どちらかと byte 単位で一致すること。hdiutil で作った APFS・HFS+・FAT32・exFAT のイメージで行う。マウントし直して dev が変わった後も回復できること。旧版の sweep が vol- を消さないこと。128 巻で EMFILE にならないこと |
| M3 保存時にまとめて書き込むモード（単一ファイル） | 設定、予約、投影、staging、予約操作、メモリ上の undo、保存・別名で保存（予約を含む）・戻す、メニュー、閉じるときと終了時の確認。着手前に実際の bundle で次を実測する: 役割が Viewer で動的 UTI（.001）の文書でも、⌘S が保存パネルなしで上書きに届くか（docprobe は Info.plist なしで測った）。タブと「ウインドウ」メニューに未保存の点が出るか。読み込み時の fileModificationDate | 編集で dirty、undo で clean に戻る。保存で clean になり、公開は 1 回だけ。戻すと予約と staging が消える。「保存しない」で閉じると staging が消える。別名で保存が予約を含めて書き、原本は変わらない。外部変更があると保存を拒否する。dirty にならない前提のテストをモード別にする（KaitoFinderTests/ArchiveUndoStackTests.swift:403-421, 512, 604、ArchiveEditTests.swift:554、ArchivePasswordTests.swift:370, 390、EntryTreeTests.swift:259-263） |
| M4 予約中の項目の取り出し | payload の revision と origin、staging からの実体化、改名後の出力名、混在するフォルダ、Quick Look、file promise、書庫内コピー | a と b を入れ替えても中身を取り違えないこと。予約中の追加をドラッグで取り出せて、Quick Look でも見られること |
| M5 分割セットの保存（保存時にまとめて書き込むモード） | M2 を保存に接続する。予定表の推定と巻サイズのシート、volume-layout の xattr、.zip.001 の連結 → Updater（門番を通らなければ通知して rewriter に切り替える） | 全巻を連結したものが W と cmp で一致する。`7zz t <stem>.001` が終了コード 0 で、「data after the end」や Tail の警告を出さない。`7zz l` の Volumes が n。巻の長さが予定表どおり。n+1 番の名前が無い。縮小の試験（tar.gz / bz2 / xz と、最終巻がちょうど満杯になる .zip.001）。`lha t`。2 回続けて保存しても予定表が変わらない。KaitoKit で全 entry を読める |
| M6 即時モードの分割編集（任意）と、別名で保存の分割出力 | 同じ公開の部品を即時モードの publish から呼ぶ。slot を作らず canUndo=false。保存パネルの分割の行。保存先の全巻名と続きの番号の検査 | M5 と同じ互換試験。削除のときに「取り消せません」の確認が出ること |
| M7 ZIP 本来の分割 | GyoshukuKit の Joiner / Splitter。gate を .zip にする。1 巻に収まったら 504b0708 の付かない普通の .zip にし、.zNN をすべて削除する | .z01 が 504b0708+504b0304 で始まる。境界をまたぐ header が 0 件。`zip -s 0 --out` の後に `unzip -tq` が OK。.zip からも .z01 からも `7zz t` が通る。zipinfo。1 巻のものを ditto で展開できる。テストデータは Info-ZIP の作成モードで作る（`--out` のコピーモードは header の位置を誤記録するので使わない） |
| M8 任意 | open(reader:)、Updater の進捗、VolumeSetOutput、consumedLength と seqlock、保存をまたぐ多巻の undo | — |

7zz・zip・lha がない環境では互換試験を XCTSkip にし、最終確認はローカルでの実行と Documentation/verification の記録で行います。

## 8. 未決事項

| # | 論点 | 選択肢（★が推奨） |
|---|---|---|
| 1 | 既定のモード | ★すぐに書き込む / 保存時にまとめて書き込む |
| 2 | すぐに書き込むモードで分割を編集できるようにするか | M0 の拒否のまま / ★M6 で「取り消せない編集」として解禁 / 設定に「分割アーカイブだけ保存時に書き込む」を足す |
| 3 | 保存した後の undo | ★履歴を消す / 旧セットを slot にして 1 段だけ残す |
| 4 | 巻サイズが揃っていないセット | ★保存時にシートで選んでもらう / 拒否する / consumedLength が入るまで拒否する |
| 5 | 兄弟のない .001 や、1 巻に縮んだ後の巻サイズ | ★xattr に記録する（FAT では ._ ファイルになる）/ 別名で保存のときだけ尋ねる / 設定に既定値を持つ |
| 6 | ZIP 本来の分割 | ★巻が N 以下になることを「同じサイズ」と認めて M7 で作る / 拒否と単一 ZIP への変換だけにする（読めるのは 7zz と KaitoKit だけ） |
| 7 | ネットワークボリューム | 拒否する / ★保存時にまとめて書き込むモードに限り、確認してから許可する |
| 8 | iCloud Drive などの file provider の配下 | ★確認してから許可する / 拒否する |
| 9 | 前進で回復した後の旧セット | ★ゴミ箱 / 見える場所の復旧フォルダ / 削除 |
| 10 | 別のボリュームにある追加元 | 常にコピーする / 参照と stamp を持つ / ★大きさで切り替える |
| 11 | 未保存の予約がクラッシュで失われること | ★受け入れる（古典的な文書アプリと同じ）/ 予約を journal に書いて復元する |
| 12 | すぐに書き込むモードでの「保存」「戻す」メニュー | ★保存時にまとめて書き込むモードの文書が 1 つも開いていなければ隠す / 常に表示して使えなくする |
| 13 | 7z の solid が保存で失われること | ★通知欄で知らせて許容する / 中身をそのまま運ぶ機能を先に作る |
| 14 | 外部で変更された後に、旧い内容から救う open(reader:) | ★M8 で作る / M5 と同時に作る |
| 15 | 編集の結果が 129 巻以上になる場合 | ★拒否し、巻サイズを大きくして別名で保存するよう案内する / すべての reader の上限を上げる |

## 付録: 審査で指摘された点への対応

| 指摘 | 対応 |
|---|---|
| gate を rename すると NSDocument の fileURL が隠しフォルダへ移る | §4。NSFileCoordinator(filePresenter:) を使い、保険として一時的に無視し、公開後に明示的に同期する |
| アプリ側だけ maxVolumeCount を上げても rewriter は 128 のまま | 128 に据え置き、超える見込みなら書く前に拒否する（§3） |
| 回復の入口が起動時だけで、台帳は壊れると [] になる | journal を正とし、別ファイルの索引と 3 つの入口を持つ（§4） |
| rewriter が巻を組み立て直すときの TOCTOU | `ArchiveRewriter.volumeSet` で照合する（S2） |
| 退避物を TemporaryItems に置くと OS に回収されうる | アプリが所有する `.KaitoFinder-stage-` に置く（§5） |
| 即時モードの分割編集を保存時モードより先に出していた | 保存時モード（M3・M5）を先にし、即時モードは M6 の任意にする |
| 10 秒の打ち切りを外す対象を取り違えていた | 外すのは臨界区間にいる公開だけ（§4 の「終了」） |
| .001 は動的 UTI で、⌘S の経路が実際のアプリで未検証 | M3 の着手前に実測する |
| groupsByEvent=false なので、undo の登録が例外になる | 既存の registerUndo の grouping を使う（§2） |
| 公開の部品が最も複雑な UI の変更の後で初めて動く | M2 で UI から切り離して先に作り、障害注入で試験する |
| RENAME_EXCL が FAT / exFAT では ENOTSUP | S0 で probe し、すべての EXCL の箇所で代わりの手順に揃える |
| read(from:) の中で回復すると副作用があり、UI も止まる | エラーの回復提案から、非同期に実行する |
| ネットワークボリュームを一律に拒否するのは不便 | §8 #7 で、確認してから許可する案を推奨する |
| .zip.001 を rewriter で書き直すと再圧縮になり、パスワードも要る | 連結して Updater で編集する |
| ZIP 本来の分割を当面作らない | M7 で作る（§8 #6） |
| 混在するフォルダを取り出せない | M4 で ExtractionService にディスク上のファイルの入力を足す |
| 予約中の行を斜体にするのは Finder の見た目から外れる | 採らない |
| 即時モードで灰色の ⌘S が常に見える | 既定では隠す（§8 #12） |
| fd の予算を見積もっていない | setrlimit と、S0 での予算の検査 |
| st_dev はマウントし直すと変わる | ボリュームの UUID で照合し、索引の項目を落とさず、マウントの通知でも回復を走らせる |
| 公開の作業領域に `add-` を使うと、旧版が臨界区間の残骸を消す | `.KaitoFinder-vol-` を使う |
| 予定表の式がどんな長さの並びでも受け入れてしまう | 自動で扱うのは揃ったセットだけにし、それ以外はシートで選んでもらう |
| undo を公開の部品で行うと、非原子の窓が 3 倍になる | 保存後は履歴を消し、即時モードでは slot を作らない |
| journal を 1 回しか書かない | phase ごとに先に書き（write-ahead）、F_FULLFSYNC する |
| 台帳の登録に失敗しても続行する | S1 で中止する |
| M0 の判定が inspect の中だけで、巻のコピー中に開くと漏れる | 公開の直前にもう一度判定する |
| FAT は mtime が秒単位で、ino がクラスタから決まる | 新しい巻の先頭と末尾のハッシュを journal に記録する |
## 付録 2: 反証レビューへの対応（統合後に反映）

以下は統合設計の後に行った 2 本の反証レビューの指摘です。本文の §3〜§5 より優先します。

| 指摘 | 対応 |
|---|---|
| **（重大）素の tar・LHA の .001 以外の巻が単独で開け、編集できる**（オーケストレータが再現） | M0 の規則 (1) を「3 桁以上の数字の拡張子（値は問わない）で、同じ桁幅の `<stem>.001` が lstat(NOFOLLOW) で存在する」に広げる。両モードで拒否し、inspect と公開直前（ArchiveImportTransaction.swift:503-505）の両方で判定する。回復の入口 (3) は、開くのに失敗したかどうかではなく `parse(fileName:)` で判定する |
| **（重大）回復が phase だけを根拠に削除する** | 削除はディスク上の内容で判断する。staging を消すのは、old/ が空で、旧セットの全巻が元の名前で SetIdentity と一致するときだけ。old/ を消すのは、新セットの全巻が最終名にあり、巻数・続きの名前がないこと・巻全体の SHA-256 を確かめたときだけ。どちらでもなければ保留にする。回復は何も削除せず、ゴミ箱か見える復旧フォルダへ移す |
| ロールバックが「中止」を記録しない | 最初に new/ を abandoned/ へ rename してから journal を更新する。abandoned は決して前進させない。前進は、旧巻が journal の識別と一致するときだけ。journal は S1 で事前確保し、固定長で 2 スロット・チェックサム付き。読めない journal は保留として扱う |
| 所有判定が kill(pid,0) で、pid が再利用される | 所有者は S1〜S11 の間、journal の flock(LOCK_EX) を持ち続ける。回復側は LOCK_NB で取れたら所有者が死んだと判定する。flock が使えなければ kern.bootsessionuuid・pid・開始時刻で判定する |
| S10 の失敗と、段階ごとの文書の状態が未定義 | S11 へ進む条件を S10 の成功にし、失敗したら old/ が残っているうちに後退する。失敗した段階ごとに、dirty・予約・staging・reader・世代をどうするかを表にして M2/M3 の仕様に入れる |
| 保存中の状態機械がない | 保存を始めてから S10 までは、予約・undo・戻す・別名で保存を無効にする。⌘S・閉じる・終了は実行中の保存を待つ。自分の公開中は main actor からの SetIdentity 照合を止める。S5 より後は取り消しを無視する。カウンタが 0 に戻ったら finishTermination を呼び直す。臨界区間用の終了確認の文言を別に用意する |
| 予約が index だけを参照する | 予約の各要素に (index, expectedName, baseGeneration) を持たせ、世代が一致しなければ拒否する。保存に成功したら予約を空にする |
| M3 を M4 より先に出すと、a↔b の改名で相手の中身を返す | M4 を M3 と同時に出す（または M3 の間、予約にかかわるノードの展開系操作を無効にする） |
| staging を書庫の隣に置くと、FAT/SMB で内容の忠実度と寿命が落ち、自分自身を列挙しうる | 追加元が APFS ならそのボリュームへ clone し、それ以外は `~/Library/Application Support/KaitoFinder/Staging` に置く。`.KaitoFinder-*` は列挙と追加から常に除外する |
| 孤立した stage を削除すると、file promise の唯一のコピーが消える | 削除せず、ゴミ箱か見える復旧フォルダ（「KaitoFinder で保存されなかった項目」）へ移し、次の起動時に通知する |
| 0.2.0 の不具合で壊れた圧縮 tar のセットは、開くこと自体ができない | M0（または M0b）で、兄弟の巻があって開けなかったときに「この巻だけで開く」を提案する。手作業での回避策: `.001` だけで完全な書庫なので、別のフォルダへ移すか `.002` 以降を除く |
| file provider・同期フォルダ・FAT/exFAT | §8 に行を足す。分割セットの公開は、既定では拒否（または明示的な同意）。巻ごとに xattr `com.shunnag.KaitoFinder.volume-set`（setUUID・世代・番号・巻数・全体の SHA-256）を書き、開くときに混在を警告する |
| S0 の検査の不足 | 同じ stem に未解決の `.KaitoFinder-vol-*` があれば保存を拒否する。巻ごとの `accessx_np(_DELETE_OK)`・親の delete_child・sticky bit のときの所有者も見る。(ボリュームの UUID, gate の ino) を鍵にしたロックを S0〜S11 の間保持する |
| 空き容量の見積もり | ArchiveUpdater の複製（GK/ArchiveUpdater.swift:239-253）と LHA の一時ファイル（GK/LHAWriter.swift:147-159）を含める。非 APFS の .zip.001 は 3W。APFS のローカルスナップショットがあれば ftruncate しても解放されない前提で見積もる |
| NSFileCoordinator の待ちが臨界区間の中に入る | S5 より前に、非同期の coordinate(with:queue:) でまとめて取得し、時間切れなら S5 より前で中止する |
| identity の利用箇所の漏れ | ArchiveCreationController.swift:73、ArchiveCreationTransaction.swift:65-66、ArchiveBatchExtraction.swift:154, 223-233 も SetIdentity にする。「展開後にアーカイブをゴミ箱へ」は分割セットでは全巻に広げるか無効にする（未決事項に追加） |
| M6 の確認が削除・置き換え・パスワードだけ | 分割セットへのすべての編集で、取り消せないことを 1 回確認する |
| 畳み込み結果が空のときの ⌘S | 公開せずに changeCount だけを消す（7z の solid と巻サイズを守る） |
| 追加予約の親フォルダの改名・削除、取り出し中の staging | 追加予約のパスは親の改名に追随し、親を削除したら捨てる。staging の削除は file promise の完了を待つ。undo 履歴が消えるまで staging を保持する |
| モードが開いた時点で固定される | 設定画面に「次に開くアーカイブから有効」と出す。拒否の理由に「保存時にまとめて書き込むモードで開き直す」を付ける |
| 保存中と回復中のスリープ・App Nap、アンマウント | ProcessInfo.beginActivity と willUnmount の警告を入れる |
| 確認できていない前提 | F_FULLFSYNC による先行 fsync の確定（Apple の文書に基づく）、保存完了後の applicationShouldTerminate の順序、Viewer の役割と動的 UTI での ⌘S、macOS 26.x の FAT/exFAT の挙動、ReadLimits 128 を cooViewer と共有していること、7zz -v で全体がちょうど S の倍数のときの最終巻 |
