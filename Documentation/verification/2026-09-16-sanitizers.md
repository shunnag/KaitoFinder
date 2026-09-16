# Thread Sanitizer / Address Sanitizer での全件実行 — 2026-09-16

## Thread Sanitizer

`xcodebuild test -enableThreadSanitizer YES`(別の DerivedData、KaitoKit / GyoshukuKit も TSan で
再ビルド)。661 件・skip 1・失敗 1、**ThreadSanitizer の報告は 0 件**。失敗は
`DragCopyOutTests.testRegistrySweepsUncalledDragsAndPendingProviders` の `XCTAssertNil(lastDelegate)`
(weak 参照が sweep 直後に nil になることを期待する解放タイミングの assert)で、TSan 下では
オブジェクトの解放が遅れるための差。競合の報告は伴わない。通常実行では通る。
`ScenarioScaleTests` の 5,000 フォルダのテスト(上限 5 秒)は TSan 下でも 6.8 秒の実行時間のうち
解決自体は上限内で通過した。

## Address Sanitizer

`xcodebuild test -enableAddressSanitizer YES`(別の DerivedData)。672 件・skip 1・失敗 0、
**AddressSanitizer の報告は 0 件**(`ExtractionDestination` の unsafe buffer、KaitoKit の decoder、
GyoshukuKit の writer を含む全経路)。

## 位置づけ

Swift 6 の strict concurrency は主にコンパイル時の保証で、`nonisolated(unsafe)`・`Mutex`・Darwin
呼び出し・unsafe pointer の誤りは実行時にしか出ない。本日のコミット(descriptor キャッシュ、
台帳、promise の待ち合わせ、終了時の後始末)を含む状態で、両 sanitizer が沈黙したことを記録する。
`git status` は両実行の前後で変化なし。
