# 7z Swap2 / Swap4 のアプリ統合（2026-09-18）

KaitoKitに追加したSwap2/Swap4を`EntryReadCapability`へ接続し、プレビュー・外部アプリ用の
ファイル生成と書庫編集を有効にした。圧縮方式名の許可だけでなく、独立生成の実書庫を使用する。

- plain／AESヘッダー暗号化×2方式の4書庫。7zz 26.03でプロジェクト所有の入力を圧縮し、
  同ツールで全byteを展開・照合した。由来・コマンド・SHAは
  `KaitoKit/Tests/Fixtures/sevenzip-swap/manifest.json`に記録している。
- `CompressionCapabilityTests`: **12件、失敗0、skip0**（15.747秒）。
  262,403 byteと1,027 byteのsolid memberを、プレビューと同じ経路で取り出してSHAを照合。
  各書庫へ2ファイルを一度に追加し、元の内容と暗号化を維持すること、
  1回のundoで元書庫全byteへ戻ること、redo後に7zzの検査を通ることを確認した。
- KaitoKit全件: **1,176件、失敗0、既知skip43**。互換層も **24件、失敗0**。
  Swap個別8テストは、極小read、未完単位、solid逆順、AES、分割巻、unlink後のreopen、
  破損・上限・coder graphの不整合を含む。
- GyoshukuKit全件: **202件、失敗0、skip0**。4 GiB超の圧縮tarも含む。
- ASan/UBSan: 正常4書庫の全entry SHAが一致。160変異入力でcrash・hang・sanitizer所見はいずれも0。

RISC-Vは追加していない。公開資料の不足と、調査中の検索結果に他実装の断片が表示された経緯は
KaitoKitの`Documentation/verification/2026-09-18-sevenzip-swap.md`と`Documentation/design.md`に記録した。
その内容はSwap実装には使用していない。

実行環境はmacOS 27.2 / Xcode 27.0 / Apple Silicon。macOS 26・Intelは未実行。
ログは`/private/tmp/kaitofinder-sevenzip-swap-{finder,kaitokit-full,gyoshuku-full,sanitizer,sanitizer-valid}.log`。
KaitoFinderの全UIは、圧縮tarの保存名の修正とともに引き続き検証する。
