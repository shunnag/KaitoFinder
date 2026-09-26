# S35 / P10-a: 現在のフォルダへの移動

2026-09-26。S35（AC-a1〜a9）の実装。**未コミット。S36 / P10-b は未着手**。
初回の実装・検証記録を残し、[S35 correction 1](#s35-correction-1) に追加修正と検証を追記した。
通常のアプリ test host の修正後の再検証、実キー入力、UI、50万件の受入計測はオーケストレータ待ち。

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
