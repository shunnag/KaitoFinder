# S35 / P10-a・S36 / P10-b: フォルダへの移動と表示オプション

2026-09-26。S35 はオーケストレータが検証し、`4d4be0b` にコミットした。
以下に S35 初回・[correction 1](#s35-correction-1)・オーケストレータの検証を残し、
末尾に [S36 / P10-b](#s36--p10-b-表示オプション) を追記した。**S36 は未コミット**。
各段の通常host・実入力の実施状況は、それぞれの節を参照。

仕様: [P8-P9-P10 の P10-a](../pending/specs-2026-09-26/P8-P9-P10.md)、
[ORDER-P6-P13 §2](../pending/specs-2026-09-26/ORDER-P6-P13.md)。
利用者の2026-09-26の承認どおり、フォルダを開く既定は `.enter`。
行番号ではなく型・関数名で確認し、仕様が参照する既存の型・関数に欠落はなかった。

## 出自とビルドの隔離

canonical の `feature/2026-09-24-review`、clean な `b450765f78c15e4a7d69058b0b856e4ab221f34c` から着手。
`git archive --format=tar <commit>` で次の三つを
`build/P10S35Verification/layout/{KaitoFinder,GyoshukuKit,KaitoKit}` に展開した。
以後、KaitoFinder の製品・試験・Tools だけを canonical の内容で更新した。

| 対象 | 固定 commit |
|---|---|
| KaitoFinder の基底 | `b450765f78c15e4a7d69058b0b856e4ab221f34c` |
| GyoshukuKit | `52655cbd76f73f97f4715d06baed1478d6b30a47` |
| KaitoKit | `823ad460faab055b6b7051da10583480785e8f68` |

[source-checks.json](../../build/P10S35Verification/source-checks.json) で、固定archiveの全ファイル
（KK1,513 / GK295）が隔離先と一致し、最終KFの製品137 / 試験172 / Tools21ファイルもcanonicalと一致することを確認。
live sibling と `GyoshukuKit-p14` はビルド・変更していない。
兄弟リポジトリへ行った操作は固定 commit の `git archive` のみ。
[archive-checks.json](../../build/P10S35Verification/archive-checks.json)、
[compiled-sources.json](../../build/P10S35Verification/compiled-sources.json) に出自とコンパイル入力を記録。

## 実装と AC

- **a1**: window ごとの現在位置、各100件の戻る・進む、32件の表示状態のLRU。
  戻る・進むでは選択・展開・スクロールを復元し、新しい移動では復元しない。
  内包フォルダへは出てきた子を選択する。パスバーの現在位置では履歴を増やさない。
  複数フォルダの「開く」はその場で展開する。`.expand` は従来の動作。
- **a2**: 検索は書庫全体を表示し、消すと現在のフォルダと検索前の選択へ戻る。
  結果からの移動は検索を同期で消し、未完了の非同期検索も取り消す。
  `displayedRoot` の代入は init・navigate・reloadFilteredEntries の3か所。
  表示の差し替えでは旧表示を collapse してから代入する。P8 の requested/applied の区別を維持。
- **a3**: 再読込では現在位置をパスで解決し直し、消失・非表示なら最も近い祖先へ戻る。
  改名・移動の公開成功後は現在位置と履歴・保存状態のパスを書き換える。undo/redo では追従しない。
  表示の根自身と外側の node を expand/collapse/選択/scroll の対象にしない。
- **a4**: ペースト・追加・空白の新規フォルダ・ドロップは表示中の場所へ。
  追加パネルは開いたときのパスを保持し、消えた追加先で処理を始めない。
  すべて展開・無選択の展開は従来どおり書庫全体。
- **a5–a6**: 「移動」メニュー、⌘[・⌘]・⌘↑、戻る/進むのツールバー、設定のpopup。
  NSText が first responder の間は3メニューを無効にし、ツールバーの判定は独立。
  設定を `.expand` に変えると全ウインドウが最上位へ戻り、履歴を消去。
  `ArchiveFolderOpening` を TestProcessSetup と AutosaveIsolationTests に追加。
- **a7**: `testNavigationScaleWhenEnabled` を追加。500,000件・5,000フォルダの木で enter/back/enclosing をそれぞれ測り、50 ms以下を検査。
  最適化した受入計測は今回未実行。
- **a8 / AC-W**: Localizable の7キーと新しい GoMenu table の1キーに、26言語の translated 値。
  既存の `移動`（Move）を含め、既存の訳は変更していない。French colon の改行しない空白も検査。
- **a9**: 関連する試験を追加・更新。通常 host の全件は未実行。

### AppKit のコンストラクタについて

仕様の `NSToolbarItemGroup(itemIdentifier:images:selectionMode:labels:target:action:)` を
サブクラス名で呼んでも、このSDK/ランタイムでは基底の `NSToolbarItemGroup` が返り、
サブクラスの `validate()` が使われなかった（初回試験で確認）。
そのため `ArchiveNavigationToolbarItemGroup` は指定初期化子と `.momentary` の
`NSSegmentedControl` を使う。二つの subitem の有効状態と実際の segment の有効状態を同期し、
メニューの NSText 規則を通さない。画像の accessibility description と各segmentのtooltipも各操作名。
実クリック・アクセシビリティの最終確認は通常hostで行う。

### 既存の試験を変えた理由

- ArchiveFinderInteractionTests の従来のダブルクリック・⌘矢印の assert はそのまま。
  その2試験だけ `.expand` を注入し、`.enter` の実入力試験を別に追加。
- ArchiveDisplayTests の既定ツールバー一覧の先頭に `navigation` を追加。
- WordingAcceptanceTests のメニュー一覧に GoMenu の題を追加し、3項目・キー・responder chainを検査。
- LayoutOverflowTests の一般タブの popup 一覧に folderOpeningPopup を追加。
- FileURLDragInfo は空のURL配列ならpasteboardへ書かない。新しいlocal move試験はURLを使わないため。
  非空配列の既存の書き込み assert は残した。
- 設定の既定値と不正値、autosave の一覧に新しい設定を追加。

## 実行した検証

実行環境は **macOS 27.2 (26B5091g)、Apple Swift 6.4**。
Swift 6言語モード、製品はdefault isolation = MainActorと既存のupcoming featureを維持。
最終ビルドは兄弟・製品・試験とも `-target arm64-apple-macos26.0` を明示。
実行自体はmacOS 27.2上なので、macOS 26実機での確認ではない。
初期のビルド・試験はhost既定の27.2 targetだったため、26 targetで作り直して関連試験を実行した。
初期の保存済みcommand/logは [pre-target26](../../build/P10S35Verification/pre-target26/)。
実際のSparkle frameworkを使用。依存Swift moduleは固定archiveから新規に作ったもののみ。

### ビルド

`build/P10S35Verification/build.py` を使用した直接 `swiftc` コンパイル・リンク。
KK207 / GK62 / 製品104 / 試験150 Swift files。`xcodebuild` と `swift test` は今回起動していない。

- `--prepare KaitoKit GyoshukuKit`: 成功。
- `--sync app`: 成功。
- `--sync test`: 成功。
- `--sync app test`: 初期修正の3回とも成功。
- `--sync KaitoKit GyoshukuKit app test`: macOS26 targetでの作り直し、成功。
- `--sync app test`: 最後のtoolbar delegate判定とtest-host guardを反映、成功。
- `--sync test`: pasteboardを使わないlocal move試験を追加した最終試験ビルド、成功。

非DEBUG構成（`-DDEBUG` を除いた `swiftc -typecheck`）もexit0。
最終コンパイル入力のSHA-256とcanonicalの製品・試験が一致し、`git diff --check`も成功。
最終製品にcompiler診断はなく、試験のwarningは既存のArchiveDocumentControllerTests・ArchiveEditTests・ArchiveImportSafetyTestsのみ。
詳細は [app-command.json](../../build/P10S35Verification/app-command.json)・
[test-command.json](../../build/P10S35Verification/test-command.json)・各 `*-build.log`。

### XCTest

直接 `xctest -XCTest KaitoFinderTests.<selector> <bundle>` で実行。
通常のXcode application test hostの代わりにはならない。
[全93起動の一覧](data/2026-09-26/p10-navigation-test-runs.tsv) と
[command・環境・case・logの記録](../../build/P10S35Verification/test-results.json) に途中の失敗・反復・skipを含めた。
二つの短い起動が並行した際の集計上書きを、生ログから復元した（`recovered_from_log`）。
最終対象は [final-selection.json](../../build/P10S35Verification/final-selection.json)。

macOS26 targetの50起動と最後のlocal move単独1起動は **88成功・22skip・assertion失敗0、1起動が終了コード69で中断**。
中断は既存の `ArchivePreferencesUITests.testSavePanelAndSettingsShareDefaultFormat`。
システムの保存パネル作成時に `ClientCallsAuxiliary` / `HostCallsAuxiliary` のXPC接続が
`Connection invalid` となり、case完了の行に到達しなかった。
同じselectorの基底比較は今回行っていない。通常hostでの再確認が必要。

| 最終対象 | 結果 |
|---|---|
| ArchiveFolderNavigationTests | 17成功・3skip（pasteboard、failure sheet、opt-in規模計測） |
| ArchiveFinderInteractionTests | 2成功・13skip（native input runnerなし） |
| AsyncSearchFilterTests | 18成功・3skip（通常hostのシート・password・Quick Look） |
| M6bSearchTests | 1成功 |
| ArchivePreferencesTests / AutosaveIsolationTests | 7 / 2成功 |
| ArchiveDisplayTests（bundle言語照合以外の17 selector） | 17成功 |
| ArchivePreferencesUITests（9 selector） | 8成功、保存パネルの1起動がexit69 |
| ArchiveEntryControlsTests（14 selector） | 13成功・1skip（既存のLaunchServices public.folder判定） |
| DeferredSaveUITests（pending選択・undoによる木の縮小） | 2成功 |
| 新規blank file drop / menu integration | 各1skip（pasteboard service / compiled nibなし） |
| 最後に追加したblank local move（pasteboard fileなし） | 1成功。現在のフォルダへの同一位置の提案・受入をともに拒否し、原本は不変 |

初回の移動クラスは11成功・5失敗・2skip。toolbar factoryが基底型を返す問題、
空のpasteboard書き込み、抽出対象の並び順を表示順と比較した試験、既存出力先へのwriter新規作成、
pasteboard service不足を切り分けた。
第2回は14成功・2失敗・3skip（toolbarのtarget/選択の橋渡しと、置換fixtureのファイル名再利用）。
その後のtoolbar単独1回も選択の橋渡しで失敗し、修正後の3 selectorは全て成功。
最終版の移動クラスは上表のとおり。
製品の問題はtoolbarの構築とactionの接続を修正し、fixtureは新しいZIPを別名で作ってatomicに置換する形に直した。
抽出対象は実際の `root.children` の順序・identityで比較する。
既存のassertを環境に合わせて弱めていない。

新規のpasteboard利用試験は、pasteboard serviceへ書けない場合にskip。
追加パネルの失敗alertとメニュー連携の試験はアプリのtest host/compiled nibが無い場合にskip。
既存のnative input試験は専用runnerが無いとskipし、今回も実キー入力は送っていない。

### 文言

`xcstringstool compile` は最初に2ファイルを一度に渡してusage error（exit64）。
1ファイルずつに直して2回とも成功。
コンパイルした52個の `.strings`（2 table×26言語）を調べ、追加した208値がcatalogと一致。
さらに `check-resources.swift` から各 `.lproj` を `Bundle` として開き、tableを指定した208値のlookupも一致。
[検査結果](../../build/P10S35Verification/resource-checks.json)。

WordingAcceptanceTests のcatalog全体・26言語style・ellipsisの計28 selectorが成功。
新しい2試験のbuilt app bundle照合と、26言語でのメニュー・layoutの試験は通常hostでの実行待ち。

### 今回実行していないもの

通常hostの全件、`Tools/verify_finder_interactions.py`、`Tools/verify_ui_integration.py`、
実キー入力、500kの最適化したAC-a7計測、HFS+ / FAT32 / exFAT のvolume試験。
既存の `ScenarioDiskTests` と `Support/VolumePublishFixture.swift` は
hdiutilの起動失敗と非0終了をXCTSkipにすることを確認し、変更していない。

## GoMenu の26言語

このMacの `/System/Library/CoreServices/Finder.app/Contents/Resources/<language>.lproj/LocalizableMerged.strings` の
`FR24`（英語 Go）で値を確認した。言語フォルダ名は pt_BR / pt_PT / zh_CN / zh_TW / no を対応付けた。

| language | GoMenu「移動」 |
|---|---|
| ja | 移動 |
| en | Go |
| de | Öffnen |
| fr | Aller |
| es | Ir |
| it | Vai |
| pt-BR | Ir |
| zh-Hans | 前往 |
| zh-Hant | 前往 |
| ko | 이동 |
| th | ไป |
| vi | Đi |
| id | Buka |
| ms | Pergi |
| hi | जाएँ |
| ru | Перейти |
| nl | Ga |
| pl | Idź |
| tr | Git |
| sv | Gå |
| da | Gå |
| nb | Gå |
| fi | Siirry |
| uk | Перейти |
| cs | Otevřít |
| pt-PT | Ir |

## オーケストレータへの引継ぎ

固定した兄弟を使うには、隔離した
`build/P10S35Verification/layout/KaitoFinder/KaitoFinder.xcodeproj` をbuild/testする。
実入力runnerも **隔離した `layout/KaitoFinder/Tools/verify_finder_interactions.py --focused`** を使う。
canonicalのToolsから実行するとlive siblingを参照するため、この検証には使わない。
画面ロックがなくMacが空いている状態でAC-a5とUIを検証する。

AC-a7はP8と同じ `-O` / wholemoduleのDebug buildを使い、
`TEST_RUNNER_KAITOFINDER_PERFORMANCE_PROBES=1`、`TEST_RUNNER_KAITOFINDER_PROBE_ENTRIES=500000` で
`ArchiveFolderNavigationTests/testNavigationScaleWhenEnabled` を1回実行し、3本の `PROBE-NAVIGATION` 行を記録する。
S35の検証とcommit後、同じthreadでS36を開始する。今回はS36へ進まない。

## S35 correction 1

2026-09-26。オーケストレータから、固定 GK `52655cb` / KK `823ad46` の通常 Xcode test host で
build-for-testing 成功、全1,625件で既知のGUI環境依存失敗に加えて新規の決定的失敗2件、との報告を受けた。
`ApplicationCommandIntegrationTests` と `LayoutOverflowTests/testLockedPlaceholderInEveryLanguage` を
画面ロック解除後に絞っても再現し、前者の他10件は成功した、という報告に対する修正。
この通常hostでの実行はオーケストレータによるもので、以下のCodexの実行数には含めない。

### 修正内容と切り分け

- **navigation group 本体の無効化（製品の修正）**:
  `ArchiveNavigationToolbarItemGroup.validate()` が、戻る・進むの判定から
  group 自身と control 全体の `isEnabled` も設定する。
  その後に個別の subitem / segment を設定し、一方だけ使える状態も保つ。
  履歴なし・sessionなし・ロック中には group、control、両 subitem、両 segment が全て無効になる。
- **Open（試験の準備の修正）**:
  `validateMenuItem(openEntry:)` は `selectionOpenRefusal(skippingDirectories: true)` を使い、
  単一フォルダを許可していた。製品の Open 判定と `openEntry(_:)` は変更していない。
  `testOpenMenuValidationAllowsASingleFolderInEnterMode` を追加し、無選択では無効、フォルダ選択で有効、
  実行で `a` へ移動することを確認した。
  失敗した integration 試験は `NSApp` の nil-target dispatch に依存する一方、
  アプリのアクティブ化を待たず、新しく作ったメニューも main menu に設置していなかった。
  同クラスの既存toolbar/responder試験は `window.firstResponder.tryToPerform` を使うため、
  非アクティブなhostでも動作し、この前提を保証しない。
  `ArchivePreviewSidebarTests` / `ArchiveColumnsTests` のメニュー試験と同じく delegate を保持して
  `NSApp.mainMenu` に設置し、自動タブ化を止め、activate / key / main の成立を待ってから
  outline を first responder にする形へ修正した。
  選択が `a`、controller の validation が true、nil-target の実際の送り先が当該controllerであることも
  `menu.update()` / `performMenuItem` の前に検査する。通常hostでの修正後の成功確認は未実施。
- **実際の segment とラベル表示（製品と試験の修正）**:
  `NSSegmentedControl` 自身に controller / `navigateFromToolbar(_:)` を接続し、
  指定初期化子で作った group がサポートしない `selectionMode` の設定を削除した。
  control の `.momentary` は維持する。
  `testToolbarControlAndTextSubitemsNavigateAndValidate` で、iconOnly / iconAndLabel / labelOnly の各表示で
  segment 0・1を `performClick(_:)` し、戻る・進むの実際の位置と enabled 状態を検査する。
  labelOnly の両 subitem から送る action も検査する。
  integration 試験と、文字入力中でもtoolbarが使える試験も control 自身のクリックへ変更した。
  group の action を直接送るだけの検査ではない。

### correction 1 で実行したもの

隔離先は `build/P10S35Correction1Verification/layout/{KaitoFinder,GyoshukuKit,KaitoKit}`。
三つの基底commitを改めて `git archive` し、canonical の KF 製品・試験・Tools を反映した。
live sibling はビルドしていない。macOS 27.2 / Swift 6.4、target は全て `arm64-apple-macos26.0`。

実行コマンド:

```sh
python3 build/P10S35Correction1Verification/build.py --prepare --sync KaitoKit GyoshukuKit app test
python3 build/P10S35Correction1Verification/run-tests.py ArchiveFolderNavigationTests ArchiveDisplayTests/testToolbarItemsExposeLabelsActionsAndCustomization ArchiveDisplayTests/testToolbarWithoutSessionKeepsOnlySearchEnabled ArchiveDisplayTests/testLockedPlaceholderRestoresListToolbarAndStatusAfterUnlock ArchiveEntryControlsTests/testToolbarValidationTracksSelectionReadabilityAndArchiveCapabilities ApplicationCommandIntegrationTests/testGoMenuCommandsAndToolbarNavigateTheActiveArchive
xcrun swift -module-cache-path build/P10S35Correction1Verification/ModuleCache build/P10S35Correction1Verification/segment-probe.swift
python3 build/P10S35Correction1Verification/build.py --sync test
python3 build/P10S35Correction1Verification/run-tests.py ArchiveFolderNavigationTests ApplicationCommandIntegrationTests/testGoMenuCommandsAndToolbarNavigateTheActiveArchive
git diff --check
```

直接 `swiftc` で KK207 / GK62 / 製品104 / 試験150 Swift files のコンパイル・リンクが全て成功。
試験だけの再ビルドも成功。製品のcompiler診断はなく、兄弟・試験のwarningは既存箇所のみ。
`xcodebuild` / `swift test` は起動していない。
[build-runs.json](../../build/P10S35Correction1Verification/build-runs.json) と各 `*-command.json` / `*-build.log` に
展開済みの全コンパイル引数と結果を保存した。

最初の移動クラス実行は17成功・2失敗・3skip。
単に `selectedSegment` を代入して `sendAction` した2試験で移動しなかった。
[小さなAppKit probe](../../build/P10S35Correction1Verification/segment-probe.swift) と
[ログ](../../build/P10S35Correction1Verification/segment-probe.log) で、momentary control の getter はクリック外では `-1`、
`performClick` の action 中には代入した 0 / 1 が渡ることを確認した。
製品のtracking modeを変えず、試験を `performClick` に直して再実行した。

| 対象（最終結果） | 結果 |
|---|---|
| ArchiveFolderNavigationTests 全22件 | 19成功・3skip（pasteboard service、通常hostのfailure sheet、opt-in規模計測） |
| ArchiveDisplayTests/testToolbarItemsExposeLabelsActionsAndCustomization | 成功 |
| ArchiveDisplayTests/testToolbarWithoutSessionKeepsOnlySearchEnabled | 成功 |
| ArchiveDisplayTests/testLockedPlaceholderRestoresListToolbarAndStatusAfterUnlock | 成功 |
| ArchiveEntryControlsTests/testToolbarValidationTracksSelectionReadabilityAndArchiveCapabilities | 成功 |
| ApplicationCommandIntegrationTests/testGoMenuCommandsAndToolbarNavigateTheActiveArchive | compiled nib の無い直接xctest hostのためskip（2起動とも） |

最終対象は **23成功・4skip・失敗0**。途中も含めた全8起動は40成功・2失敗・8skip。
全起動の [一覧](data/2026-09-26/p10-navigation-correction1-test-runs.tsv) と
[command・環境・case・log](../../build/P10S35Correction1Verification/test-results.json) を保存した。
全8ログに `does not support selectionMode` は0件。
固定archiveの全KK1,513 / GK295ファイル、およびKFのコンパイル入力とcanonicalの一致、
`git diff --check` を確認した。
[検査結果](data/2026-09-26/p10-navigation-correction1-checks.json)。

`LayoutOverflowTests/testLockedPlaceholderInEveryLanguage`、ApplicationCommandIntegrationTests全体、
通常host全件、実マウス・キー入力、`Tools/verify_ui_integration.py` はこの修正では実行していない。
通常hostで二つの指摘クラスと全件をオーケストレータが再検証する。
公開済みrelease notes、設定キー、文言、兄弟の製品ソースは変更していない。
未コミット、S36 / P10-b は未着手。

## Release note 用の文

「フォルダのダブルクリック、⌘↓、⌘Oで、そのフォルダへ移動できるようになりました。
戻る・進む、内包フォルダへの移動とパスバーにも対応しました。
設定の『フォルダを開くとき』で、従来の『その場で展開』に戻せます。」

公開済みの `Documentation/releases/` は編集していない。

## オーケストレータの検証（S35、通常の Xcode test host、2026-09-26）

隔離の三つ組（KaitoKit 823ad46・GyoshukuKit 52655cb は `git archive`、KaitoFinder は作業ツリー）。

| 実行 | 結果 |
|---|---|
| 最初の build-for-testing と全件（画面ロック中） | build 成功。全件 1,625 件で、既知の環境依存の GUI の失敗のほかに新しい失敗 2 件。画面ロックを外して単独でも再現: `LayoutOverflowTests.testLockedPlaceholderInEveryLanguage`（ロック中の window で移動のツールバーの group が有効のまま）と `ApplicationCommandIntegrationTests.testGoMenuCommandsAndToolbarNavigateTheActiveArchive`（「開く」が無効）。加えて、戻る・進むの `NSSegmentedControl` の target・action が nil で、実行時に AppKit が「NSToolbarItemGroup … does not support selectionMode」と出していた（実際のクリックで移動しない恐れ。試験は `sendAction` を直接呼んでいた） |
| correction 1 の後の build-for-testing | 成功 |
| 関係する 11 クラス（ArchiveFolderNavigation・ArchivePreferences・ArchivePreferencesUI・AutosaveIsolation・LayoutOverflow・WordingAcceptance・ApplicationCommandIntegration・ArchiveDisplay・ArchiveDropIntegration・AsyncSearchFilter・M6bSearch） | 167 件、skip 1、失敗 2（予期しないもの 1）。予期しない 1 件は下の GUI の試験 |
| 全件（画面ロック無し） | 1,627 件、skip 32、失敗 3（予期しないもの 1）。予期しない 1 件は `ApplicationCommandIntegrationTests.testGoMenuCommandsAndToolbarNavigateTheActiveArchive` で、22 行目の `NSApp.isActive && NSApp.keyWindow === window` の待ちが時間切れになる（利用者が別のアプリを使っていて、試験の host が前面になれない）。ほかは既知の `ArchivePreviewSidebarTests.testMenuToolbarAndKeyboardToggleTheActiveArchive` など |

`testGoMenuCommandsAndToolbarNavigateTheActiveArchive` は既知のネイティブのドラッグの試験と同じく、Mac が空いていて host が前面になれるときにしか通らない。
`Tools/verify_ui_integration.py` の「commands」の組（ApplicationCommandIntegrationTests を含む）に入っているので、最後の GUI の確認で利用者に流してもらう。
AC-a5（実のキー入力、`python3 Tools/verify_finder_interactions.py --focused`）も同じく利用者の実行待ち。AC-a7（50 万件の移動の main の時間）は下に追記する。

## S36 / P10-b: 表示オプション

2026-09-26。S35 の確定済み `4d4be0b2738766fcf0d59440567225406041bf35`、clean な canonical tree から着手。
P10-b AC-b1〜b10 の製品・試験を実装した。**未コミット。通常hostの全件と実入力のGUI受入は未実施**。
指定された型・関数は名前で確認でき、欠落はなかった。
`Documentation/pending/2026-09-24-large-archive-edit-plan.md` と公開済みrelease notesは変更していない。

### 実装と受入項目

- **b1 / b5**: AppDelegate が一つの `ArchiveViewOptionsController` を遅延生成。
  ⌘J で表示・非表示を切り替え、メニューの題も切り替わる。
  NSPanel は floating / hidesOnDeactivate、key にはなれるが main にはならない。
  main の変更・辞退・closeを監視し、weakなアーカイブ対象を更新する。
  対象なしでは並べ順・順序・列を無効にし、アプリ全体の設定は使える。
  AppDelegate の列の操作・メニュー生成・validationも mainWindow を使う。
  ロック中は新しい⌘Jメニューを無効にし、表示中のパネルも対象ウインドウの操作を無効にする。
- **b2**: 並べ順と昇順・降順、名前以外の列を操作できる。隠れた列で並べると列を表示する。
  既存の `sortDescriptorsDidChange` を通し、不正な改名で並べ順が戻ったときはパネルも戻す。
  `toggleColumn` とソートの完了・拒否を `viewOptionsDidChange` で通知し、ヘッダ操作にも追随する。
  列のautosave形式・keyは変更しない。
- **b3**: フォルダを先頭・隠しファイル・大きさは注入されたstoreを更新し、開いている全ウインドウへ同期反映する。
  checkboxは `performClick`、popupは選択後にそのcontrolの `sendAction` を通して試験した。
- **b4**: 小16pt / 大32pt、文字10…16pt（既定13）。不正な保存値は既定へ戻す。
  既定は `.default`、それ以外は `.custom` と仕様の高さの式を使う。
  `ArchiveEntryCellView` が適用済み世代を持ち、再利用時にfontとアイコンのconstraintを更新する。
  サイズ変更は選択・展開・先頭行を復元し、サイズだけの変更では `sortedChildren` を消さない。
  サムネイルの組立を共有し、アイコンサイズ変更時に旧providerをcancelして作り直す。
  文字サイズだけならproviderを保つ。ドラッグ画像にも現在のfont / iconSizeを渡す。
  P8のrequested/appliedの区別と、S35のcollapse後の `displayedRoot` 代入は維持した。
- **b6**: `ArchiveListIconSize` / `ArchiveListTextSize` / `NSWindow Frame ArchiveViewOptions` を
  `TestProcessSetup.autosaveKeys` と `AutosaveIsolationTests` の両方に追加。
- **b7 / b8 / AC-W**: 指定の12キーだけを追加し、26言語すべてtranslated（312値）。
  小・大に「アイコンのサイズ」のcommentを付け、French colonの前はNBSP。
  既存434キーの値・状態は不変。設定画面とパネルで `ArchiveFormRow` を共有し、controlのaccessibility labelも同じ規則にした。
  LayoutOverflowTestsに26言語・全popup項目の検査、WordingAcceptanceTestsに文言と⌘Jメニューの検査を追加。
- **b9 / b10**: 試験・GUI runnerへの登録まで実装。通常hostでの全件成功、実クリック・実Tab・目視での受入はオーケストレータ待ち。

`ArchiveViewOptionsTests` の7件は注入したmain-window取得関数を使い、前面化なしでcontrolの動作を検証する。
実際の `NSApp.isActive` / key / main を使う試験は
`ApplicationCommandIntegrationTests.testViewOptionsCommandJTracksMainArchiveWhilePanelIsKey` と
`ArchiveColumnsTests.testViewSubmenuTracksMainWindowWhilePanelIsKeyAndSharesHeaderActions`。
後者のクラスとArchiveViewOptionsTestsも `Tools/verify_ui_integration.py` の commands に追加した。
これらの前面化試験は**ロック解除済みで、利用者が別アプリを操作していないMac**で実行する。

### 隔離ビルド

`build/P10S36Verification/layout/{KaitoFinder,GyoshukuKit,KaitoKit}` に `git archive` で展開した。
KFの基底は上記S35、GK `52655cbd76f73f97f4715d06baed1478d6b30a47`、
KK `823ad460faab055b6b7051da10583480785e8f68`。KFの製品・試験・Toolsのみcanonicalから同期した。
全KK1,513 / GK295ファイルがarchiveと一致。live siblingとGyoshukuKit-p14はビルドしていない。
S35との比較は同じ固定依存moduleを使い、KFのS35 archiveを `baseline/layout/KaitoFinder` へ展開して製品・試験を新規ビルドした。

macOS 27.2 (26B5091g)、Swift 6.4。全コンパイルは `arm64-apple-macos26.0` target。
直接swiftcでKK207 / GK62 / KF107 / 試験151 Swift filesをコンパイル・リンクした。
macOS26実機での実行ではなく、`xcodebuild` / `swift test` も起動していない。

実行したbuild.pyの呼出しは順に次の5回で、全て成功した。

```sh
python3 build/P10S36Verification/build.py --prepare KaitoKit GyoshukuKit
python3 build/P10S36Verification/build.py --sync app
python3 build/P10S36Verification/build.py --sync app test
python3 build/P10S36Verification/build.py --sync app test
python3 build/P10S36Verification/build.py --sync app
```

このほか `baseline-build.py` のS35製品・試験の2コンパイル、非DEBUGの `swiftc -typecheck` も成功。
製品のcompiler診断はなく、試験のwarningは既存のArchiveDocumentControllerTests・ArchiveEditTests・ArchiveImportSafetyTestsのみ。
[build-runs.json](../../build/P10S36Verification/build-runs.json)、各 `*-command.json` / `*-build.log`、
[非DEBUG引数](../../build/P10S36Verification/release-typecheck-command.json) に全引数を保存した。

### XCTestの実行結果

主試験は `run-tests.py <class[/method]>…` から直接 `xctest -XCTest KaitoFinderTests.<selector> <bundle>` で起動した。
[全61起動の一覧](data/2026-09-26/p10-view-options-s36-test-runs.tsv) と
[command・環境・case・log](../../build/P10S36Verification/test-results.json) に途中・反復・中断を含めて保存した。
全61起動の完了caseは **169成功・4失敗・11skip**。別にArchiveSortingTestsの1起動がSIGTRAP（exit -5）で途中終了した。
同じcaseの最新結果で数えると **121成功・4失敗・8skip**。

| 対象 | 最新結果と範囲 |
|---|---|
| ArchiveViewOptionsTests | 新規7件すべて成功（最終製品でも再実行） |
| ArchivePreferencesTests / AutosaveIsolationTests / ArchiveDragImageTests | 8 / 2 / 3件成功 |
| ArchiveColumnsTests | 前面化する1件を除く5件成功 |
| ArchiveSortingTests | メニューを使う1件を除いて7成功・1skip（LaunchServicesのpackage種別判定） |
| ArchiveThumbnailTests | 14成功・2失敗。下記のS35比較でも同じ2件が失敗 |
| ArchiveHiddenFilesTests | 7成功・1失敗（直接hostにRecentDocumentsMenu.nibがない） |
| ArchiveFolderNavigationTests | 19成功・3skip（pasteboard、通常hostのfailure sheet、opt-in規模計測） |
| AsyncSearchFilterTests | 18成功・3skip（通常hostのシート・password・Quick Look） |
| WordingAcceptanceTests | 26言語style・catalog全体の書式/状態・ellipsisの計28 selector成功 |
| ArchivePreferencesUITests | testSettingsControlsPersistAndRefreshWithoutReopening成功。testToolbarSwitchesPanesWithoutMovingControlsOffScreenはNSScreenがnilで失敗 |
| ArchiveDisplayTests | testToolbarWithoutSessionKeepsOnlySearchEnabled / testLockedPlaceholderRestoresListToolbarAndStatusAfterUnlockの2件成功 |
| 新規ApplicationCommandIntegrationTestsの⌘J試験 | compiled nibがない直接hostのためskip |

ArchiveSortingTestsの中断は `testFoldersPreferencePersistsUpdatesAllWindowsAndPreservesSelectionAndExpansion` の
`preserveApplicationMenus()` で `NSApp` がnilだったため。その他のselectorは個別に実行した。
既存のGUI試験を環境に合わせて弱める変更はしていない。

サムネイルの失敗は次の2件で、Quick Look生成の5秒待ちが完了しない。
ログに `sandbox_extension_issue_file ... Operation not permitted` がある。
S35を固定archiveから作り直して各1回実行し、**2件とも同じタイムアウト・画像nilを再現した**。
[比較の2起動](data/2026-09-26/p10-view-options-s35_baseline-test-runs.tsv)、
[S35のcommand・環境・log](../../build/P10S36Verification/baseline/test-results.json)。

- ArchiveThumbnailTests/testDisplayReplacesAndCancelsThePreviousThumbnailProvider
- ArchiveThumbnailTests/testPNGThumbnailReplacesNameIconWithoutPasswordProgressOrTemporaryCopies

### 26言語の描画と既定表示の比較

`xcrun xcstringstool compile KaitoFinder/Resources/Localizable.xcstrings --output-directory build/P10S36Verification/CompiledStrings --serialization-format binary`
を1回実行、成功。コンパイルした `.strings` の追加312値をcatalogと照合した。
通常アプリbundleがない直接hostでも実際の翻訳を使えるよう、隔離build内に補助XCTest bundleを作った。
製品のcontrollerへ上記の各言語bundleを注入し、リポジトリの **UISnapshot.swiftそのもの**で描画・overflow検査する。
通常hostのLayoutOverflowTestsの実行を代替したという扱いにはしない。

補助bundleのコンパイルは `build-probes.py` をS36で2回、`build-probes.py --baseline` をS35で1回。
実行は `run-probes.py` をS36で3回、`run-probes.py --baseline` をS35で1回。
初回はラベルのAppKit alignment rectが左へ2pt出ていることを検出した。
既存設定画面と同じgridの余白を追加し、2回目と最終製品の3回目は
**26言語×全22 popup選択（計572選択）と各言語の初期表示が全てoverflowなし**で成功した。
補助XCTest全4起動は6成功・1失敗（初回のpadding修正前）。
[補助試験の全結果](data/2026-09-26/p10-view-options-probes.json)。

`AppearanceProbe` はS35とS36へ同じ表示・同じAqua外観を設定して描画した。
最終比較は **2080×1200画素が全て一致**、寸法も一致した。
rowHeight 24pt、rowSizeStyle `.default`、font `.SFNS-Regular` 13pt、アイコン16×16pt、
ラベルのframe、既定ドラッグ画像のicon / labelのframeが同じ。
最初のPython/Pillowによる画素比較はPillow未導入で起動できなかったため、
`compare-defaults.swift` からNSBitmapImageRepのbitmapを比較した（2回とも一致）。

| S35の既定 | S36の既定 |
|---|---|
| ![S35の既定表示](data/2026-09-26/p10-view-options-default-s35.png) | ![S36の既定表示](data/2026-09-26/p10-view-options-default-s36.png) |

パネルのオフスクリーン描画（GUI受入の実画面キャプチャではない）:

| 日本語 | フランス語 | ヒンディー語 |
|---|---|---|
| ![日本語](data/2026-09-26/p10-view-options-ja.png) | ![フランス語](data/2026-09-26/p10-view-options-fr.png) | ![ヒンディー語](data/2026-09-26/p10-view-options-hi.png) |

全26画像と補助source・build引数・logは `build/P10S36Verification/` 以下に保存した。
最終主試験・補助試験のlogに、controlの非対応API警告やAuto Layout制約競合はなかった。
新しいsendabilityの回避指定もなく、`git diff --check` は成功。
コンパイル入力とcanonical、固定archiveとの照合結果・文言・画素比較の値は
[検査結果](data/2026-09-26/p10-view-options-checks.json) にまとめた。

### 未実行と引継ぎ

通常Xcode test hostでのbuild-for-testing・全件、正式なLayoutOverflowTestsの26言語、
WordingAcceptanceTestsのbuilt app bundle照合、前面化が必要な⌘J/main-window試験、
`Tools/verify_ui_integration.py`、実マウス・キー・Tab入力、目視・実画面キャプチャは未実行。
HFS+ / FAT32 / exFAT のvolume試験も実行していない（S36は書庫I/Oを変更しない）。

オーケストレータは同じ固定三つ組の隔離layoutで仕様の関連クラスと全件を実行する。
GUIは、そのlayout内のTools/verify_ui_integration.pyを、ロック解除済みのidle Macで実行する。
パネルをkeyにしたままA/Bのメイン対象を切り替え、⌘J、列メニュー、Tab移動を確認し、AC-b9の実画面画像を本節へ追記する。

Release note用の文（公開済み文書は変更していない）:
「表示メニューの『表示オプションを表示』（⌘J）から、並べ順や列の表示、アイコンと文字の大きさを変更できるようになりました。」

## オーケストレータの検証（S36、通常の Xcode test host、2026-09-26）

隔離の三つ組（KaitoKit 823ad46・GyoshukuKit 52655cb は `git archive`、KaitoFinder は作業ツリー）、画面ロック無し、利用者は別のアプリで作業中。

| 実行 | 結果 |
|---|---|
| build-for-testing | 成功 |
| 関係する 14 クラス（S35 の 11 クラスに ArchiveViewOptions・ArchiveColumns・ArchiveDragImage を加えたもの） | 187 件、skip 2、失敗 4（予期しないもの 2）。予期しない 2 件は、host を前面にする必要のある `testGoMenuCommandsAndToolbarNavigateTheActiveArchive` と `testViewOptionsCommandJTracksMainArchiveWhilePanelIsKey`（どちらも `NSApp.isActive` の待ちが時間切れ） |
| 全件 | 1,639 件、skip 32、失敗 11（予期しないもの 4）。予期しないものは上の 2 件、Quick Look の `ArchiveDocumentOpeningTests.testQuickLookForXZAndLegacyZstandardZIPRows`（host が前面でないとメニューが無効）、ネイティブのドラッグ。どれも `Tools/verify_ui_integration.py` の組に入っている、Mac が空いているときにしか通らない試験 |

最後の GUI の確認で、利用者に `Tools/verify_ui_integration.py`（ApplicationCommandIntegrationTests・ArchiveColumnsTests・ArchiveViewOptionsTests を含む）と
`python3 Tools/verify_finder_interactions.py --focused`（AC-a5）を Mac が空いた状態で流してもらう。

## AC-a7（オーケストレータ、2026-09-27 00:41）

KaitoFinder 786ec4c（S35・S36 を含む）の `-O`・wholemodule の Debug、GyoshukuKit 52655cb・KaitoKit 823ad46、
`TEST_RUNNER_KAITOFINDER_PERFORMANCE_PROBES=1 TEST_RUNNER_KAITOFINDER_PROBE_ENTRIES=500000` で
`ArchiveFolderNavigationTests/testNavigationScaleWhenEnabled` を 1 回（負荷の平均 15.4–16.4）。

| 操作 | main の時間 | 合格条件 |
|---|---:|---:|
| 最上位から 100 件のフォルダへの移動 | 2.39 ms | ≤ 50 ms |
| 戻る | 0.52 ms | ≤ 50 ms |
| ⌘↑ | 0.73 ms | ≤ 50 ms |
