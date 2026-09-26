# LHA update fixtures

Step 0-P4 の `SP/p4/fixtures` から凍結した base64（最初の14件）。テスト内で復号して書き出す。
`tl-S3b` は level 0 の lh6 と level 1/2 の混在。`lhark-lh7` の payload は復号できないため、fallback の試験ではその member を削除する。
`colon`・`unrepresentable`・`symlink` は名前・Unix mode の拡張だけを持つ最小の level 2 を作った門番用の fixture。

SHA-256 は復号した書庫の値。

| File | SHA-256 |
|---|---|
| tl-S3b.lzh.b64 | b62042e0f2b5c4ce9f7ffadfa196f28c9c8cfe6fbd83d572d528901de69a325e |
| sfx.lzh.b64 | 1ec8b11396cc7d0a0d191f393414af136406fb0066275e3b2504d4a2f7e9ed51 |
| names-euc-jp.lzh.b64 | e169c1209427923be9c4d6607cf8374de69b47ff68a6114cbda1a22a8350130b |
| names-utf8-undeclared.lzh.b64 | 74a2671740935bf2bde8d685230bfcdf01cccf39b04817010bb868e3c2cdcd87 |
| names-utf8-declared.lzh.b64 | 678460a7950f5e3364404433a7f9cd2e143c1f300c41cbfe5fcd5143c0e9e38d |
| tl-S5.lzh.b64 | 803ba865eb01b1cffb00b4dab382d7ad39359fe6c1f51db963dd0294d5b8a6d3 |
| tl-S11.lzh.b64 | 7a366da3aa99ca9812d21e074a216c9e6f0e93357f6f38ac15470155d8969209 |
| level3.lzh.b64 | 7b3444a51521e36e0f9c848bcecdae9f0ea6e445a3e7206d0133d4c5561f8a67 |
| anonymous-middle.lzh.b64 | 7f5dda07a9fa551cc35edda4348eb312b46cc339049eed6b9c01ea677e0f86b4 |
| empty-name-directory-tail.lzh.b64 | b8d3ada65699f2f7f9ddf85dcbce636b49445144f1f98c52a1ade6f7f432543e |
| data-directories.lzh.b64 | 5a3e6fadf0eb37479b946bcad3e6e7e19ded3641ca2a33330b8db1191f5ba033 |
| lhark-lh7.lzh.b64 | 03966a7b33b8188627a4463f757d9daa6d205650650fc966ea87058c2f609611 |
| names-cp932-mixed.lzh.b64 | 6104af5d2b00aed01f60e778469ef9d286856e80035582c5d17e551465abbadf |
| names-ascii.lzh.b64 | b46038d8ba54989cbdf1c7cca2129616714cde4bac045fd2892690cd892f2869 |
| colon.lzh.b64 | 0e7269ad9450432b934a5ba322f94dbe2bc511a302dab04927a0e30ab4250d26 |
| unrepresentable.lzh.b64 | 48851cb5ac506b06301959d9cac2a7ae32ecd294618485dfd26d18410e4daad3 |
| symlink.lzh.b64 | 7d12acdb35208eb5ba9015117d65759a49366bea8880a9d90308f415ea4876e5 |
