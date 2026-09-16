# KaitoFinder 設計書(2026-09-10 初版)

## 1. 要件

KaitoFinder は「書庫を一覧できる圧縮ソフト」ではなく、**名前空間が書庫の中身で
あるファイルマネージャ**として作る。Finder と同じ外観・操作感が第一の要件であり、
他のすべてはそれに従属する。

- Finder と同じ見た目・操作感で、書庫内のフォルダ / ファイル構成を表示する。
- 書庫内の項目を Finder や他アプリへ **drag & drop** と **copy & paste** で取り出す。
- 他アプリから書庫へ **drag & drop** と **copy & paste** で追加する。
- 対象は Apple Silicon のみ、deployment target は macOS 26.0(ホストは macOS 27)。
- 可能な限り macOS らしい技術で作る。
- 読み取りエンジンは KaitoKit(解凍Kit)。改造してよいが他の KaitoKit
  利用ソフト(cooViewer)へ影響を出さない。
- 書き込みは GyoshukuKit(凝縮Kit)として独立した framework にする。
- 配布は cooViewer と同じ non-sandbox + hardened runtime + Developer ID +
  notarization。App Store は目標にしない。
- 書き込み対応は **ZIP → tar → 7z → LHA/LZH** の順に進め、拡張しやすい形にする。

> **Requirements.** KaitoFinder is not "a compressor with a file list" — it is a
> file manager whose namespace happens to be the inside of an archive. Looking and
> behaving like Finder is the first requirement, and everything else is
> subordinate to it: a Finder-shaped browser over an
> archive, moving items out by drag & drop and copy & paste and taking items in
> the same two ways. Apple Silicon only, deployment target macOS 26.0, built on
> native macOS technology, engine is KaitoKit (extendable, but without affecting
> cooViewer), shipped unsandboxed and notarized like cooViewer, with write
> support arriving in the order ZIP, tar, 7z, LHA/LZH.

## 2. 全体構成

三層に分ける。**それぞれ独立したリポジトリ**にする。

| 層 | リポジトリ | 役割 |
|---|---|---|
| `KaitoKit`(解凍Kit) | shunnag/KaitoKit(既存) | 読み取り。**原則として触らない** |
| `GyoshukuKit`(凝縮Kit) | shunnag/GyoshukuKit(新規) | 書き込み。純 Swift |
| `KaitoFinder` | shunnag/KaitoFinder(本 repo) | アプリ本体。AppKit |

解凍(KaitoKit)と凝縮(GyoshukuKit)を対にする。書き込みを KaitoKit の
中の target にせず**別リポジトリとして独立**させることで、「他の KaitoKit
利用ソフトへの影響ゼロ」が文言ではなく構造として成立する。cooViewer が埋め込む
`KaitoKitDynamic` には writer の byte が一切入らない。

GyoshukuKit は KaitoKit と同じ性格で作る。純 Swift、外部依存なし、OS 同梱の
zlib・libbz2・Apple Compression だけをサポートされた形で使う。macOS 26 以上、
Swift 6、MIT。単体で「書庫を作る・書き換える」ライブラリとして成立させ、
KaitoFinder 専用の作りにしない。

### 2.1 GyoshukuKit は KaitoKit に依存するか

**依存させる。** 書庫の更新(削除・改名・追加)は、生き残る entry を
再圧縮せずに運ぶために既存書庫を読む必要があり、そのための堅い parser を
KaitoKit が既に持っている。二つ目の ZIP parser を書くのは危険で無駄。

依存の向きは `GyoshukuKit → KaitoKit` の一方向だけ。KaitoKit は
GyoshukuKit を知らない。SwiftPM の package 依存として
`.package(path: "../KaitoKit")` を持ち、release では tag 参照へ切り替える。

### 2.2 checkout の配置と参照

関係する checkout は `~/Github/` へ揃えてある(2026-09-10 に移動)。

```
~/Github/KaitoKit     解凍。読み取り
~/Github/GyoshukuKit  凝縮。書き込み
~/Github/cooViewer    KaitoKit.framework を埋め込む別アプリ
~/Github/KaitoFinder  本 repo
```

すべて兄弟なので、`.xcodeproj` からは `../KaitoKit` と `../GyoshukuKit` で
解決する。この二つを **SwiftPM の local package として参照**し、静的に link
する。GyoshukuKit の `.package(path: "../KaitoKit")` と cooViewer の
`Scripts/build-kaitokit-framework.sh` の `$REPOSITORY_DIR/../KaitoKit` も
同じ並びで成立する。

cooViewer は `Scripts/build-framework.sh` が作る universal framework を
`Frameworks/` へ ditto して embed する。**KaitoFinder はこれを踏襲しない。**
その script が組み立てる `KaitoKitDynamic` に writer は(意図どおり)入らず、
かといって二つ目の dynamic product を足す素直な解決策は壊れるからだ ——
SwiftPM の `.dynamic` product は依存 target を **dylib の中へ静的に畳み込む**ため、
`GyoshukuKit.framework` が `KaitoKit` の二つ目の複製を抱え、
`KaitoKit.framework` と link / load 時に衝突する。

cooViewer 側の framework 経路は、その script のコメントどおり「書庫エンジンを
差し替えて検証する」ために存在する。KaitoFinder にその要件は無いので、
複雑さを引き継ぐ理由も無い。**cooViewer の構成は一切変えない。**

> **Layering.** Three layers in three separate repositories: the untouched
> read-only `KaitoKit` (解凍Kit, "extraction kit"), the new `GyoshukuKit`
> (凝縮Kit, "compression kit") for writing, and the KaitoFinder app. Keeping the
> writer in its own repository rather than as a target inside KaitoKit makes
> "zero impact on other KaitoKit users" structural rather than merely asserted —
> not one byte of writer code enters the `KaitoKitDynamic` product cooViewer
> embeds. GyoshukuKit is built with KaitoKit's own character: pure Swift, no
> external dependencies, only OS-bundled zlib, libbz2 and Apple Compression
> through supported APIs, macOS 26+, Swift 6, MIT — and it stands on its own as
> an archive-writing library rather than being shaped around KaitoFinder.
>
> GyoshukuKit does depend on KaitoKit, in one direction only: updating an archive
> means reading the existing one to carry surviving entries across without
> recompressing them, and KaitoKit already has the hardened parser for that. A
> second ZIP parser would be both dangerous and wasteful. KaitoKit never learns
> about GyoshukuKit.
>
> On checkout layout: every related repository sits side by side under
> `~/Github/` (consolidated 2026-09-10), so `../KaitoKit` and `../GyoshukuKit`
> resolve from the `.xcodeproj`, which references both as local SwiftPM packages,
> linked statically. The same sibling arrangement is what makes GyoshukuKit's
> `.package(path: "../KaitoKit")` and cooViewer's framework build script work. KaitoFinder deliberately does not copy cooViewer's embedded
> universal-framework route: that framework carries no writer, and adding a second
> dynamic product would fold a duplicate copy of `KaitoKit` into it and collide at
> link time. cooViewer's own configuration is left completely untouched.

## 3. KaitoKit への変更(追加のみ、3 点)

既存の振る舞いを変えないことを条件に、次の 3 点だけを入れる。いずれも
source-compatible で、cooViewer の再ビルドを要求しない。

### (i) `reopen()` に `sending` を付ける

```swift
public func reopen() throws -> sending ArchiveReader
```

Swift 6.4 で実測した結果、これが無いと actor で包んだ session から並列 worker へ
reopen した reader を渡せない。戻り値へ `sending` を足すのは呼び出し側の義務を
**緩める**方向なので source-compatible。

### (ii) 親ディレクトリ open の leaf fallback

`FileByteSource.openDescriptorAnchoredToParent` は書庫の**親ディレクトリ**を
`O_DIRECTORY` で開く。権限の無いディレクトリに置かれた書庫が開けない。
EPERM / EACCES のときだけ leaf を直接 open し、directory anchor を nil にする
fallback を足す。`RARVolumeLocator` は anonymous origin を既に
`unsupportedMethod` で扱うので、multi-volume だけが穏当に縮退する。
non-sandbox でも実利があり、将来 sandbox を検討する際の前提条件でもある。

公開初期化子 `FileByteSource(url:)` も同じ private 関数を通るため、
**`openDescriptorAnchoredToParent` の中**へ入れる。片方の経路にだけ入れない。

### (iii) 生 payload 範囲の公開(ZIP 更新のため)

削除・改名は書庫の作り直しになるが、生き残る entry を**再圧縮せずに**運びたい。
`ZipReader` は `localHeaderOffset` / `dataOffset` / `compressedSize` / `method` /
`flags` を private に持っているので、これを読み出す追加 API を用意する。

形式に依存しない形にする。ZIP の `method` や `flags` を struct の field に
持たせると tar / LHA で意味を失うので、形式固有の値は `formatSpecific` と同じ
文字列辞書へ逃がす。

```swift
public struct RawEntryRecord: Sendable {
    /// そのまま運ぶべき範囲。ZIP なら [LFH][name][extra][payload] に
    /// bit 3 が立っていれば data descriptor まで含む。
    public let recordRange: Range<UInt64>
    /// 検証用。圧縮データ本体だけの範囲。
    public let payloadRange: Range<UInt64>
    /// 形式固有の値(ZIP なら method、flags など)。
    public let formatSpecific: [String: String]
}
public func rawRecord(of entry: ArchiveEntry) throws -> RawEntryRecord?
```

**終端の算出は KaitoKit にやらせる**のが要点。ZIP の data descriptor は
signature の有無と ZIP64 かどうかで 0 / 12 / 16 / 20 / 24 byte と変わり、
`ZipReader` が今持っている `dataEnd` は payload までしか見ていない。
呼ぶ側にこの算術をやらせると、writer と reader で解釈がずれる。

**local record 全体をバイト列としてそのまま運ぶ**ことが重要で、local と
central の extra field 長は正当に異なる(ditto は 16 / 12、Info-ZIP の 0x5455 は
9 / 5)。central から local header を再構成してはならない。

対応しない形式では `nil` を返す。ZIP・tar・LHA が対象で、7z の solid folder は
`nil`。これは reader の**追加**であり、既存の解析経路と出力は変わらない。

updater 側には併せて**三つの門番**を置く。**SFX 付き ZIP は編集しない**
(prefix があると central directory の offset 基準がずれる)。**EOCD の後ろに
trailing data がある ZIP も編集しない**。そして **EOCD.cdOffset が
`PK\x01\x02` を指さない ZIP も編集しない** —— これは実測で見つけた実在の罠で、
`ditto`(Finder の「圧縮」)は 4 GiB 超の entry を ZIP64 なしで書き、
uncompressed size / compressed size / EOCD の CD offset を mod 2^32 で切る。
その状態で descriptor を算術で探すと deflate stream の途中を指し、編集が
静かに壊す。詳細は `Documentation/verification/2026-09-10-ditto-zip64.md`。
いずれも読み取りは従来どおり行い、read-only の理由を UI で言う。

> **KaitoKit changes — additive only, three of them.** (i) `reopen()` gains a
> `sending` return type; measured on Swift 6.4, without it an actor-wrapped
> session cannot hand a reopened reader to a parallel worker at all, and
> relaxing a return type is source-compatible. (ii) A leaf-open fallback inside
> `openDescriptorAnchoredToParent` for when the parent `O_DIRECTORY` open fails
> with EPERM/EACCES, leaving the directory anchor nil so multi-volume degrades
> gracefully — placed in the private function so the public `FileByteSource(url:)`
> inherits it too. (iii) A new `rawPayload(of:)` accessor exposing the byte range
> of an entry's stored payload, so that rebuilding an archive can move surviving
> entries without recompressing them; it returns nil for formats where that is
> meaningless. The whole local record must be copied verbatim, because local and
> central extra fields legitimately differ in length.

## 4. 書庫モデル

### 4.1 仮想フォルダ

実測(2026-09-10):`tar --no-recursion` と `zip -D` の書庫には **directory entry が
一つも無い**。KaitoKit はそのまま file だけを返す。

```
$ kaito list nodirs.zip
0  5  file  stored  plain  sub/deep/c.txt
1  6  file  stored  plain  sub/b.txt
2  6  file  stored  plain  a.txt
```

Finder の見た目を名乗る以上、木は必ず作る。`pathComponents` から中間ディレクトリを
**合成**し、`isVirtual` を立てる。合成しただけのフォルダは書庫に実体を持たないので、
属性とタイムスタンプの変更は許さない。`isVirtual` が編集動詞を塞ぐ。

tar は `./a.txt` のように `./` を付ける。表示名は `./` を落として正規化し、
展開に使う raw name は保持する。

### 4.2 entry の同一性

`ArchiveEntry.index` は書庫内の位置であり、**書き込みのたびに振り直される**。
drag の promise は drag が終わってから発火するので、index を握った payload は
その間に書き換えが起きると別の entry を指す。よって:

- promise / pasteboard の payload には `(archive URL, generation, index, path)` を持たせる。
- `generation` は書庫を書き換えるたびに増やす。発火時に generation が違えば
  path で引き直し、見つからなければエラーで完了させる。

### 4.3 capabilities

書庫ごとに一つ `ArchiveCapabilities` を計算し、メニュー項目の有効・無効と
drop 後の処理をここから駆動する。drop のハイライトは、在位編集または新規書庫への
変換提案につながることを示す。書けない書庫も受け入れ、元の書庫を変えない
変換を提案する。使えない編集動詞は、どの形式制限が原因かを言う。

```swift
struct ArchiveCapabilities: Sendable {
    var canAppend, canDelete, canRename, canEditAttributes: Bool
    var readOnlyReason: String?      // 「RAR 書庫は変更できません」
}
```

> **Archive model.** Measured: a `tar --no-recursion` or `zip -D` archive carries
> no directory entries at all, so the folder tree must be synthesized from
> `pathComponents` and marked virtual. A folder that exists only as a synthesized
> node has no record in the archive, so attribute and timestamp edits are refused
> on it. Entry `index` is a position, not an identity, and every write
> renumbers it, so drag payloads carry `(archive URL, generation, index, path)`
> and re-resolve by path when the generation has moved on. One
> `ArchiveCapabilities` value per archive drives every menu item's enablement and
> the action after a drop. A drop highlight means the action leads to an edit or
> an offer to create a new archive; read-only archives offer conversion while
> leaving the original unchanged.

## 5. UI 構成

**AppKit を主にする。** Finder 自身が AppKit と SwiftUI の両方をリンクし、
NSBrowser / NSCollectionView / NSOutlineView / NSTableView / NSPathControl /
NSSplitViewController / NSToolbar / NSSearchField を使っている。column view と
ラバーバンド選択は SwiftUI にどの availability にも存在しない。

| 部品 | 実装 |
|---|---|
| 全体 | `NSDocument` + `NSSplitViewController`(sidebar / content / inspector) |
| サイドバー | `NSOutlineView`(`style = .sourceList`) |
| リスト表示 | `NSOutlineView`(sortable / resizable column、`autosaveTableColumns`) |
| アイコン・ギャラリー | `NSCollectionView` |
| カラム表示 | item-based `NSBrowser` |
| パスバー・ステータスバー | `NSSplitViewItemAccessoryViewController`(macOS 26 新規) |
| タブ | `NSWindow` tabbing |
| 設定 | `NSWindowController` + `NSTabViewController`(`tabStyle = .toolbar`) |
| 情報を見る・inspector | `NSHostingView` で SwiftUI |

**設定**: アプリメニューの「設定…」(⌘,)から、一般 / 圧縮 / 展開の三つのタブを持つ
単一のウインドウを開く。新規書庫の既定形式は保存パネルと共有し、ZIP の方式・レベル・
圧縮済みファイルの無圧縮格納、tar.gz の gzip レベル、tar / tar.gz の所有者 ID 保存を変更できる。
7z は LZMA2、LHA は -lh5- の固定エンコーダーを使う。操作ごとに UserDefaults へ保存し、
新規作成・形式変換・開いている書庫の追加や編集へ即時反映する。展開先・フォルダ作成方針・
展開後のアーカイブのゴミ箱移動も保存し、一括展開から参照する。

**一括展開**: ファイル›「アーカイブを展開…」で複数のアーカイブを選ぶか、
Finderのサービス「KaitoFinderで展開」から、文書を開かずに同じ`ArchiveBatchExtractor.run`を使う。
展開先が「毎回確認」なら開始前に全体で一度だけフォルダを選び、「同じフォルダ」なら各原本の隣へ展開する。
`ArchiveBatchPlan.destinationFolder`は設定の「常に」「最上位に複数項目があるときだけ」「作成しない」に従い、
アーカイブの拡張子を除いた名前のフォルダを必要な場合だけ作る。既存名は「名前 2」「名前 3」と避ける。
入力順に逐次展開し、アーカイブごとに進捗の子を一つ持つ。パスワードは保管庫を先に参照し、必要なら
単独の進捗パネルに名前付きの入力シートを出す。破損や入力のキャンセルはそのアーカイブの失敗として次へ進む。
進捗のキャンセルは全体を止め、処理中のアーカイブが作った出力だけを回収し、完了済みの出力を残す。
展開成功後だけ設定に従って原本をゴミ箱へ移す。移動の失敗でも展開した内容は残す。
失敗は最後に名前と理由を一つのアラートにまとめ、すべて成功した場合は通知も表示先の変更もしない。
展開には画面の「すべて展開」と共通のペイロードと`ExtractionService`を使い、安全性検査と隔離属性の伝播を引き継ぐ。

`NSDocument` は**読み取り専用の器**として使う。`readFromURL:ofType:` を
override して super を呼ばない(継承実装は NSFileWrapper 経由で書庫全体を
memory へ載せ、KaitoKit の遅延読みを潰す)。`isEntireFileLoaded` は NO、
`autosavesInPlace` / `preservesVersions` は NO、`writableTypesForSaveOperation:`
は空配列。書き換えは NSDocument の保存機構ではなく後述の atomic replace で行い、
`revertToContentsOfURL:` で同期し直す。

日本語 UI の語彙は Finder 自身の `ja.lproj/*.strings` に合わせる(項目、など)。
文字列は `.xcstrings`。

ツールバー `ArchiveToolbar` は unified / iconOnly で「展開」「追加…」「新規フォルダ」「削除」「クイックルック」、伸縮スペース、「検索」の順に並べ、カスタマイズと配置の自動保存を許可する。展開は選択がなければ書庫全体を対象にし、追加はファイル・フォルダの複数選択を表示中のフォルダへ取り込む。ボタンの可否と理由は既存メニューと共通にし、読み取り専用書庫への追加・ペーストは変換提案へ進める。一覧の空白部分の右クリックには「新規フォルダ」「ペースト」、区切り、「すべて展開…」、区切り、「新規書庫…」「書庫を Finder に表示」を出す。行の右クリックは既存の行メニューを使い、未選択の行ならその行を選択する。

Quick Look は `QuickLookUI.QLPreviewPanel` を window controller の responder chain から
制御する。Space は `NSOutlineView` の `keyDown(with:)` で受ける。独自の
`QLPreviewItem` は書庫内パスをタイトルにし、未展開時の URL は nil とする。
選択全体を data source に公開しても、実体化するのは `currentPreviewItemIndex` の一項目
だけ。solid 群の先読みを避け、移動・選択変更・終了で古い要求を取り消す。
成功したコピーは generation / index / path を含む payload をキーに文書内でキャッシュし、
選択やパネルを閉じる操作をまたいで再利用する。文書の終了・世代変更時には要求を停止して
終了を待ち、文書の一時コピーを background で削除する。コピー用 pasteboard の寿命とは別に扱う。
非対応の行へ受動的に選択を移した場合、パネルは空の状態になり alert を出さない。
Space / メニューの明示的な実行には理由を表示する。可否判定は翻訳文字列から分離した enum を使う。
Open / Open With も同じ遅延実体化処理を使い、実名と拡張子を保持する文書別一時領域へ
既存の安全な展開層を通して書く。M1 は公開前にコピーを読み取り専用にし、書庫には
保存されないことを UI に常時表示する。32 MiB 以上またはサイズ不明なら既存の進捗と
Cancel を使う。詳細と自動検証・手動確認の境界は
`Documentation/verification/2026-09-10-quicklook-open.md` を参照。

> **UI.** AppKit is the primary framework, mirroring what Finder itself does — it
> links both AppKit and SwiftUI, and neither column view nor rubber-band
> selection exists in SwiftUI at any availability level. SwiftUI is used through
> `NSHostingView` for Settings, Get Info and the inspector. `NSDocument` serves
> as a read-only shell whose `readFromURL:ofType:` deliberately does not call
> super, because the inherited implementation loads the whole archive into memory
> through `NSFileWrapper` and defeats KaitoKit's lazy reader; mutation happens
> out of band through atomic replacement, followed by `revertToContentsOfURL:`.
> Japanese vocabulary follows Finder's own `.strings`.
>
> Quick Look uses QLPreviewPanel through the window controller's responder chain;
> Space is handled by NSOutlineView.keyDown. A custom preview item reports its
> archive path as title and nil URL until ready. The data source exposes the full
> selection but materializes only currentPreviewItemIndex, cancelling old work on
> navigation, selection changes and closure. Successful copies are cached by the
> document using the generation/index/path payload, surviving selection and panel
> changes. Document closure or generation replacement drains work and deletes the
> document's copies in the background, independently of pasteboard lifetime. Passive
> navigation onto unsupported rows leaves an empty panel without alerts; explicit
> actions still report the reason. Capability decisions use stable enum values,
> separately from translated messages. Open and Open With share this lazy
> materialization through the existing safe extraction layer, preserving real
> filenames and extensions in per-document temporary storage. M1 copies become
> read-only before publication, with a persistent notice that changes are not saved
> to the archive. The existing progress sheet and Cancel apply at 32 MiB or unknown
> size. The M1c verification record distinguishes automated logic checks from
> remaining manual integration checks.

### 5.1 書庫内の編集(削除・改名)の UI

M3 で載せる操作。判断の根拠は §7.6(取り消し)と
`Documentation/verification/2026-09-10-index-identity.md`。

**確認ダイアログは取り消せないときだけ出す。** Finder が削除で確認を出さないのは
undo があるからで、確認の有無は「危険だから」ではなく「戻せるか」で決まる。
`canUndoNextMutation` が真なら即削除する。偽になるのは clone slot を作れない
とき — 非 APFS ボリューム(exFAT の USB、SMB 共有)で `clonefile` が ENOTSUP を
返す場合 — で、そのときだけ「取り消せません」と明示して確認する。
選択行ごとにモーダルを出すことはしない。

**検証は UI で先に行う。** 衝突する名前を打った利用者には、フィールドを編集状態の
まま検証メッセージを見せる。commit してからエラーシートを出すのは設計ではなく
フォールバックであり、`ArchiveEditError` が型入力から出てきたらこの層の漏れである。

ただし「編集状態のまま」の実現方法は AppKit の制約で決まる。表のインライン編集は
`editColumn(_:row:with:select:)` で始める(`makeFirstResponder` を直接使うと、
key でないウィンドウで field editor の生成が同期的に確定せず、自分で始めた
セッションを自分で取り消す競合になる)。その代償として `NSTableView` が編集
セッションを所有するため、`control(_:textShouldEndEditing:)` が false を返しても
編集の終了は止められない。したがって Return は `doCommandBy` の中で検証して
first responder を手放さない形にし、focus 喪失は拒否せず、終了直後に同じ行へ
再入して入力と理由を残す。実測は
`Documentation/verification/2026-09-10-inline-rename.md`。

**カスケードは呼出側が明示する。** GyoshukuKit は削除も改名も子孫へ波及させない。
仮想フォルダ(`EntryNode.isVirtual`、子の接頭辞としてのみ存在するフォルダ)の削除は
子孫の複数 entry 削除であり、実在するディレクトリ entry の削除は自身と子孫を
まとめて消す。でないと孤児が残る。ディレクトリの改名は全子孫の接頭辞を書き換える。

**index は信用しない。** `remove(entriesAt:)` は updater 自身の open 時 index を
取るが、呼出側が持つのは `ArchiveSession` の別の open から来た index である。
`ArchiveUpdater.entryNames` と突き合わせ、一つでも違えば操作全体を拒否する。
照合では正規化しない(Swift の `String ==` は正準等価を折り畳む)。

**削除後の選択**は次の兄弟へ、最後の子を消したなら親へ移す。改名後は
改名した項目を選択したままにする。undo / redo では tree が作り直され世代が
上がるので、消えた node を掴んだままにしない。

**同じウインドウ内のドラッグは移動**とし、⌥ を押したときはコピーにする。
別の書庫ウインドウへのドラッグは従来どおり file promise によるコピー。
同じ親フォルダ、自分自身や自分の子孫への移動は受け付けず、移動先の名前が
一つでも衝突したら理由を示してドロップ全体を拒否する。複数項目とフォルダの
全子孫は一括で公開し、「移動」一回で取り消せる。成功後は移動先を展開して
移動した項目を選択する。モデルの検証はエラーを返し、確認 UI は持たない。

> **Editing inside an archive.** Confirmation is gated on reversibility, not on
> danger: Finder does not ask before deleting because undo exists, so this app
> asks only when `canUndoNextMutation` is false — that is, on a volume where
> `clonefile` returns ENOTSUP and no slot can be taken. Typed names are validated
> before the library is called, with the field left editing on rejection, because
> a commit-then-refuse is a leak in this layer rather than the intended path.
> Cascading is explicit: GyoshukuKit deliberately does not propagate to
> descendants, so deleting a directory — real or virtual — collects its subtree
> here, and renaming one rewrites every descendant's prefix. Indices are never
> trusted across two independent opens of the same file; they are checked against
> `ArchiveUpdater.entryNames`, without normalisation, since Swift's `==` folds
> canonically equivalent names and would hide the very divergence being checked.

### 5.2 暗号化書庫とパスワード

実測は `Documentation/verification/2026-09-10-encrypted-archives.md`。

**入力を求める瞬間は二つある。** ZIP(従来型 PKWARE / WinZip AES)と本体だけを
暗号化した 7z は、一覧はでき、初回読み取りで `passwordRequired` になる。
7z の `-mhe=on` と RAR のヘッダ暗号化は **open 自体が失敗する**。しかもその
open は `ArchiveDocument.read(from:ofType:)` の中で、`nonisolated` かつ AppKit の
並行読み込み経路なので UI を出せない。そこで `.locked(URL)` 状態で開き、
コントローラ側で入力を得てから `unlock(password:)` で本開きする。

**`PasswordProvider` は使わない。** KaitoKit の同期 `Sendable` コールバックで、
復号中の任意スレッドから呼ばれる。ここで入力を求めると背景スレッドをメインの
モーダルで塞ぐことになり、取り消せず、「キャンセル」と「拒否」も区別できない。
`ReaderOptions.password` だけを使い、再試行は操作の境界に置く。UI はメイン、
復号は背景、塞ぐ橋を作らない。

**正しさの判定は照合値では足りない。** ZipCrypto の照合値は 1 byte で、実測では
誤ったパスワード 4000 個のうち 15 個(≒1/267、理論値 1/256)が `stream()` を
開けてしまう。`stream()` が開けたことをもって「正しい」と判定すると、
**約 0.4% の確率で誤ったパスワードを受け入れる**。CRC / HMAC まで読んで確定する。

**パスワードは session が持ち、`reloadAfterMutation` にも渡す。** 書き換えは毎回
inode を差し替えて開き直すので、渡さないと「追加した後に暗号化項目を展開
できない」が静かに壊れる。`reopen()` は options と password を自前で引き継ぐ。
`close()` で nil にする。

**保管は選択式、既定はオフ。** Archive Utility は保存せず、それが macOS らしい
既定である。設計は cooViewer の `PasswordVault` から借りた — Keychain には
マスターキー 1 本だけ置き(per-item 保存は ad-hoc 署名の Debug でビルド毎×
書庫毎に許可ダイアログが出る)、本体は AES-GCM で封緘する。封緘できなければ
書かず、読めない庫は上書きしない。キーは JSON 配列で持つ(区切り文字はパスに
合法に現れるので連結は非単射)。

ただし **inode ではなくパスで引く**。cooViewer は書庫を書き換えないので inode で
引けるが、KaitoFinder は commit のたびに inode が変わるため、踏襲すると最初の
編集で保存済みパスワードが孤児になる。

> **Encryption.** There are two moments a password can be needed, not one: ZIP and
> payload-encrypted 7z list fine and fail at first read, while 7z `-mhe=on` fails at
> *open* — inside a `nonisolated` document read that cannot present UI, hence the
> locked state. `PasswordProvider` is deliberately unused: it is a synchronous
> callback invoked on the decoding thread, so prompting from it would block a
> background thread on a main-thread modal. Correctness is decided by CRC/HMAC, not
> by the check byte: measured, 15 of 4000 wrong passwords open the stream, so a
> check-byte verdict would accept a wrong password roughly 0.4% of the time.
> Persistence is opt-in and off by default, and follows cooViewer's vault design —
> one Keychain master key, an AES-GCM file, never write plaintext, never overwrite a
> vault that cannot be read — except that entries are keyed by path rather than
> inode, because every commit here replaces the inode.

### 5.3 ようこそウインドウ — 2026-09-15

`AppDelegate` が単一の `WelcomeWindowController` を保持する。内容領域は 720 × 440 pt、
中央配置、サイズ変更・最小化なし、閉じるボタンと Escape で閉じられる。
アプリアイコン、ようこそのタイトル、バージョン、左右同幅のドロップ領域、左下の起動時表示チェックを置く。
ドロップ領域は角丸・破線枠と薄い塗りで示し、受け入れ可能なドラッグではアクセント色の実線と 1.02 倍の拡大に切り替える。
「視差効果を減らす」が有効なら拡大のアニメーションを省く。色はライト・ダークに対応する意味色を使う。

| 状況 | 動作 |
|---|---|
| ファイル指定なし・文書なし・起動時表示オンで起動 | メインキューの次の処理でようこそを表示 |
| 既存のファイルパスを起動引数で指定 | 非同期で開く処理を予約し、ようこそは表示しない |
| LaunchServices が起動時に文書を登録済み | ようこそは表示しない |
| 起動時表示オフで起動 | ようこそは表示しない |
| ウインドウがない状態で Dock をクリック | 起動時表示の設定にかかわらず表示し、通常の再オープン処理を抑止 |
| ウインドウが見えている状態で Dock をクリック | 通常の再オープン処理へ渡す |
| ウインドウ › ようこそKaitoFinderへ（⇧⌘1） | 同じようこそウインドウを再表示 |
| アーカイブのウインドウがメインになる | ようこそを閉じる。設定などのウインドウでは閉じない |
| 最後のアーカイブを閉じる | ようこそは自動で再表示しない |
| XCTest の起動 | 既存の環境変数ガードにより起動時表示しない |

「アーカイブを開く」はクリックで標準の開くパネルを出す。ドロップは全 URL が
`ArchiveBatchExtractionController.archiveContentTypes()` のいずれかに準拠するファイルのときだけ受け入れ、
各 URL を `NSDocumentController` で開く。フォルダ、非アーカイブ、その混在は強調せず拒否する。
「アーカイブを作成」はクリックで既存の新規作成へ進み、ファイル・フォルダのドロップは
圧縮サービスと同じ `ArchiveCreationController.createAndOpen` を使う。
保存パネルはようこそに付属するシートとなり、取り消した場合はようこそを残す。
マウス移動が 4 pt を超えた操作をクリックにせず、Space / Return / VoiceOver のプレスでも同じ操作を呼ぶ。
両領域は手形カーソル、フォーカスリング、見出しと説明によるアクセシビリティ情報を持つ。

`ArchiveShowsWelcomeAtLaunch`（既定 true）は `ArchivePreferencesStore` に保存し、
ようこそ左下の「KaitoFinderの起動時にこのウインドウを表示」と設定 › 一般の
「起動時にようこそウインドウを表示」を `didChange` で即時同期する。
追加の 8 文言を含め全 26 言語を収録し、固定サイズのようこそと設定 › 一般は両外観で描画監査する。
検証結果は [ようこそウインドウ検証](verification/2026-09-15-welcome.md) に記録する。

### 5.4 対応言語 — Wave D、2026-09-15

`Localizable.xcstrings` の全 292 キーと Finder の二つの Services メニューを、以下の 26 言語で提供する。
Wave D は 16 言語・4,672 訳を追加し、既存 10 言語の 2,920 訳とカタログのキー・メタデータは維持した。

| 区分 | 言語コードと名称 |
|---|---|
| 既存 | `en` 英語、`ja` 日本語、`de` ドイツ語、`fr` フランス語、`es` スペイン語、`it` イタリア語、`pt-BR` ポルトガル語（ブラジル）、`zh-Hans` 中国語（簡体字）、`zh-Hant` 中国語（繁体字）、`ko` 韓国語 |
| Wave D | `th` タイ語、`vi` ベトナム語、`id` インドネシア語、`ms` マレー語、`hi` ヒンディー語、`ru` ロシア語、`nl` オランダ語、`pl` ポーランド語、`tr` トルコ語、`sv` スウェーデン語、`da` デンマーク語、`nb` ノルウェー語（ブークモール）、`fi` フィンランド語、`uk` ウクライナ語、`cs` チェコ語、`pt-PT` ポルトガル語（ポルトガル） |

- 提供された Apple 用語集 `tier1-glossary.json` を基準とし、Archive Utility、Finder、AppKit の
  文脈と句読点に従う。用語集の `no` / `pt_PT` を、カタログ・lproj・`knownRegions` では
  `nb` / `pt-PT` に対応させる。`Archive` の動詞訳を名詞ラベルへそのまま流用しない。
- 用語集にない「別名で保存…」は AppKit `Document.loctable`、「圧縮」と「変更日」は
  Finder の言語別リソースを参照した。一部の未翻訳の Undo / Redo は Finder のメニュー訳を補う。
  ウェルカム文は用語集の文型を使い、Apple 内部の活用指定や書式マーカーは表示文字列に入れない。
- 名前の引用符は ru / uk / nb が `«…»`、pl が `„…”`、cs が `„…“`、sv / fi が `”…”`、
  nl が直線の `'…'`、他の追加言語は `“…”`。省略記号は語に続けて `…` を付ける。
  タイ語は文末の句点なし、ヒンディー語は `।`。欧州ポルトガル語は `palavra‑passe` の
  改行しないハイフンを維持する。警告文の整形はこれらの句点を重複させない。
- `LocalizationAcceptance.languages` は 26 言語で共通化し、文体・全訳の引数順序・Services・
  バンドル内リソース・設定の用語をテストする。設定、保存アクセサリ、パスワードシート、
  ようこそ、警告、進捗、ステータスバーの描画監査にも同じ一覧を使用する。
  ウインドウ幅を増やす前に、長いラベルと文字体系に応じた折り返し・行高を確認する。
- 未対応言語では英語にフォールバックする。切替手順は
  [手動検証 §8.1](manual-verification.md#81-言語)、実行結果と sandbox 制約は
  [Wave D 検証](verification/2026-09-15-languages.md)を参照。

### 5.5 対応形式の宣言 — 2026-09-16

`Info.plist` の `CFBundleDocumentTypes` は、KaitoKit が読む全形式を次の識別子で宣言する。
今回 StuffIt / StuffIt X / Zstandard を追加した。文書の role はすべて `Viewer`、
クラスは `ArchiveDocument`。実際の形式は KaitoKit が内容から判定し、これら三形式は
`ArchiveCapabilities` の共通経路で読み取り専用になる。

| 文書形式 | LSItemContentTypes | LSHandlerRank |
|---|---|---|
| ZIP | `public.zip-archive`、`com.winzip.zipx-archive` | Alternate |
| tar / tar.gz | `public.tar-archive`、`org.gnu.gnu-zip-tar-archive` | Alternate |
| gzip | `org.gnu.gnu-zip-archive` | Alternate |
| bzip2 | `public.bzip2-archive` | Alternate |
| XZ | `org.tukaani.xz-archive`、`org.tukaani.tar-xz-archive` | Alternate |
| LZMA | `org.tukaani.lzma-archive` | Default |
| UNIX compress | `public.z-archive` | Alternate |
| 7-Zip | `org.7-zip.7-zip-archive` | Default |
| RAR | `com.rarlab.rar-archive` | Default |
| LHA | `public.lha-archive` | Default |
| ISO 9660 | `public.iso-image` | Alternate |
| cpio | `public.cpio-archive` | Alternate |
| ar / deb | `com.shunnag.KaitoFinder.ar-archive`、`org.debian.deb-archive` | Default |
| xar | `com.apple.xar-archive` | Alternate |
| Installer Package | `com.apple.installer-package-archive` | Alternate |
| CAB | `com.microsoft.cab` | Default |
| RPM | `com.redhat.rpm-archive` | Default |
| StuffIt | `com.stuffit.archive.sit` | Default |
| StuffIt X | `com.stuffit.archive.sitx` | Default |
| Zstandard | `org.zstandard.zstd-archive` | Default |

Archive Utility が開ける形式は Alternate、macOS に標準の開き手がない形式は Default とする。
ISO 9660 は Finder がマウントするので Alternate を維持し、Installer Package / xar も
Alternate とする。この方針を戻す場合は各文書型の `LSHandlerRank` を変更する。

The Unarchiver が export する `org.tukaani.tar-xz-archive`（`.txz`）、
`com.winzip.zipx-archive`（`.zipx`）、`org.debian.deb-archive`（`.deb`）は
既存の宣言型に準拠しないため、拡張子の関連付けで優先される環境でも Finder の
「このアプリケーションで開く」に出るよう、XZ / ZIP / ar の別識別子として追加した。
未インストールの環境でも意味を持つよう、三識別子を `public.data` / `public.archive` に
準拠する imported type として、それぞれの拡張子とともに宣言する。
既存 import の `txz` / `zipx` / `deb` はフォールバックとして残す。
Zstandard も同じ準拠先で import し、`zst` / `tzst` を登録する（`.tar.zst` は `zst` で対応）。
StuffIt は CoreTypes の識別子を参照し、`sit` / `sea`、`sitx` の import も明記する。
`.tbz2` / `.tbz`、`.z01`、`.jar`、`.cbz` は既存型への準拠で対応するため変更しない。

開発用 Mac で Release ビルドを `lsregister -f` により登録した後、拡張子ごとに
KaitoFinder が開き手の候補に出るかを実測した。識別子・候補・既定アプリの表と CAB の
識別子修正は [LaunchServices の実測記録](verification/2026-09-16-document-types.md)を参照。
オーケストレータは CAB 修正後に Release を再ビルドして `lsregister -f` で再登録し、開発用 Mac で `.cab` → `com.microsoft.cab` の開き手 6 アプリに KaitoFinder が含まれ、既定アプリも KaitoFinder であることを確認した（`.zst` / `.sit` / `.deb` は変化なし）。

関連付けには macOS 側の制約がある。`.pkg` の識別子は CoreTypes で `apple-internal` のため、
宣言が登録されても「このアプリケーションで開く」にはインストーラだけが出る。
宣言は維持し、「ファイル > 開く…」または Dock のアイコンへのドラッグで開く。
`.taz`（tar.Z）は動的な型に解決され、import の拡張子一覧でシステム型 `public.z-archive` の
`z` / `Z` を拡張できないため、「ファイル > 開く…」から開く。
`.001` の分割ボリュームと `.exe` の自己解凍アーカイブも関連付けの対象外とする。

展開サービスの `NSSendFileTypes` は全 `LSItemContentTypes` の集合と一致させる。
一括展開パネルとようこそのドロップ判定もこの宣言を参照する。
拒否・変換の形式名は `Model/ArchiveFormatName.swift` の `ArchiveFormat.displayName` で統一し、
圧縮 tar の magic による名前と既存の tar / 7z / SFX ZIP の扱いは維持する。
Finder の登録・ダブルクリックの実機確認は [手動検証 §13](manual-verification.md#13-finder-のこのアプリケーションで開く)を参照。

## 6. 取り出しと取り込み

### 6.1 実測で決まったこと

`Documentation/verification/2026-09-09-pasteboard-promise.md` に記録した実測で、
copy & paste の設計は確定した。

- `NSFilePromiseReceiver.receivePromisedFiles` は **drag 操作中しか呼べない**。
  外から呼ぶと AppKit が `NSInternalInconsistencyException` で拒否する。
  つまり paste の受け側は原理的に promise を受け取れない。
- `.fileURL` の遅延供給は動くが、**reader が居なくても書いた直後に引かれる**。
  遅延を前提にした設計は成立しない。

### 6.2 drag out — file promise

`NSFilePromiseProvider`。`outlineView(_:pasteboardWriterForItem:)` で選択行ごとに
一つ返し、`setDraggingSourceOperationMask(.copy, forLocal: false)` を必ず呼ぶ
(これが無いと Finder への drag が黙って何も起きない)。`.copy` だけを出す。

- **フォルダは 1 個の provider** にする(`fileType = UTType.folder.identifier`)。
  KaitoKit の hard link は「同じ reader で、同じ出力 root へ、先に本体を展開」が
  条件で、root を変えると provenance が消える。部分木を N 個の promise に割ると
  この条件を満たせない。
- delegate は `@MainActor`、ただし `writePromiseTo` は **`nonisolated`**
  (ヘッダの `NS_SWIFT_NONISOLATED`)。main actor の状態に触らない。必要な物は
  4.2 の Sendable payload として promise 作成時に確定させ、書き込み中は
  `reopen()` した専用 reader を使う。completion handler は全経路で必ず一度呼ぶ。
- `NSFilePromiseProvider.delegate` は **weak** で、`writePromiseTo` は drag が
  終わってから発火する。provider と delegate を drag session をキーに保持し、
  書き込み完了後に解放する。**受け取られなかった場合の解放経路**も用意する
  (drag session 終了 + 猶予で掃く)。さもないと fd ごと漏れる。
- `operationQueue(for:)` を必ず実装する。既定は **main queue** なので、
  実装しないと main thread で展開される。既定 `maxConcurrentOperationCount = 1`。
  上げるなら `solidGroup >= 0` が同じ entry は同じ worker に固める。

### 6.3 copy out — 明示的な展開

promise は使えないので、⌘C で temp へ**展開してから**実 file URL を pasteboard へ
置く。遅延を装わない。サイズが閾値を超えるときは進捗シートを出し、
取り消せるようにする。展開先はアプリ専用の temp サブディレクトリで、
起動時に background task で掃く(pasteboard はアプリより長生きしうる)。UI の起動は待たせない。
一時領域名にプロセス固有の UUID prefix を付け、今回の起動後に作った領域は掃除から除外する。

> Launch cleanup runs in a detached background task without delaying the UI. A
> per-process UUID prefix excludes newly created temporary directories from the
> sweep, preventing cleanup from racing new copy or preview requests.

### 6.4 drop in / paste in

- `NSFilePromiseReceiver.readableDraggedTypes` + `.fileURL` を registerForDraggedTypes。
  **`NSFilePromiseReceiver` を `NSURL` より先に**見る(promise の方が高精度)。
  これで Photos や Mail からの drag も受かる。
- drop 先はツリーの**そのフォルダ**。`setDropItem(_:dropChildIndex:
  NSOutlineViewDropOnItemIndex)` で folder 行そのものを狙う。
- paste の可否判定に `readObjects` を投機的に呼ばない。`pb.types` か
  `canReadObject(forClasses:options:)` を使う(pasteboard privacy 対策)。
- spring-loaded は最初は入れない。`NSOutlineView` は drag 中に自動展開する。

> **Moving items out and in.** The empirical spike settled copy & paste:
> `receivePromisedFiles` is refused by AppKit outside a drag operation, so no
> paste destination can receive a promise, and a "lazy" `.fileURL` provider is
> pulled by the system the instant it is written. Therefore drag-out uses
> `NSFilePromiseProvider` — one provider per selected row, a whole folder as a
> single directory promise (forced by KaitoKit's hard-link provenance rules), a
> `nonisolated` write method, providers retained past the drag with a sweep for
> promises that are never called in, and an explicit background
> `operationQueue(for:)` because the default is the main queue. Copy-out instead
> extracts explicitly into an app-owned temp directory and puts real file URLs on
> the pasteboard, with a progress sheet above a size threshold. Drops accept
> `NSFilePromiseReceiver` in preference to `NSURL`, target the folder row under
> the cursor, and never probe the pasteboard speculatively.

## 7. 書き込み(GyoshukuKit / 凝縮Kit)

### 7.1 方針

**純 Swift で書く。** システムの libarchive は `archive_write_set_format_zip` /
`_7zip` などを実際に export しており dlopen で解決もできるが、SDK に
`archive.h` が無い(実測)。ヘッダの無いシステムライブラリに prototype を
手書きして依存するのは、KaitoKit から引き継ぐ「外部依存なし・OS 同梱
ライブラリをサポートされた形でだけ使う」という GyoshukuKit の性格と合わない。さらに libarchive には
**in-place update が無い**ので、書庫内編集という中核機能のためにどのみち
自前の updater が要る。二つの writer が同じ ZIP を別々の作法で書く方が危険。

圧縮は zlib(`deflateInit2_`、raw deflate は windowBits `-15`)。実測で Apple の
Compression framework は `COMPRESSION_ZLIB` が zlib level 5 相当に固定され、
level を選べない。既定は Info-ZIP と同じ **level 6**、設定で変更可。

### 7.2 ZIP(第一段)

- `version made by = (3 << 8) | 63`。host 3 (UNIX) でないと POSIX mode と
  symlink が尊重されない。
- 新規 entry は常に general purpose **bit 11** を立てて UTF-8 名を書く。
  NFC へ正規化する。既存の CP932 書庫を更新するときは、既存 entry の名前バイトと
  flag を**そのまま**運ぶ(混在は正当)。
- data descriptor は**書かない**(seek して local header を patch する)。ただし
  **読む側は必須**。ditto、つまり Finder の「圧縮」は deflate entry すべてに
  bit 3 を立てる。descriptor の位置は central directory の compressed size から
  算術で求め、`0x08074b50` を走査して探さない。
- external attributes は `(unixMode << 16) | dosByte`。ディレクトリには
  MS-DOS 0x10 も立てる。symlink は stored entry として target path を格納し、
  上位 16 bit を `0xA1ED`。追加時は `stat` ではなく **`lstat`**。
- extra field 0x5455 は local 9 byte / central 5 byte で**長さが違う**。
- ZIP64 は sentinel をフィールドごとに判定する。local header の 0x0001 は
  **常に両サイズを載せ、offset は載せない**(APPNOTE 4.5.3)。
- ZIP 暗号化は AES-256 を既定にし、ZipCrypto は「互換性優先、安全性は低い」と表示する。
  CTR は CommonCrypto の AES-ECB + 手動 little-endian counter(CommonCrypto の
  CTR は BE のみ)。KaitoKit の `WinZipAES.swift` の逆をやる。salt は entry ごとに
  新しい乱数。

### 7.3 更新アルゴリズム

1. 同一ボリュームの `.itemReplacementDirectory` へ書庫を **APFS clone** する
   (実測 300 MB で 0.002 s、サイズ非依存)。
2. clone を書き換える。追加は末尾の central directory を上書きして local record を
   足し、生き残る entry は **local record 全体をバイト列で**運ぶ。
3. central directory は**全部作り直す**。offset が 0xFFFFFFFF を跨ぐと 0x0001 が
   増えて CD が伸びるため、offset の部分修正では閉じない。
4. `FileManager.replaceItemAt` で差し替える。**直後に POSIX permission を
   復元する**(実測:replacement 側の mode が勝つ)。`replaceItemAt` は Finder tag
   と xattr と作成日は保つが `com.apple.quarantine` は落とす。
5. reader は捨てて `ArchiveReader.open(url:)` で**開き直す**。`reopen()` は
   置き換え前の inode を掴んだままなので使わない。

改名は、新旧の名前バイト長が違えば全書き直し。同じなら local と central の
両方を in-place で patch する。

### 7.4 tar 以降

- **tar**:bsdtar に合わせた restricted pax。ustar で表せない値のときだけ
  typeflag `x` を出す。数値あふれは pax record を真とし、ustar 側は base-256。
  macOS metadata(`SCHILY.xattr` pax record、および経路によっては `._`
  AppleDouble member)は**既定で書かない** —— Apple の bsdtar は既定で書き、
  それが Mac 製書庫が Windows で嫌われる主因。実測(2026-09-10): xattr を
  二つ付けた 5 byte のファイル一つを `bsdtar -cf` で固めると 4608 byte、
  `--no-mac-metadata --no-xattrs` を付けると 2560 byte になり、
  `SCHILY.xattr` が 2 箇所現れる。なおこの経路で出るのは pax record の方で、
  `._` member は現れない。
  uid/gid は既定 0、uname/gname は空。
- **gzip / bzip2 / xz**:gzip は zlib windowBits 15+16 と `deflateSetHeader`。
  bzip2 は既存の `CBzip2` systemLibrary をそのまま使う。xz は当面
  `COMPRESSION_LZMA`(実測で `xz -t` を通る本物の container、ただし check なし・
  level 6 固定・単一 block)。zstd は macOS に無いので対象外。
- **7z**:Apple の Compression framework が出す `.xz` から **LZMA2 payload を
  そのまま抜き出して** 7z の coder として使えることが実測で分かっている
  (props 0x16、終端 0x00 込み)。LZMA encoder を書かずに non-solid の 7z writer を構成する。AES-256 とファイル名の暗号化も選択できる。比率は 7-Zip 本家に劣る。
- **LHA**:`-lh5-` を書く。member が独立(`solidGroup == -1`)なので更新は素直。
- **書けない形式**:RAR は license が明示的に禁じている
  (「cannot be used to develop RAR (WinRAR) compatible archiver」)。CAB / RPM /
  ISO / xar も書かない。drop されたら**最初から read-only と分かる UI**にし、
  「この .rar は変更できません。中身と新しいファイルで archive.7z を作りますか?」
  という**変換**を逃げ道として出す。

### 7.5 SFX は作らない

Windows のアーカイバでは定番だが、macOS では成立しない。data を追記した Mach-O は
正しく署名できず、ad-hoc 署名の実行ファイルは Gatekeeper に拒否され、quarantine が
付けば Apple Silicon では SIGKILL される。作っても相手の Mac で動かない。
代わりに `hdiutil` の `.dmg` を macOS 版の等価物として置く。SFX の**読み取り**は
KaitoKit が既に対応しており、これは残す。

> **Writing.** Written in pure Swift. The system libarchive does export
> `archive_write_set_format_zip`/`_7zip` and resolves under dlopen, but the SDK
> ships no `archive.h` (measured), and hand-declaring prototypes against a
> header-less system library contradicts KaitoKit's zero-dependency character —
> and libarchive has no in-place update, so a hand-written updater is needed for
> in-archive editing regardless; two writers emitting the same ZIP by different
> conventions is the worse risk. Compression uses zlib directly, because Apple's
> Compression framework is measurably locked to zlib level 5. The ZIP section
> records the field-level decisions (UNIX host byte, always bit 11 with NFC
> names, never writing data descriptors but always parsing them because ditto
> emits them, `lstat` not `stat`, per-field ZIP64 sentinels, AES-256 by default).
> Updates clone the archive with APFS, rewrite the central directory wholesale,
> commit with `replaceItemAt`, restore POSIX permissions afterwards because the
> replacement's mode wins, and reopen the reader from scratch because `reopen()`
> would keep reading the replaced inode. tar follows bsdtar's restricted pax but
> deliberately omits macOS metadata by default. 7z becomes feasible without
> writing an LZMA encoder by lifting the LZMA2 payload out of Compression
> framework `.xz` output. RAR is never written — its license forbids it. SFX
> creation is dropped outright: an appended-data Mach-O cannot be validly signed,
> so a created SFX would not run on the recipient's Mac.

### 7.6 取り消し(undo)モデル — 決定(2026-09-10)

M3(書庫内の削除・改名)には取り消しが要る。Finder にはファイル操作の undo があり、
Finder を名乗る以上期待される。一方 `NSDocument` の編集機構は止めてあるので Cmd-Z が無い。
実測(`Documentation/verification/2026-09-10-undo-model.md`)の上で以下に決めた。

**単位は書庫ファイルそのもの。** `commit()` は必ず inode を差し替えるので、
編集前のファイルが自然な undo 単位になる。当初案の `NSFileVersion` は
ファイル全体を複製するため 4 GiB 級の書庫で破綻し、entry model 上の undo stack は
削除された byte を持たないので rename にしか使えない。どちらも採らない。

**退避は `clonefile(2)`、置き場所は同一ボリュームの temp。**
`replaceItemAt` の直前に、原本を `.itemReplacementDirectory` 配下の undo slot へ
clone する。実測で 1 GiB が **0.2 ms・空き容量の減少 0 MiB**。実コストは編集で
分岐した extent だけ。`backupItemName` + `.withoutDeletingBackupItem` は
コピー無しで同じ効果を出せるように見えるが、**退避物が原本と同じディレクトリに
生える**ことを実測で確認したので採らない(ユーザーの書庫の隣に `~` ファイルが
見え、クラッシュすれば残置される)。temp に置けば残骸は OS が回収する。

**undo は同じ commit 経路の逆再生。** `replaceItemAt(原本, withItemAt: slot)` の後、
`ArchiveSession.reloadAfterMutation()` を通す。世代が上がり、reader が URL から
開き直され、capabilities と quarantine が読み直される — 通常の commit と同一の経路で、
既に検証済みの mode 復元と quarantine 復元をそのまま再利用する。redo は対称に、
undo の直前に現状態を clone してから戻す。

**stack は有界、document 単位、セッション限り。** 件数(10)と退避総 byte の両方で
上限を持ち、古いものから捨てる。document を閉じたら全部消す(Quick Look の
後始末と同じ `@concurrent` 経路)。Finder の undo もアプリ終了を跨がない。

**dirty 状態は抑制する。** `NSUndoManager` に登録すると `NSDocument` が
`updateChangeCount` を呼び、実測で `isDocumentEdited` が true になる。本アプリは
`writableTypes` が空 — commit は即ディスクに落ちるので「未保存」という状態が
存在しない — なので、dirty になると閉じる際に**満たせない「保存しますか？」**が出る。
`updateChangeCount(_:)` を no-op に上書きする。実測で dirty は立たず、
`canUndo` / `canRedo` / メニュー項目名(「取り消す — 削除」)は生きたままになる。

**clone できない書庫は undo を持てない。** 非 APFS ボリューム(exFAT の USB、SMB 共有)
では `clonefile` が ENOTSUP を返す。その場合は undo slot を作らず、
**commit の前に**「この操作は取り消せません」と明示して確認を取る。
黙って全体コピーに落として 4 GiB を焼くことはしない。

UI 層でこれに伴って決めておくこと:

1. **undo / redo でも世代を上げ、Quick Look の cache を捨てる。** commit 後と同じ罠で、
   `reloadAfterMutation()` を通す限り自動的に満たされるが、テストで固定する。
2. **ディレクトリの削除は子孫を巻き込む。** 仮想フォルダの削除は複数 entry の削除であり、
   実在するディレクトリ entry の削除も子孫を道連れにしないと孤児が残る。
3. **改名の検証は UI 側でも先に行う。** GyoshukuKit が弾くもの(衝突、`..`、絶対パス、NUL)は
   ライブラリを呼ぶ前に UI で弾き、「commit してから拒否された」ではなく
   検証メッセージを見せる。

> **Undo.** The unit of undo is the archive file itself, because every commit
> replaces the inode anyway. Both originally-surveyed options were dropped:
> `NSFileVersion` copies the whole file into `.DocumentRevisions-V100`, which is a
> disk bomb for the >4 GiB archives we already know exist, and an in-memory entry
> stack cannot undo a deletion because it does not hold the deleted bytes. Instead
> the pre-edit archive is `clonefile`d into a same-volume temp slot immediately
> before `replaceItemAt` — measured at 0.2 ms and **zero** disk for 1 GiB, since
> APFS shares the unchanged extents. `backupItemName` was rejected on measurement:
> it puts the retained file **next to the user's archive**, where it is visible in
> Finder and survives a crash. Undo replays the same commit path in reverse and
> goes through `reloadAfterMutation()`, so it reuses the already-verified mode and
> quarantine restoration. The stack is bounded by count and bytes, per document,
> and dies with it. Registering with `NSUndoManager` gives real Cmd-Z and Edit-menu
> titles, but it also makes `NSDocument` mark itself edited — measured — which
> would raise an unsatisfiable save prompt on a document whose `writableTypes` is
> empty, so `updateChangeCount` is overridden to a no-op. On a non-APFS volume
> there is no slot, and the user is told the operation is irreversible *before* it
> commits rather than being charged a 4 GiB copy silently.

### 7.7 全面書き直しによる更新 — 決定(2026-09-14)

ZIP だけが在位更新(`ArchiveUpdater`:生き残る record を byte のまま運び、
中央ディレクトリを作り直す)を持つ。tar / 7z / LHA にも同じ在位更新を書くのは、
形式ごとに「生 record の範囲」を KaitoKit から引き出す改造が要り、solid 7z では
そもそも成立しない。代わりに **全面書き直し**を一つ書く:

- `GyoshukuKit.ArchiveRewriter` — KaitoKit が読める**どの形式**の書庫でも
  開き、削除・改名・追加を予約し、`commit()` で生き残る entry を全部
  `ArchiveWriter` へ流して、書ける形式(`.zip/.tar/.tarGzip/.sevenZip/.lha`)の
  新しい書庫を作る。`output` を与えれば原本を触らず別ファイルへ書く(= **形式変換**)。
  与えなければ原本を atomic に置き換える(= **更新**)。
- `ArchiveUpdater` と同じ面(`ArchiveEditing`)を持たせ、KaitoFinder の公開境界
  `publish` は形式で実装を選ぶだけにする。取り消しは同じ `willPublish` で
  clonefile の slot を取るので、そのまま効く。
- **代償を隠さない**:触っていない entry も再符号化される(`-lh7-` は `-lh5-` に、
  solid 7z は non-solid になる)。既知のパスワードとファイル名の暗号化設定は引き継ぐ。所要時間は
  変更量でなく書庫の大きさに比例する。KaitoFinder は capability に
  `.rewrite` を持たせ、通知欄に「編集すると書庫全体を再圧縮します」と出し、
  変換時は保存パネルで出力の暗号化設定を選べる(§7.9)。
- 生き残る entry は index 昇順に一つの reader から読む。KaitoKit は solid 群の
  decoder を連続した `stream()` 呼び出しの間で保持する(7z は folder ごとの
  coordinator、RAR は `solidState`)ので、この順なら solid 群を一度しか復号しない。
- `.tgz` は KaitoKit が `format == .tar` と報告し、外側の gzip を区別しない
  (実測 2026-09-14)。KaitoFinder が先頭 magic を嗅ぎ、`1f 8b` なら `.tarGzip`、
  なしなら `.tar`、bzip2 / xz なら読み取り専用(変換で逃がす)にする。

### 7.8 表示用の隠しファイルと保存操作 — 2026-09-15

- 隠し項目の表示は **完全なツリーに対する view filter** とする。末尾の名前が `.` で
  始まる項目、`__MACOSX` とその子孫を、検索と組み合わせて表示から除く。
  表示メニューの ⇧⌘. と設定 › 一般は同じ `ArchiveShowsHiddenFiles` を保存し、
  `didChange` で全ウインドウに反映する。既定は非表示。フォルダの展開状態は保持する。
  ステータスバーは表示対象の件数を数え、検索時だけ「絞り込み件数/表示対象の総数」にする。
- 編集では常に **完全な root** を使う。表示から消えた `.gitignore` との名前衝突を
  見逃さず、フォルダの削除・移動・改名や展開・ドラッグアウトで隠し子孫を落とさない。
  表示フィルターで元の node や `children` を縮めない。
- 追加時の除外は別の設定。`.DS_Store` の除外は既定で有効、隠し項目全体の除外は
  既定で無効。`ArchiveImportPlan.Options` を、文書のスレッド安全な設定スナップショットと
  作成 plan から渡す。最上位の選択と再帰列挙の両方に適用し、展開や既存項目の変換には適用しない。
  macOS の Foundation `contentsOfDirectory(at:)` は AppleDouble (`._*`) を列挙しないため、列挙経由の追加には除外設定に関係なく含まれない。
- 共通の保存パネルに圧縮レベルを置く。ZIP は「圧縮しない」(stored)、速い(1)、標準(6)、
  高い(8)、最高(9)。tar.gz は 1/6/8/9、7z と LHA は標準で固定、tar は非圧縮のため
  レベルを変更できない。設定値に最も近い段階から開始し、同距離なら高い方を選ぶ。
  形式を変えるとその形式の設定から選び直す。レベルの選択は今回だけに適用する。
- ファイル › 別名で保存…(⇧⌘S) は、`ArchiveCreationTransaction` で新しい保存先へ変換し、
  完了後に同じ文書の `fileURL`・型・session・capabilities・identity を更新する。
  Quick Look、実体化、サムネイルと旧 undo 履歴を破棄し、空の undo stack を用意する。
  最近使った項目にも登録する。元ファイルは変更せず、同一ファイル(path / symlink / hard link)
  への保存は拒否する。読み取り専用形式からも利用できる。暗号化された入力は既知の鍵を保存パネルの両欄へ
  入れ、暗号化を初期選択する。出力の鍵で新しい session を開く。ドロップによる変換は従来どおり別の文書を開く。
- 未対応言語の fallback は `Info.plist` の `CFBundleDevelopmentRegion = en` で指定する。
  プロジェクトの開発言語とカタログの sourceLanguage は `ja` のままとする。

### 7.9 パスワードの設定・変更・削除 — 2026-09-15

- 新規アーカイブ(⌘N)、Finder の圧縮サービス、ドロップからの形式変換、別名で保存は
  `ArchiveSavePanel` の同じ暗号化行を使う。既定はオフ、ZIP は AES-256、7z のファイル名暗号化はオフ。
  ZIP は ZipCrypto も選べる。tar / tar.gz / LHA は暗号化できず、チェックボックスを無効にして理由を示す。
  形式を切り替えても両パスワード欄の値は保ち、出力形式で有効な設定だけを `WriterOptions` へ渡す。
  `NSOpenSavePanelDelegate.panel(_:validate:)` が空欄と不一致を拒否し、保存パネルを開いたままにする。
- ファイルメニューの「別名で保存…」の直後に「パスワードを設定…」「パスワードを変更…」
  「パスワードを削除」を常に表示する。ZIP / 7z の開いた編集可能な文書だけが対象。
  設定は暗号化項目がないとき、変更・削除は暗号化項目があり鍵が既知のとき有効。ロック中・処理中は無効。
  RAR 等や tar / LHA は形式変換を案内するツールチップを出す。
- 設定・変更シートは `ArchivePasswordPrompt` とアクセサリのレイアウト規則を共有する。
  変更では古い鍵を再入力させない。空欄・不一致をインラインで表示し、確定ボタンを無効にする。
  削除は対象名と、暗号化せず書き直す説明を含む確認シートを出す。
- 三操作とも `ArchiveDocument.updatePassword` → `ArchiveSession.updatePassword` →
  `ArchiveImportTransaction.publish(mode: .rewrite(format))` を通る。mutate は空で、`commit()` が
  全項目を読み直す。入力の復号鍵は `password`、出力の鍵は `options.password` として分離する。
  削除は出力の鍵を nil にする。identity 照合、取消し、属性・quarantine の保持、進捗は通常編集と共通。
  鍵の採用・capabilities の再計算・一覧の再読込は公開成功後に行う。
- 通常編集は鍵が既知なら許可する。ZIP は `.inPlace` で既存 record を保持し、追加項目に同じ鍵を使う。
  既存の暗号化項目がすべて ZipCrypto なら追加も ZipCrypto、それ以外は AES-256。
  7z は `.rewrite(.sevenZip)` で同じ鍵とファイル名の保護を維持する。KaitoKit の entry metadata に
  header 暗号化フラグはないため、パスワードなしで一覧を開けるかを検査する。
  鍵が不明なら「暗号化されたアーカイブを変更するにはパスワードが必要です。」で拒否する。
  誤った既知の候補でも書き込まないよう、編集前に CRC / HMAC まで検証する。
- `writerOptions` のクロージャは従来の preferences snapshot を基礎とし、session が公開時に鍵を重ねる。
  worker は UserDefaults を読まない。平文入力への通常編集は平文を維持する。
- Undo スロットは clonefile の原本に対応する鍵・方式・header 設定をメモリ内に持つ。
  Undo / Redo は byte と鍵を一緒に入れ替え、7z の header も再び開ける状態にする。
  設定・変更・削除は専用の取り消し名を使う。パスワードは診断文やスナップショットに含めず、
  文書を閉じると session と履歴を破棄する。変更時は旧来の記憶済み鍵を除き、新しい鍵を自動保存しない。
- 保存パネルと全三シートは 26 言語で描画・`UISnapshot.overflowViolations` の対象とする。
  パスワード欄を隠しても必要な高さを確保し、長い翻訳では popup の固有幅からアクセサリ幅を決める。

## 8. 並行性

`ArchiveReader` は thread-safe ではない。

- `actor ArchiveSession` が閲覧用の primary reader を一つ持つ。
- 並列展開は `reopen()` した reader を worker ごとに配る(§3(i) の `sending`)。
- `solidGroup >= 0` が同じ entry は**同じ worker へ書庫順で**渡す。`-1` は自由。
- `EntryStream` は非 Sendable。isolation 境界を跨がせない。read loop は
  一つの domain に閉じる。
- UI へ渡すのは Sendable な snapshot だけ(`ArchiveEntry` は既に Sendable)。
- Approachable Concurrency は**有効にする**。アプリ target に
  `SWIFT_APPROACHABLE_CONCURRENCY = YES` と main actor 既定 isolation を設定し、
  重い展開・圧縮だけを `@concurrent` にする。設定は module 単位なので
  KaitoKit package 側は現状のままでよい。Swift 6.4 の既定は OFF で、
  そのままだと `nonisolated async` が暗黙に main actor を離れる。後から
  有効化すると意味が反転するため、最初に決めて動かさない。
- 進捗は `Foundation.Progress`。`ProgressManager` は macOS 27 なので使えない。

## 9. 安全性

- **path traversal**:KaitoKit は名前を verbatim で返す(`../escape.txt`、
  `/abs.txt`、重複名を含む)。展開層で必ず、先頭 `/` を落とし、`..` 成分を拒否し、
  解決後の実パスが出力 root の内側にあることを確認する。root を出る target を
  持つ symlink も拒否する。
- **quarantine**:書庫の `com.apple.quarantine` を展開物へ**伝播**させる。
  やらないと KaitoFinder が Gatekeeper 迂回路になる。`replaceItemAt` は
  quarantine を落とすので、書庫自身の印も編集後に付け直す。
- **RLO 偽装拡張子**を検出して警告する。
- 展開結果の宣言サイズを信用しない。Archive Utility は 4 GiB 以上を
  ZIP64 無しで mod 2^32 で書く(実測:5 GiB が 1 GiB)。
- 破損書庫の救済(`recoverDamagedArchives`)で得た byte は認証されていない。
  UI 上で明示する。

## 10. マイルストーン

| | 内容 | 出来上がるもの | 状態 |
|---|---|---|---|
| **M0** | repo、`.xcodeproj`(buildable folder 構成)、`../KaitoKit` への SwiftPM 依存、`NSDocument`、`NSOutlineView` 一覧、仮想フォルダ合成 | 書庫を開いて中身が見える | **完了** `163fafd` |
| **M1a** | 安全な展開エンジン(path traversal、quarantine 伝播、取り消し、fd 相対書き込み) | 展開の土台 | **完了** `5458eaf` / `4456df4` |
| **M1b** | drag out(file promise)、copy out(明示展開)、世代付き識別、進捗と取り消し | Finder へ取り出せる | **完了** `1871791` |
| **M1c** | Quick Look、Space、Open / Open With、遅延実体化 | 中身を見られる | **完了** `0902444` |
| **M2** | `GyoshukuKit` を起こす + ZIP writer、append、drag in / paste in | 書庫へ入れられる | **完了** |
| **M3** | 削除・改名・atomic replace、undo | 書庫内編集 | **完了** — GyoshukuKit `7fb2585` / `141469f`、取り消し基盤 `def0666`、モデル層 `fdb8b03`、UI `fac4b91`。新規フォルダ作成は M4 へ送った |
| **M4** | アイコン / カラム / ギャラリー表示、パスバー、タブ、絞り込み、サムネイル、暗号化書庫の鍵管理 | Finder らしさ | **完了(表示形式の切替は見送り、§10.1)** — 暗号化書庫 `576ef4d`、パスワードの記憶 `71decb2`、新規フォルダと絞り込み `53e534b`、ツールバー検索・パスバー・タブ・サムネイル `db72975`(検証 `2026-09-15-display.md`、描画は `manual-verification.md` §5) |
| **M5** | tar writer、7z writer、LHA writer、全面書き直しによる更新、形式変換 | 書ける形式が増える | **完了** — GyoshukuKit に tar + gzip `efba3cc`、7z `d0138b9`、LHA `2a9663a`。`ArchiveRewriter` `0c1ee85`(§7.7、検証 `2026-09-14-archive-rewriter.md`)。KaitoFinder の再圧縮モード編集 `846ceed`(検証 `2026-09-14-rewrite-mode.md`)。形式変換は M6 `1491bce` で実装 |
| **M6** | 新規書庫の作成 — ⌘N、Finder のサービスメニュー、読み取り専用書庫からの変換。作成元に quarantine があれば書庫へ伝播 | ファイルを圧縮できる | **完了** `1491bce`(検証 `2026-09-15-archive-creation.md`)。保存パネル・サービス・変換ダイアログの実挙動は `manual-verification.md` §4-5 / §6 |
| **M7** | ユーザー要望(2026-09-15): 同一ウインドウ内ドラッグの移動、ブランク領域の右クリック、ツールバー、設定ウインドウ(圧縮 / 展開)、一括展開、文言の macOS 化(書庫→アーカイブ、取り出す→展開、標準メニュー) | Finder の作法と日常のアーカイブ操作 | **完了** — 移動 `906c0e1`、右クリックとツールバー `76b2d66`、設定 `dfac011`、文言 `8df2ad6`、一括展開 `37ec1fc`。クラッシュ修正 `4135e04` / `2d05b22` / `d8e9d72`(いずれも @MainActor の ObjC 面を AppKit / QL がバックグラウンドから呼ぶ型) |
| **M8** | リリースに向けた磨き込み(2026-09-15): プロセス内スナップショット基盤とはみ出し監査、パスワード UI の修正、ロック状態・設定・進捗・ステータスバーの Finder 化、10 言語対応(Apple の語彙に追随)、実運用シーンのテスト | 出荷品質 | **完了** — 監査基盤 `c1da7e1`、UI 洗練 `cdac130`、10 言語 `d7b9067`、シーンテスト 28 件と 8 件の修正 `6046b80`(検証 `2026-09-15-scenarios.md`)。`6046b80` が持ち込んだ回帰(identity の ctime 照合 → 文書を開くと LaunchServices の拡張属性で全読み取りが拒否)は `3b93b4b` で修正。ウインドウのカスケード、エラー文言の 10 言語化(`ArchiveErrorText`)、スナップショットの世代管理(検証 `2026-09-15-cascade-error-text.md`) |
| **M9** | ユーザー要望(2026-09-15) 第 2 弾: 英語フォールバック、隠しファイル、圧縮レベル、別名で保存、暗号化 UI、ようこそウインドウ | 日常操作の追加と形式変換 | **Wave A 完了・検証済み** — ユーザーのシェルで XCTest 544 件、失敗 0、スキップ 0、Release smoke 成功(ユーザー報告)。[Wave A 検証](verification/2026-09-15-wave-a.md)。**Wave C 実装完了** — 暗号化付き保存、パスワード設定/変更/削除、既知の鍵による編集と Undo/Redo、10 言語の UI 監査テストを追加。ユーザーのシェルで build 成功。全件実行の順序依存の失敗はテスト用ウインドウのアニメーション待機が原因と判明し、起動時の無効化で 563 件・失敗 0(ユーザーによる追補前の検証)。テスト基盤への恒久対応とエージェントの sandbox 内の検証範囲は [暗号化 UI 検証](verification/2026-09-15-password.md)。**Wave B ウェルカムウインドウ完了** — ようこそ専用 17 テストを追加。補助 XCTest は 49 件中 43 成功・失敗 0・sandbox 制約で 6 スキップ。ようこそと設定の一般タブは 10 言語 × 両外観の 40 描画ではみ出し 0 件。[ようこそ検証](verification/2026-09-15-welcome.md)。**Wave D 実装完了** — 全 292 キーと Services に 16 言語を追加し、計 26 言語。文体・用語テストと描画監査を拡張。ユーザーのシェルで XCTest 598 件・失敗 0(2 回目。1 回目の 1 件失敗は KaitoKit の ZipCrypto 判定が原因、修正済み)、Release 実機で th / ru / pt-PT を確認。全件検証・Release smoke と標準 build / test の sandbox 制約・補助検証の実測は [言語検証](verification/2026-09-15-languages.md) |
| **M10** | リリース準備: README の全面更新、対応形式の宣言(StuffIt / StuffIt X / Zstandard、txz / zipx / deb の別識別子)、形式名の表示、言語の二次レビュー 39 件、CAB の識別子修正、大規模アーカイブの実測(10 万・50 万件) | 現行機能の案内と Finder の形式認識 | 完了(検証: オーケストレータ、LaunchServices 実測) |

M1 が read-only のまま**全形式で有用**なのが要点。ここで sandbox 周りと
promise 周りの実地確認を済ませてから書き込みへ進む。

M1 は三つに割った。安全側の中核(M1a)を先に単体で固め、UI を被せる前に
敵対的レビューへかけたためで、実際に 21 件の候補から 5 件の実在する欠陥が出た
(`Documentation/verification/2026-09-10-extraction-safety.md`)。

### 10.1 完成の定義(2026-09-14)

「KaitoFinder の完成」を次の三つで判定する。どれか一つでも欠けていれば未完成。

1. §10 の各行が **完了** か、理由付きの **見送り** になっている。
2. §12 の各項が **解決** か、ユーザーが実機で行う確認手順が
   `Documentation/manual-verification.md` に書かれている(この環境では画面収録も
   Accessibility も使えないので、描画とドラッグの実挙動は自動化できない)。
3. 自動テストが三つのリポジトリで全件通っている。
4. 作った app を fixture 付きで起動し、ウインドウが出て正常終了する(§11.5 の Release ビルドで)。

Developer ID による署名と notarize はこの環境に鍵が無く、ユーザーの Mac で行う(§11.5)。

**書き込み時の暗号化は実装済み**(ZIP AES-256 / ZipCrypto、7z AES-256 とファイル名暗号化)。UI と取り消しの扱いは §7.9、今回の検証範囲は [検証報告](verification/2026-09-15-password.md)。

**見送り(ユーザーが覆せる)**:

| 項目 | 理由 |
|---|---|
| bzip2 / xz で包んだ tar の作成・更新 | writer が gzip 包装しか持たない。`.tar.bz2` / `.tar.xz` は読み取り専用のまま、変換で逃がす |
| アイコン / カラム / ギャラリー表示 | Finder らしさの中核はリスト表示で満たしている。描画をこの環境で確認できないため、パスバー・タブ・サムネイルまでを実装し、表示形式の切替は後回し |
| 動画・音声のサムネイル | 画像のみ。動画は `QLThumbnailGenerator` が entry の実体化を要求し、遅延実体化の設計と衝突する |

## 11. 検証方針

KaitoKit の作法を引き継ぐ。

- writer は**参照実装との差分テスト**。書いた ZIP を `unzip -t`、`7zz t`、
  `ditto -x`、Windows の Explorer で開く。書いた tar を `bsdtar -tvf` と
  GNU tar で読む。**書いたものを KaitoKit 自身で読み直す**往復も必ず行う。
- clean-room の byte 表からテスト入力を組み立てる(`ArArchiveBuilder` と同じ形)。
- 実測はすべて `Documentation/verification/YYYY-MM-DD-*.md` に残す。

2026-09-16 の Release ビルドによる[大規模アーカイブの実測](verification/2026-09-16-scale.md)では、
ウインドウ出現までの時間 / dirty footprint は 10 万件で約 1.3 s / 232 MB、
50 万件で約 4.2 s / 924 MB。100 万件は KaitoKit の保持メタデータの合計上限
`maxTotalMetadataSize`(256 MiB)で拒否された。約 25 万件を超える読み込みは
KaitoKit PR #28(`fix/zip-first-candidate-budget`)の修正に依存する。
同日、50 万件の一括展開が書き始めないことから、フォルダ選択の解決が
O(トップレベルのフォルダ数 × 全 entry 数) だったのを線形に直した
([記録](verification/2026-09-16-subtree-resolution.md)。5,000 フォルダ × 20,000 entry で
231 s → 1 s 未満)。Release の 50 万件の一括展開は約 190 s で、`unzip` の 38 s に対する差は
ファイルごとの親ディレクトリの開き直しと path 検査に集中している(同記録の「残る伸びしろ」)。

**テストプロセスではウインドウの自動アニメーションを無効にする。** 表示されないテスト用
ウインドウでもシート表示・文書の close が `_NSWindowTransformAnimation` を開始し、
`_runBlocking` が GCD ワーカーを占有したまま残る。ユーザーの調査では全件実行中に
`task_threads` が 9 → 96（うち 80 がアニメーション待機）へ増え、プールの枯渇で
`NSDocumentController` の Coordination キューが開始できず、内包書庫の open がタイムアウトした。
テストバンドルの principal class `TestProcessSetup` が全テストより先に
`NSAutomaticWindowAnimationsEnabled = false` を `UserDefaults.standard.register(defaults:)` で
揮発性の登録ドメインへ登録し、アプリの保存済み設定には書き込まない。無効化後は 23 スレッド以下、
全 563 件成功（ユーザー報告）。標準の名前順で末尾の `ZZProcessHealthTests` が登録を確認し、
`task_threads` を一度だけ取得して 48 を超えたら失敗させる。取得した Mach ポートの送信権と配列も解放する。
詳細は [Wave C 検証報告](verification/2026-09-15-password.md#追補テストプロセスのウインドウアニメーション)。

## 11.5 配布(sandbox なし・notarize 済み)— 2026-09-15

ユーザーの決定は「sandbox なし、notarize して配布」。現状と手順:

- **project の設定(確認済み)**: `ENABLE_APP_SANDBOX = NO`、Release は
  `ENABLE_HARDENED_RUNTIME = YES`、`CODE_SIGN_IDENTITY = "-"`(ad-hoc)、
  `MACOSX_DEPLOYMENT_TARGET = 26.0`。entitlements ファイルは無い(sandbox も
  例外的な権限も要らない)。Release ビルドは通り、ad-hoc 署名 + hardened runtime で
  起動・文書オープン・終了まで確認した(`2026-09-15-launch-smoke.md`)。
- **この環境に無いもの**: Developer ID 証明書と App Store Connect の API 鍵。
  従って署名・notarize はユーザーの Mac で行う。
- **手順**(Xcode の GUI なら Product › Archive › Distribute App › Developer ID で同等):
  1. `xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -configuration Release
     archive -archivePath build/KaitoFinder.xcarchive CODE_SIGN_IDENTITY="Developer ID Application: <名前> (<TEAM>)" DEVELOPMENT_TEAM=<TEAM>`
  2. `xcodebuild -exportArchive -archivePath build/KaitoFinder.xcarchive -exportPath build/export
     -exportOptionsPlist <method=developer-id, teamID の plist>`
  3. `ditto -c -k --keepParent build/export/KaitoFinder.app build/KaitoFinder.zip`
  4. `xcrun notarytool submit build/KaitoFinder.zip --keychain-profile <profile> --wait`
     (`notarytool store-credentials` で API 鍵か Apple ID を一度登録しておく)
  5. `xcrun stapler staple build/export/KaitoFinder.app` → `spctl -a -vv` で `accepted` を確認
- **Finder のサービス**: `NSServices` は LaunchServices が app の登録時に拾う。
  `/Applications` に置いて一度起動すれば「KaitoFinderで圧縮」が Finder の
  サービス(クイックアクション)に出る。出ない時は
  `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/KaitoFinder.app`。
- **KaitoKit / GyoshukuKit の参照**: 現在は `../KaitoKit` へのパス依存(§2.2)。
  配布用の archive はこの checkout 配置のままで作れる。tag 参照へ切り替えるなら
  release ブランチで `Package.swift` の `.package(path:)` を差し替える。

## 12. 未解決事項(実装中に実地で潰す)

1. **Finder は directory promise を実際に満たすか。** API は `public.folder` を
   許すことをヘッダで確認済みだが、Finder の実挙動は未確認。自動化には
   Accessibility 権限が要り、この環境では keystroke 送信が拒否された。**実機で手で
   確認する — 手順は `Documentation/manual-verification.md` §1。** 満たさない場合は、部分木を一つの promise で
   なく、展開済み temp を渡す経路へ落とす(hard link の扱いが劣化する)。
2. ~~**`LSFileQuarantineEnabled` は無条件に付けるのか、伝播するのか。**~~ **解決(2026-09-14、設計判断)。**
   **宣言しない。** `Info.plist` に鍵を置かず、伝播は自前で行う:取り出したファイルには
   書庫の `com.apple.quarantine` を `ExtractionQuarantine` がそのまま写し(M1a)、
   作った書庫には作成元のどれかに付いていた印を写す(M6)。無条件に付けると
   自分で作った書庫にまで印が付き、付けなければ「印付きの app をフォルダごと
   固めて、また取り出す」で印が消える迂回路になる。この二つの伝播で両方を塞ぐ。
   実機での確認は `Documentation/manual-verification.md` に置く。
3. ~~**undo をどう持つか。**~~ **解決(2026-09-10)。** 当初案の 2 つはどちらも採らなかった。
   `NSFileVersion` はファイル全体を複製するので 4 GiB 級で破綻し、entry model 上の
   undo stack は削除された byte を持たない。書庫ファイルそのものを `clonefile` で
   退避する方式に決めた — 1 GiB が 0.2 ms・ディスク 0。`backupItemName` は退避物が
   ユーザーのフォルダに生えるため実測の上で棄却。設計は §7.6、測定は
   `Documentation/verification/2026-09-10-undo-model.md`。
4. ~~**`reopen()` の並列展開は本当に速いか。**~~ **解決(2026-09-10)。** 実測した。
   独立 entry は 8 worker で 6.76x 伸び、`pread` は直列化しない。ただし solid 群を
   分断すると直列より遅く(0.95x)、`solidGroup` で束ねるだけの実装は独立 entry が
   `-1` を共有するため ZIP を直列に落とす(0.99x)。正しい規則と数値は
   `Documentation/verification/2026-09-10-parallel-extraction.md`。
   現状の `ExtractionService` は一要求一 reader の直列で、この伸びしろは未取得。

> **Open questions.** One of the original four remains, and it needs the real app
> rather than a guess: whether Finder actually fulfills a directory promise (the
> API permits it, but synthetic keystrokes are blocked in this environment, so it
> is confirmed by hand — see `Documentation/manual-verification.md`). Quarantine
> was **settled as a design decision on 2026-09-14**: `LSFileQuarantineEnabled` is
> not declared; instead the app propagates the mark itself — archive → extracted
> files (M1a) and quarantined sources → the archive it creates (M6) — which closes
> both the over-marking and the "compress-then-extract" bypass. The other two were
> **settled by measurement on 2026-09-10**.
> Parallel extraction through `reopen()` does scale — independent entries reach
> 6.76x at eight workers because `pread` does not serialize — but splitting a
> solid group is *slower* than serial, and bucketing purely by `solidGroup`
> collapses a ZIP to one bucket because independent entries all share `-1`; the
> engine is still one serial reader per request, so that speedup remains
> unclaimed. Undo (§7.6) discarded both surveyed designs in favour of cloning the
> archive file itself into a same-volume temp slot: 0.2 ms and zero disk for
> 1 GiB, versus an `NSFileVersion` store that would copy every 4 GiB archive per
> edit and an in-memory entry stack that cannot restore deleted bytes.
