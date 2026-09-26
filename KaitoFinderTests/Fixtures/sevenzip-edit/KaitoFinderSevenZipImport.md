# KaitoFinder P5-A fixture import

The original 33 `.7z` archives and two expected-value JSON files were copied from
GyoshukuKit commit `52655cbd76f73f97f4715d06baed1478d6b30a47`,
`Tests/Fixtures/sevenzip-edit/`.

On 2026-09-27, `bcj.7z`, `bcj2.7z`, and `ppmd.7z` were replaced byte-for-byte from
KaitoKit's `Tests/Fixtures/sevenzip-edit/`. KaitoKit's `generate-filters.py` in that
directory generates their project-authored SHAKE-256 seeded bytes, synthetic x86
E8/E9 rel32 streams, and text under the MIT license, using 7-Zip 26.03. Entry names
`cat`, `ls`, and `t.txt` are retained for compatibility. The other 30 archives are
unchanged. Both expected-value JSON files match KaitoKit's regenerated metadata;
only these three structural records and the provenance metadata changed, and all
three AES arrays remain empty. Archive hashes are in `expected-structures.json`.

The upstream `README.md` and `NOTICE-lines.txt` are adapted as
`SevenZipEditFixtures.md` and `SevenZipEditNOTICE.txt`, with the current generator
provenance and the historical Step 0 record. Their distinct filenames avoid
collisions in Xcode's synchronized test-resource group. The generator and
`public-values.json` remain in KaitoKit. Tests read the local fixtures relative to
their source files and do not require `7zz`; fixture-derived values remain in
metadata files.

The approved `startpos.7z` exception and remaining upstream limits are recorded in
`Documentation/verification/2026-09-26-p5-7z-update.md`. This import does not add an oracle
exception or claim that `empty_7zz.7z` is readable by KaitoKit.
