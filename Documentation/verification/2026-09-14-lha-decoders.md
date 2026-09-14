# LHA の復号器三種の実挙動(2026-09-14)

GyoshukuKit の LHA writer を検証するにあたり、この Mac で使える三つの
復号器が何を検証し、何を検証しないかを実測した。writer の受入基準は
この表に基づいて各復号器へ振り分けている。

## 前提: 参照エンコーダが無い

Homebrew の `lha` は Lhasa 0.6.0 で、**展開専用**(`c` コマンドが無い)。
参照書庫を作れないため、tar で bsdtar と行ったようなバイト単位の比較は
できない。正しさの根拠は「三つの独立した復号器が全て受理する」ことに置く。

## 実測の結果

writer で `日本語.txt`(-lh0-、9 byte)と `ascii.txt`(-lh5-、5000 byte)を
入れた書庫を作り、三者に読ませた。

| | Lhasa 0.6.0 | 7zz 26.03 | KaitoKit |
|---|---|---|---|
| ASCII 名の一覧・展開 | ○ | ○ | ○ |
| **CP932 名の一覧** | `???{??.txt` | `{.txt` | **`日本語.txt`** |
| **CP932 名の展開** | **Failure** | (未確認) | ○ |
| データ CRC の検証 | ○ | ○ | ○ |
| **ヘッダ CRC の検証** | (要確認) | **無視**(`Everything is Ok`) | **検証**(`LHA header CRC mismatch`) |

書庫内のバイト列は正しい CP932(`93 fa 96 7b 8c ea` が offset 32)である
ことを別途確認している。名前が読めないのは書庫の問題ではなく復号器の
問題である。

## 解釈

Lhasa と 7zz は西洋のツールで、macOS では CP932 を知らない(7zz は
Windows なら OEM コードページで読むが、macOS にはそれが無い)。
KaitoKit はこの生態系 —— 日本の Windows ツール製の書庫 —— 向けに作られた
読み手で、Shift_JIS を既定にしている。だから読める。

これは writer が CP932 を書くという判断の妥当性を裏付ける。相互運用の
相手は日本の Windows ツールであり、macOS の西洋ツールではない。

## 受入基準の振り分け

- **日本語名**: KaitoKit の `entries[i].name` と、書庫内の生バイト列で検証。
  Lhasa / 7zz の化けた出力は assert しない。
- **ヘッダ CRC**: KaitoKit が `KaitoError.malformed` を投げることで検証。
  加えて復号器に依存せず、ヘッダの CRC 2 byte をゼロにして CRC-16/ARC を
  再計算し、書かれた値と一致することを確認する。
- **ASCII 名の内容・構造・データ CRC**: 三者で検証。

## 補足: CP932 の表現範囲

Swift の `String.Encoding.shiftJIS` は NEC / IBM 拡張を含む(実質 Windows-31J):

```
日本語.txt → 93 fa 96 7b 8c ea 2e 74 78 74
①.txt     → 87 40 ...   (NEC 特殊文字)
髙.txt     → ee e0 ...   (IBM 拡張)
～.txt     → 81 60 ...
```

絵文字とハングルは表現不可で、writer は拒否する。日本の Windows ツール製の書庫に
出てくる機種依存文字は通る。
