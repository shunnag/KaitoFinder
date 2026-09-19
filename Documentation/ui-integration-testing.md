# UI の操作経路とレイアウトの回帰テスト

UI の接続・メニュー構築・起動経路・保存パネル・ウインドウ構成を変更するときは、
通常の `xcodebuild test` に加えて次を実行する。

```sh
python3 Tools/verify_ui_integration.py
```

macOS のログイン済み GUI セッションと、通常のビルドと同じ Xcode / ローカル framework checkout が必要。
専用の DerivedData は `build/UIIntegrationDerivedData`、実行ごとのログと `.xctestrun` は
`build/UIIntegrationVerification/<UUID>/` に残る。既存のビルドを使う場合は
`--derived-data build/ReviewDerivedData` などを指定できる。

このコマンドはランダムな専用 bundle ID でテスト用アプリをビルドする。メニュー操作の検証後、
同じ bundle ID を使う新しいプロセスを 4 回起動し、履歴への登録、再起動後の再オープン、消去、
消去後の再起動を検証する。通常アプリの最近使った項目は消去しない。
対象のテストが実行されなかった場合、skip された場合、失敗した場合はコマンドも失敗する。

`native-save` では `press_verification_save.swift` が実際の名前欄を読み書きし、標準「保存」ボタンを押す。
全7形式の切り替え、新規作成と形式変換、元の名前にも書庫拡張子がある入力、
複合拡張子・短縮形・大文字の手入力、手入力後の形式変更を検証する。
確定したURLを照合し、上書きでは目的の名前を含む標準確認が現れたことを確かめてから「置き換え」を押す。
上書きボタンの自動操作は日本語・英語のOS表示に対応する。アプリ内の26言語の描画検証とは別に扱う。
名前欄のgetterや非表示パネルだけでは、XPC側が表示・確定する名前を保証できない。
形式変更では`.tar.gz`などを一まとまりの拡張子として置き換える。手入力後も標準の
`.tar.gz` / `.tar.bz2` / `.tar.xz`を使い、名前の本体にあるドットと元ファイルの拡張子を保つ。
表示中の名前は直接変更できないため、明示された名前の形式変更時は同じ標準パネルを再構成する。
明示された名前には末尾の圧縮型を使って二重補完を防ぎ、`isExtensionHidden`の変更通知で
拡張子なしの再入力を検知して完全な拡張子の補完へ戻す。名前のgetterや確定URLの後処理では代替しない。
全7形式の組み合わせ、切り替え後の再編集、繰り返す切り替え、正確な名前での上書きを検査する。
保存先・タグ・暗号化入力・一覧の開閉状態の保持、通常パネルとシート、再構成中のTask取消し・親終了も確認する。
寸法は標準パネルが要求する最小サイズを尊重し、画面内で上端（シートでは中央）を維持する。
操作対象は今回生成した専用 bundle ID と一致する PID に限定し、アクセシビリティの既存の許可だけを使う。
許可を要求するダイアログは出さず、利用できなければ成功扱いにしない。
通常の全件テストでは外部操作を要する5件を skip し、このドライバーで検証する。
保存ボタンの確認だけを行う場合は `--native-save-only` を指定する。
保存パネルの `ok(_:)` はこの環境の XPC パネルでは未実装の例外になるため、テストから直接呼ばない。

タブとドラッグの検証もこのコマンドに含む。画面ロックを解除し、GUI テストは並列実行しない。

Finder風のクリック操作を変更した場合は、追加で `python3 Tools/verify_finder_interactions.py` を実行する。
`ArchiveFinderInteractionTests` の実入力10件はこのドライバーで実行し、通常の `xcodebuild test` ではスキップする。
ファイル名の選択範囲とキーの判定は通常のテストでも実行する。`--focused` でこの12件だけに絞れる。
専用bundle IDのウインドウにCGEventで実際のクリック・ドラッグ・キー入力を送り、名称変更・確定・Undo・
Escape・背景ウインドウの前面化・設定の即時反映を検証する。入力先のPID、bundle ID、ウインドウ境界を毎回確認する。
検証用ウインドウだけのスクリーンショット、ログ、xcresultは `build/FinderInteractionVerification/<UUID>/` に残る。
NSTableViewのmouseDown/mouseUpを上書きすると新しいmacOSでは標準ジェスチャーが無効になるため、
クリックのテストだけでなく、既存の書庫間・タブ間のドラッグも同じコマンドで確認する。

実行前と各テストプロセスの前後にログイン済み console session とロック状態を確認する。
途中でロックされていれば成功扱いにせず、解除後の再実行が必要と表示する。
ロック解除、システム設定変更、画面収録権限の要求は行わない。
`ArchiveTabTests` は表示後のタブ群、文書の再利用、実ウインドウメニューからの切り替え・分離・結合を検査する。
`SoftwareUpdateTests` と `ArchivePreferencesUITests` は更新設定の保存、メニューと設定画面の同期、
自動確認を無効にした場合の手動確認、26言語の表示、設定タブ切り替え時のレイアウトを検査する。
実 Sparkle による署名付きフィードの検出は[自動更新の検証手順](software-updates.md#ローカルの検証)を参照。
Quick Look は標準 ZIP に加え、XZ・旧 Zstandard とその暗号化 fixture を実メニューから開き、
プレビューパネルの表示、制御するウインドウ、プレビューURLの全バイト、閉じる操作まで照合する。
`ArchiveDropIntegrationTests` はテストアプリ内へマウスイベントを送り、実際のドラッグ開始、
コピー受け入れ判定、`NSFilePromiseReceiver` の背景 callback、文書の追加と undo までを通す。
タブ間のケースは実際のタブ上へマウスを移して静止させ、コードからタブを選択せずに切り替えを待つ。
`ArchiveTabSpringLoadingTests` は Finder と同じ file URL の実ドラッグで、同名の三つのタブ間の切り替え、
短い通過、離脱、Escape での取消し、待機中のタブ終了、分離・結合後の通常クリックを検査する。
他のアプリへ入力は送らず、画面収録権限やアクセシビリティ権限には依存しない。
通常のドロップでは見えない callback のスレッド違反は、provider やモデルだけのテストでは検出できない。

## テストで確かめる範囲

2026-09-17 の履歴メニュー不具合では、URL の登録とメニューのタイトルを確認するテストは通っていたが、
表示用メニューが AppKit の履歴と接続されていなかった。このため、確認を次の三段階に分ける。

1. **宣言**: ローカライズ、ショートカット、Services の selector、リソースの収録を確認する。
2. **接続**: 実際の `NSApp.mainMenu`、システムメニュー、target / responder chain を通す。
   動的メニューは `showMenu` で実際に表示する。`NSMenu.update()` は項目の有効状態を検査する用途で使い、
   動的項目が生成されたことの代用にしない。
   履歴サービスの非同期更新を待つ際は、メニューを開いたまま項目が置き換わることを期待せず、
   同じタイムアウトの範囲で開き直して確認する。
3. **結果**: `performMenuItem` / `sendAction` の後で、文書・ウインドウ・選択・モデル・設定の変化を確認する。
   処理中、選択なし、読み取り専用、キャンセル後の復帰も対象にする。
   `target != nil` や action の名前だけ、ハンドラーへの直接呼び出しだけで完了としない。

実例は `ApplicationCommandIntegrationTests`、`RecentDocumentsMenuTests`、
`RecentDocumentsPersistenceTests`。共通の支援コードは `Support/MenuInteraction.swift` にある。
`AppDelegate.makeMenu()` で別のメニューを作るテストは `preserveApplicationMenus()` を呼び、
アプリに登録されたメニューを後で戻す。ウインドウ・パネル・文書も teardown で閉じる。

保存画面は `ArchivePasswordUITests.testPresentedSavePanelAnimatesEncryptionAndCancelsWithoutSaving` で
実際の `NSSavePanel` を開き、表示直後のサイズ、暗号化のオン・オフ、入力検証、Tab 移動、非対応形式への切り替え、
無効・非表示になった欄からのフォーカス移動、キャンセル完了まで確認する。
On / Off では `CALayer.presentation()` の中間の高さと最終的なパネルの大きさを検査し、
アニメーション途中の逆転、入力値の保持、最後の状態への収束を確認する。モデルのフレームは
描画より先に切り替わるため、表示中のフレームと混ぜてアニメーションを判定しない。
`testSavePanelSheetReversesAnimationAndCancelsDuringExpansion` は文書に接続するシートでも同じ操作を行い、
展開途中のキャンセルが待機処理を終了することを確認する。
`testSavePanelReducedMotionChangesSizeWithoutAnimation` は動きの抑制と、途中から有効にした場合を検査する。
`testSavePanelResizesWithoutSlidingContents` は通常パネル・シートと、保存先の一覧の開閉を組み合わせた
4 条件を検査する。アクセサリ内の位置を実際の保存パネルの表示領域へ変換して比較する。
XPC ホストの最外側の presentation layer だけでは、ホストと画面上のパネルとの時間差を検知できない。
各行の位置と大きさ、アクセサリの原点、パネルの幅が揺れず、高さが中間値を経て単調に変わることを検査する。
行の位置と、標準パネルの上端または浮動シートの中央は 0.01 pt 以内に保つ。
実パネルの表示領域と、アプリが追加した祖先ビューのクリップを合成し、常に表示する行が欠けないことも調べる。
さらに各コントロールの `visibleRect` と bounds の共通部分を検査し、ホスト側の描画範囲による欠けを検知する。
実ウインドウとの座標の合成と、ホスト内で描画できる範囲の両方を確認する。一方だけの成功で完了としない。
初期表示後に 1 秒待って基準位置を取り、切り替え後も 650 ms 計測する。
一覧の状態は別プロセスへ伝わる保存値を一時的に指定し、元の値へ必ず復元する。
一覧付きパネルは検査開始前に画面内で伸縮できる大きさへ合わせる。

`testExpandedSavePanelRebasesAfterNativeResizeAndFitsTheScreen` は標準のリサイズ開始通知と
実ウインドウのサイズ変更の後に、暗号化を再度切り替える。画面いっぱいの状態でもウインドウが
画面内に収まり、コントロールが切れず、Off で縮小できることを確認する。
`testExpandedSaveSheetKeepsItsButtonsOnScreenNearTheBottom` は一覧付きシートを画面下端の8 pt上に置き、
暗号化を2回開閉する。WindowServerの実ウインドウ境界と入力欄の描画範囲を調べ、
保存ボタンまで画面内に収まることを確認する。画面全体の高さだけで伸縮可否を判定すると、この条件を逃す。
これらの実パネルのテストは登録ドメイン内の `NSAutomaticWindowAnimationsEnabled` を一時的に有効にし、戻す。

実際の描画を比較するときは次を使う。実行元に画面収録の許可が必要で、ツール自身は権限を要求・変更しない。
録画ツールも開始前・実テスト直前・終了後にログイン中のconsoleとロック状態を確認し、
ロック中の録画を成功扱いにしない。

```sh
caffeinate -d python3 Tools/verify_save_panel_animation.py
```

専用 bundle ID の検証アプリだけを `ScreenCaptureKit` のウインドウフィルターで記録する。
ディスプレイ上の座標と Retina のピクセル倍率を固定し、含めるウインドウを検証アプリのものに限定する。
対象外のアプリやデスクトップは映さない。伸縮するウインドウに追従して動画の原点が変わる方式は、
サイズ反映と描画のタイミングに差が出るため、最終的な位置の判定には使わない。
通常パネル・シートと一覧の開閉を組み合わせた 4 本の `capture.mov`、表示更新の `frames.json`、
座標と倍率の `capture-info.json`、テストログを `build/SavePanelAnimationVerification/<UUID>/` に保存する。
シートは親ウインドウを含めて記録する。保存先はテストが用意した空の一時ディレクトリにする。
録画には標準の動画出力を使い、アニメーション中の画像エンコードによる負荷を避ける。
フレームの画像化や比較は録画後に行う。Core Graphics のウインドウ情報を主スレッドで
高頻度に取得すると描画待ちが発生するため、動きの検査には使わない。
数フレームだけの文字欠けがあるため、間引いた一覧画像に加え、動画の全フレームで行の位置と表示を比較する。
通常のテスト実行では録画処理は動かず、画面収録の許可も不要。

`ArchiveDisplayTests.testWindowChromeAndFirstRowRemainReadableAtMinimumSizeInBothAppearances` は
標準・最小ウインドウでツールバーと先頭行の重なりを調べ、ライト / ダークの実ビューを描画する。
これらも上記コマンドに含める。全言語の文字切れは通常テストの `LayoutOverflowTests` と
`ArchivePasswordUITests` で検査する。

履歴消去のテストは、専用 bundle ID と実行フェーズを確認してから動く。通常の全件テストでは
このケースだけを skip し、上記コマンドで別途検証する。再起動の検査を単一プロセス内の
`recentDocumentURLs` の確認で置き換えない。

メニューバーからの responder 解決と Quick Look は、アプリが前面である必要がある。
`ArchiveDocumentOpeningTests.testQuickLookForSelectedZIPRowSurvivesForegroundAsyncLoading` が
実メニューから「すべてを選択」「クイックルック」を実行する。前面化できない環境での skip は
成功扱いにせず検証記録に残し、前面での操作は実機確認に残す。前面化とは独立して、ツールバーと
ウインドウ内の実 responder chain による編集・取り消し・やり直し・テキスト選択を自動検証する。

AppKit の自動 validation と responder 解決の仕様は
[Apple のメニュー有効化の説明](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/EnablingMenuItems.html)を参照。

同名項目の比較は `ArchiveConflictUITests` を上記の結合検査に含める。実際のドロップから
置き換え・スキップ・残りへの適用をクリックし、元データ、結果、undo、キャンセル、文書終了まで確認する。
`ArchiveDropIntegrationTests` は100ファイルとフォルダの別タブへの置き換え、別フォルダから選んだ同名の
file promise を追加し、AppKit による改名後も双方の内容を保持して確認に進むことを検査する。
`ArchiveImportConflictTests` は1,000件、全書き込み形式、暗号化、正準等価パス、変更された入力・世代を検証する。

比較の属性欄は26言語とライト／ダークで描画し、文字・ビューのはみ出しを調べる。
Quick Look の XPC 描画は `cacheDisplay` に含まれないため、表示の目視検証ではテストアプリの比較ウインドウだけを
ScreenCaptureKit で撮影する。`KAITOFINDER_CONFLICT_CAPTURE_DIRECTORY` を指定した場合だけ、比較テストは
そのフォルダへ window ID と bundle ID の `request.json` を出し、撮影側の `complete` を待つ。
通常のテスト実行には画面収録権限は不要。2026-09-17 の検証は `Documentation/verification/2026-09-17-import-conflicts.md` に記録する。
