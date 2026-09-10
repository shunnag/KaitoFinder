# インライン改名の実測(2026-09-10)

`NSOutlineView` のセル内でリネームを始める経路で、AppKit の実挙動が
設計の前提を二つ崩した。どちらもテストが赤くなって初めて分かった。

## 1. 自分で立てた編集を自分で取り消していた

最初の実装は `window.makeFirstResponder(field)` の直後に

```swift
if field.currentEditor() == nil { cancelRenaming() }
```

で「編集が始まらなかった場合」を拾おうとしていた。これは**非同期に成立する
条件を同期的に検査**している。ウィンドウが key でないとき、AppKit はこの行の
時点でまだ field editor を入れていない。

```
呼ぶ前:            currentEditor=nil  isRenaming=false
初回 beginRenaming: renameField=nil   currentEditor=あり
firstResponder=Optional(NSTextView)   window.isKey=false
```

`beginRenaming` が戻った時点では field editor は**立っている**。にもかかわらず
`renameField` が nil、つまり `cancelRenaming()` が走っている。自分で始めた
セッションを、まだ確定していない値を見て破棄していた。

ヘッドレステスト固有の話ではない。「その瞬間ウィンドウが key か」で結果が
変わる競合なので、ウィンドウを前面に出しながら改名を始めた場合など実アプリでも
起こりうる。

**表のインライン編集を始める正規の口は `editColumn(_:row:with:select:)`** で、
first responder と field editor の面倒は AppKit が見る。これに替えて、
Escape・Return・focus 喪失でのコミットが通るようになった(14 件中 5 件が解消)。

## 2. `textShouldEndEditing` の拒否は `editColumn` 配下で尊重されない

残る 9 件は検証拒否の経路だった。設計は「終了通知では遅いので、focus 移動
そのものを `control(_:textShouldEndEditing:)` で拒否し、入力と field editor を
残す」というものだったが、実測ではこうなる。

```
beginRenaming: isRenaming=true
commit が呼ばれた
makeFirstResponder(outline)=true   ← false であるべき
```

`NSTableView` が編集セッションを所有するため、delegate が false を返しても
編集は終了する。

失敗した assert と通った assert の対比が症状を正確に示していた。

| | |
|---|---|
| 失敗 | `isRenaming` / `isEditable` / `currentEditor` / `firstResponder` / `toolTip`(nil) / タスクが存在 / シートが表示 |
| 成功 | 書庫の SHA-256 不変 / `generation == 0` / undo slot 空 |

つまり編集が終了して改名が投入され、**モデル層が弾いた**。書庫は無事だが
エラーシートが出る。これは設計書 §5.1 が「設計ではなくフォールバック」と
呼んでいる commit-then-refuse そのものである。

## 結論

`editColumn` を使う以上、「focus 移動を拒否する」形の検証は採れない。
Return は `doCommandBy` の中で完全に自前で扱えるので、そこで検証して
first responder を手放さない。focus 喪失については、拒否できるふりをせず、
編集終了の直後に同じ行へ再入して入力と理由を残す。利用者から見た要件
「無効な文字列と理由を残したまま編集が続く」は再入でも満たせる。
