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
drop target の受け入れを**すべて**ここから駆動する。書けない書庫に drop の
ハイライトを出さない。使えない動詞は、どの形式制限が原因かを言う。

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
> every drop target, so a drop highlight never appears on an archive that cannot
> be written.

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
| 設定・情報を見る・inspector | `NSHostingView` で SwiftUI |

`NSDocument` は**読み取り専用の器**として使う。`readFromURL:ofType:` を
override して super を呼ばない(継承実装は NSFileWrapper 経由で書庫全体を
memory へ載せ、KaitoKit の遅延読みを潰す)。`isEntireFileLoaded` は NO、
`autosavesInPlace` / `preservesVersions` は NO、`writableTypesForSaveOperation:`
は空配列。書き換えは NSDocument の保存機構ではなく後述の atomic replace で行い、
`revertToContentsOfURL:` で同期し直す。

日本語 UI の語彙は Finder 自身の `ja.lproj/*.strings` に合わせる(項目、など)。
文字列は `.xcstrings`。

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
- 暗号化は AES-256 (AE-2) を既定、ZipCrypto は「古い方式」と明示して選択可能に。
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
  macOS metadata(`._` AppleDouble、`SCHILY.xattr`)は**既定で書かない** ——
  Apple の bsdtar は既定で書き、それが Mac 製書庫が Windows で嫌われる主因。
  uid/gid は既定 0、uname/gname は空。
- **gzip / bzip2 / xz**:gzip は zlib windowBits 15+16 と `deflateSetHeader`。
  bzip2 は既存の `CBzip2` systemLibrary をそのまま使う。xz は当面
  `COMPRESSION_LZMA`(実測で `xz -t` を通る本物の container、ただし check なし・
  level 6 固定・単一 block)。zstd は macOS に無いので対象外。
- **7z**:Apple の Compression framework が出す `.xz` から **LZMA2 payload を
  そのまま抜き出して** 7z の coder として使えることが実測で分かっている
  (props 0x16、終端 0x00 込み)。LZMA encoder を書かずに non-solid・非暗号・
  平ヘッダの 7z writer が作れる。比率は 7-Zip 本家に劣る。
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
| **M3** | 削除・改名・新規フォルダ、atomic replace、undo | 書庫内編集 | 進行中 — GyoshukuKit の `remove` / `rename` `7fb2585`、取り消し基盤 `def0666`。残りは削除・改名の UI |
| **M4** | アイコン / カラム / ギャラリー表示、パスバー、タブ、絞り込み、サムネイル、暗号化書庫の鍵管理 | Finder らしさ |
| **M5** | tar writer、7z writer、LHA writer、形式変換 | 書ける形式が増える |

M1 が read-only のまま**全形式で有用**なのが要点。ここで sandbox 周りと
promise 周りの実地確認を済ませてから書き込みへ進む。

M1 は三つに割った。安全側の中核(M1a)を先に単体で固め、UI を被せる前に
敵対的レビューへかけたためで、実際に 21 件の候補から 5 件の実在する欠陥が出た
(`Documentation/verification/2026-09-10-extraction-safety.md`)。

## 11. 検証方針

KaitoKit の作法を引き継ぐ。

- writer は**参照実装との差分テスト**。書いた ZIP を `unzip -t`、`7zz t`、
  `ditto -x`、Windows の Explorer で開く。書いた tar を `bsdtar -tvf` と
  GNU tar で読む。**書いたものを KaitoKit 自身で読み直す**往復も必ず行う。
- clean-room の byte 表からテスト入力を組み立てる(`ArArchiveBuilder` と同じ形)。
- 実測はすべて `Documentation/verification/YYYY-MM-DD-*.md` に残す。

## 12. 未解決事項(実装中に実地で潰す)

1. **Finder は directory promise を実際に満たすか。** API は `public.folder` を
   許すことをヘッダで確認済みだが、Finder の実挙動は未確認。自動化には
   Accessibility 権限が要り、この環境では keystroke 送信が拒否された。**M1 で
   実アプリを使って手で確認する。** 満たさない場合は、部分木を一つの promise で
   なく、展開済み temp を渡す経路へ落とす(hard link の扱いが劣化する)。
2. **`LSFileQuarantineEnabled` は無条件に付けるのか、伝播するのか。** 付けすぎれば
   自分の書庫にまで印が付いて邪魔、付けなければ迂回路になる。宣言した版と
   しない版を作り、Safari 由来の書庫とローカル生成の書庫の両方で `xattr -p` する。
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

> **Open questions.** Two of the original four remain, both needing the real app
> rather than a guess: whether Finder actually fulfills a directory promise (the
> API permits it, but synthetic keystrokes are blocked in this environment, so it
> is confirmed by hand at M1), and what `LSFileQuarantineEnabled` actually does,
> since over-applying it is hostile and under-applying it makes the app a
> Gatekeeper bypass. The other two were **settled by measurement on 2026-09-10**.
> Parallel extraction through `reopen()` does scale — independent entries reach
> 6.76x at eight workers because `pread` does not serialize — but splitting a
> solid group is *slower* than serial, and bucketing purely by `solidGroup`
> collapses a ZIP to one bucket because independent entries all share `-1`; the
> engine is still one serial reader per request, so that speedup remains
> unclaimed. Undo (§7.6) discarded both surveyed designs in favour of cloning the
> archive file itself into a same-volume temp slot: 0.2 ms and zero disk for
> 1 GiB, versus an `NSFileVersion` store that would copy every 4 GiB archive per
> edit and an in-memory entry stack that cannot restore deleted bytes.
