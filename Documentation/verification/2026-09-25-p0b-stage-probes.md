# P0b 編集の段別計測

対象: KaitoFinder 1f1ba35 + 本変更、GyoshukuKit c0df9fb、KaitoKit b518014。
計測だけを追加し、編集・検証・公開の処理順は変えていない。P1–P5 の比較には同じビルド設定・fixture サイズを使う。

## 実行

PerformanceProbeTests の三つのテストは KAITOFINDER_PERFORMANCE_PROBES=1 のときだけ動く。
Release ではスキップする。通常のテストでは fixture を作らない。

| 変数 | 既定値 | 意味 |
|---|---|---|
| KAITOFINDER_PROBE_ENTRIES | 100000 | 小項目 fixture のファイル数（2 以上） |
| KAITOFINDER_PROBE_FORMATS | zip | zip,tar,tar.gz,tar.bz2,tar.xz,7z,lha から選ぶ。カンマ・空白区切り |
| KAITOFINDER_PROBE_PAYLOAD_MIB | 256 | 本文 fixture の大きなファイル **64 個の合計 MiB**（1 以上） |
| KAITOFINDER_PROBE_ASSERT | 未設定 | 1 なら従来の予約時間・MainActor 待ちの上限も検査 |

GyoshukuKit で各形式に二つの fixture を作り、テストクラス終了まで一時ディレクトリにキャッシュする。
entries は dNNN/sN/fNNNNNNN.txt の 1 byte ファイル。
payload は先頭に大きなファイル 64 個（既定では各 4 MiB）、後ろに同じ配置の小ファイル 1,000 個。
大きなファイルの最初の 48 個は /usr/share/dict/words から単語を標本抽出したテキスト、残る 16 個は疑似乱数のバイト列。
辞書がない・空・読めない場合は組み込みの単語リストを使う。AES-128-CTR の出力を固定 seed の block PRNG として使い、
64 KiB ずつ生成する。ファイルごとに seed（20260925 + index）を変え、テキストは単語単位でコピーする。
各ファイルの長さ・パスと 64 個の合計 MiB は従来どおり。cache key の既存の項目には生成規則の版 v2 を加えた。
開くテストも entries を共有するため、以前の開く専用の dNNNNN/fNNNNNNN.txt 配置とは異なる。
作成と編集にはアプリの既定の圧縮設定を明示的に使い、利用者の保存済み設定に依存しない。

各即時編集と各保存シナリオは原本 fixture の新しいコピーから始める。文書を開く・初回準備・項目を選ぶ時間は編集の
total に含めない。編集は実際の document API と undo を通り、再表示までを含む。
即時編集は先頭削除、末尾削除、同じ byte 長の改名、長さの変わる改名、フォルダ改名、新規フォルダ、追加、衝突時の置換。
本文 fixture の先頭削除・ファイル改名・置換は大きな本文を対象にし、末尾削除は小項目を対象にする。
フォルダ改名は d000 または payload の部分木。置換では同名の 1 byte ファイルを追加し、resolver が replace を返す。

保存時モードは従来と同じ改名→1 件削除→新規フォルダ→フォルダ削除→追加の五操作、および改名だけの二シナリオ。
予約ごとの total と、保存だけの save_five_changes / save_rename_only を別々に出す。
直接編集テスト testArchiveEditorsDirectlyWhenEnabled は同じ fixture で先頭・末尾の削除を測る。
作業用入力のコピーと出力検査は直接編集の total に含めない。

比較用には最適化した **Debug** ビルドを使う（DEBUG を消すと段の観測も消える）。

~~~sh
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build/P0bDerivedData \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule build-for-testing

TEST_RUNNER_KAITOFINDER_PERFORMANCE_PROBES=1 \
TEST_RUNNER_KAITOFINDER_PROBE_ENTRIES=2000 \
TEST_RUNNER_KAITOFINDER_PROBE_FORMATS=zip,tar.gz \
TEST_RUNNER_KAITOFINDER_PROBE_PAYLOAD_MIB=1 \
xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build/P0bDerivedData \
  -parallel-testing-enabled NO \
  -only-testing:KaitoFinderTests/PerformanceProbeTests test-without-building \
  > /tmp/kaitofinder-p0b.log 2>&1
~~~

TEST_RUNNER_ は xcodebuild がテストプロセスへ渡す際の接頭辞。XCTest を直接実行する場合は接頭辞なしの変数を設定する。
実サイズは 100000 / 500000、本文は 256 以上に変えて別々のログへ保存する。

## 出力と段の境界

fixture を新しく作ったときだけ、次のタブ区切りの行も一度出す（cache hit では出さない）。
input_bytes は小ファイルを含む非圧縮の全入力サイズで、payload では指定 MiB + 1,000 byte。
build_ms は生成と書庫の finish までの wall time。dictionary は使用した辞書のパス、builtin、または entries の NA。

~~~text
PROBE-FIXTURE version=2 format=zip kind=payload entries=1064 input_bytes=8389608 archive_bytes=... build_ms=... dictionary=/usr/share/dict/words
~~~

PROBE-TSV で始まるタブ区切りの一行が (format, fixture, mode, operation, stage) ごとの測定。
列は次の順で、PROBE-TSV-HEADER にも出す。

~~~text
PROBE-TSV version format fixture mode operation stage calls duration_ms read_bytes written_bytes output_bytes entries payload_mib status
~~~

version=1。calls は同じ段を通った回数、時間・I/O はその合計、output_bytes は操作終了時の書庫サイズ。
entries と payload_mib は入力 fixture の値。status=error は操作が throw した場合の途中結果。
I/O はプロセス全体の proc_pid_rusage(RUSAGE_INFO_V2) の差分で、失敗時は NA。
キャッシュヒットで 0 になることがあり、非同期の書き出しや同時実行の影響も受ける。論理的な読み書き量ではない。

| 段 | 範囲 |
|---|---|
| work_copy | ZIP のアプリ側 copyItem |
| updater_open / rewriter_open | GyoshukuKit の open 呼び出しが返るまで |
| mutate / replay | 即時操作の検証・削除・改名・追加、または保存計画の replay |
| remove | 直接編集テストの remove(entriesAt:) だけ |
| commit | GyoshukuKit の commit 呼び出しが返るまで |
| verification_open | 公開前の厳密な ArchiveReader.open |
| entry_comparison | P0-A の出力形式・名前・種類・件数・サイズの計画照合 |
| publish | willPublish（undo 退避も含む）、原本・作業ファイルの同一性検査、rename |
| reload | reloadAfterMutation 全体 |
| reload_open / capability_probe | reload 内の reader open / 書き込み可否の再検査 |
| replay_plan / validate_representability | 保存計画の構築 / 表現可能性の全件検査 |
| updater_preparation | ZIP の保存後などに行う編集準備の identity / updater open |
| editing_install / editing_prepare | 未キャッシュの基底検証 / projection・木・filter の準備 |
| tree_build / display | EntryNode の木の構築 / controller の同期的な再表示 |
| owner_restoration | 所有者 ID を保持する tar 保存経路での中間 tar 修正 |
| fixture_build / total | fixture 作成 / 操作の wall time |

**段は入れ子を含み、全行を足して total にしない。** reload は reload_open と capability_probe を含み、
editing_prepare は tree_build を含む。同じ段が複数ある tar の所有者 ID 保持経路は calls に現れる。
通らない段の行は出さない（例: rewriter にアプリ側の work_copy はない）。
total と段の差には即時編集の計画、undo の後処理、属性保存、作業ディレクトリの片付け、計測出力なども入る。
display 後に非同期で作る改名索引の完成は編集 total の外で待ち、次の操作へ持ち越さない。

GyoshukuKit の内部には計測を追加していない。ZIP updater の内部 clone は updater_open に含まれ、
rewriter の本文読み込み・再圧縮は実際に行われる open / mutate / commit の呼び出しに含まれる。
直接編集テストでアプリの計画・公開・再表示を除いた open / remove / commit と比較できる。

アプリ側の observer・clock・span は DEBUG 限定。同期ラッパーは Release で body だけにインライン化する。
observer のない通常実行では何も出力しない。I/O カウンタと出力はテスト側だけにある。
各段の前には PROBE-STAGE-BEGIN format/fixture/mode/operation/stage を stdout へ直接書く。
PROBE-PROCESS pid=... のプロセスへ、対象の commit が始まった時点で外部から sample を実行できる。
sampling を行った実行と比較用の無負荷の実行は分ける。

## この環境での検証

以下は correction 1 より前の fixture による結果。混合本文 v2 の結果は末尾に記す。

Swift 6 で、現行の両ライブラリのソースを読み、KaitoFinder 内の build/P0bVerification にビルドした。
両 sibling の作業ツリーは無変更。アプリ全ソースの Debug dylib と Release module、変更した probe と実際の
テスト補助ファイルの XCTest bundle を直接コンパイルできた。スタブは使っていない。
コンパイラの子プロセス用の入れ子の sandbox は disable-sandbox オプションで無効化し、外側の制約内で実行した。
Release の最適化 SIL も確認し、measure を通る例と直接呼ぶ例の実行命令が同じで、
TaskLocal / ContinuousClock がないことを確かめた。

その bundle を Xcode 付属の xctest で直接実行した（アプリホスト経由の xcodebuild test ではない）。
計測用バイナリは **非最適化の Debug**。以下は動作・出力形式の確認で、10 万 / 50 万件・256 MiB の比較基準ではない。

| 実行 | 形式 | ENTRIES | PAYLOAD_MIB | 結果 |
|---|---|---|---|---|
| スイッチ未設定、PerformanceProbeTests 全体 | 既定 | 既定 | 既定 | 3 件スキップ、失敗 0、0.008 秒 |
| testArchiveEditorsDirectlyWhenEnabled | zip,tar.gz | 2000 | 1 | 1 件成功、1.242 秒 |
| testArchiveEditsWhenEnabled | zip,tar.gz | 2000 | 1 | 1 件成功、15.763 秒 |
| 上記の編集と直接編集の 2 テストを同じプロセスで実行 | tar,tar.bz2,tar.xz,7z,lha | 32 | 1 | 2 件成功、32.009 秒 |

全形式で二つの fixture、即時編集 8 種、保存 2 種、直接編集の先頭・末尾削除を実行。
段が欠けていないこと、置換が衝突 resolver を通ったこと、保存後の entry、公開後の reload 成功を検査した。
小項目 fixture の ENTRIES とは別に、本文 fixture は各回とも 64 本 + 1,000 小項目。
PROBE_ASSERT は未設定。有効時の開く専用テスト、sample、全回帰テスト、実サイズの測定は実行していない。

抽出した TSV は全 2,197 行で、15 列・一意な key・status=ok を確認した。
各ファイルはヘッダ付きで、元ログも同じディレクトリに置いた。

- [ZIP / tar.gz 直接編集（36 行）](../../build/P0bVerification/direct.tsv)
- [ZIP / tar.gz 編集・保存（612 行）](../../build/P0bVerification/edits.tsv)
- [残り 5 形式（1,549 行）](../../build/P0bVerification/other-formats.tsv)
- [スイッチ未設定のログ](../../build/P0bVerification/skip.log)

参考値（entries fixture、非最適化 Debug、ms）:

| 形式 / 件数 | 即時先頭削除 total | 即時末尾削除 total | 五操作の保存 total | 改名だけの保存 total |
|---|---|---|---|---|
| ZIP / 2000 | 140.322 | 133.607 | 230.024 | 272.907 |
| tar.gz / 2000 | 374.612 | 377.442 | 321.812 | 465.141 |

通常の xcodebuild build-for-testing は完走できていない。最初の試行は Sparkle の取得でネットワークを拒否され、
既存の checkout を使う試行は SwiftPM のユーザーキャッシュへの書き込みを拒否された。キャッシュを KaitoFinder 内へ
向けた試行と明示的な依存解決でも、manifest 実行の sandbox-exec: sandbox_apply: Operation not permitted で停止した
（build 側では Missing package product となる）。通常の build-for-testing の成功は主張しない。
ログは /tmp/kaitofinder-p0b-build.log、-build-cached.log、-build-redirected.log、-resolve.log。
オーケストレータ側で通常の build-for-testing と上記の実サイズ測定を行う。

## Correction 1: 混合本文 v2

従来の本文は同じ短い行の繰り返しで、実際のテキストの圧縮費用を代表していなかった。
48 本の辞書テキストと 16 本の疑似乱数へ変更した。既存の編集経路・段・操作・パス・サイズ設定は変えていない。
PROBE-FIXTURE に版、入力と出力のサイズ、作成時間、辞書の出所も記録する。

Swift 6 で変更した XCTest bundle を直接コンパイルし、xctest で次を実行した。
ライブラリとアプリは前回の実ソースからの Debug ビルドを使用。今回の head bb6d780 の変更は計画文書だけ。

- ENTRIES=2000、PAYLOAD_MIB=8、FORMATS=zip,tar.xz、PERFORMANCE_PROBES=1。
  直接編集と編集・保存の 2 テストを同一プロセスで実行し、失敗 0（7.430 秒 + 37.689 秒）。
  全 644 TSV 行の列数・一意な key・status=ok を確認した。
- 二つの形式 × 二つの fixture について、PROBE-FIXTURE が **計 4 行だけ** 出た。
  entries は入力 2,000 byte、payload は 8,389,608 byte（8 MiB + 小項目 1,000 byte）。
  cache を再利用する二つ目のテストでの再出力はなかった。
- スイッチを外した実行は従来どおり 3 件スキップ、失敗 0。
- ソースから抜き出した同じ生成処理を最適化して別途検査した。
  実辞書・辞書がない場合の両方で、64 本が全て異なり、再生成で一致し、合計が 8 MiB になった。
  48 本のテキストの zlib 出力は実辞書で 3,069,237 byte、組み込みで 1,977,335 byte（入力各 6 MiB）。
  16 本の疑似乱数の zlib 出力は両方で 2,097,792 byte（入力 2 MiB）。
  生成だけの 256 MiB チェックは約 0.264 秒。圧縮の時間は含めない。

| fixture | 入力 byte | 書庫 byte | 作成 ms |
|---|---|---|---|
| zip / entries | 2000 | 282022 | 54.125 |
| zip / payload | 8389608 | 5297368 | 323.961 |
| tar.xz / entries | 2000 | 4532 | 105.761 |
| tar.xz / payload | 8389608 | 4216356 | 1876.163 |

非最適化 Debug の小規模動作確認であり、100k / 500k・256 MiB の測定値ではない。
build-for-testing は再試行したが Missing package product で停止した。明示的な package resolution も
sandbox-exec: sandbox_apply: Operation not permitted で停止しており、通常の Xcode ビルドの成功は主張しない。
ログは /tmp/kaitofinder-p0b-c1-build.log と /tmp/kaitofinder-p0b-c1-resolve.log。
両 sibling は無変更、コミットは作成していない。

- [混合本文 v2 の TSV](../../build/P0bVerification/Correction1/probes.tsv)
- [fixture の情報](../../build/P0bVerification/Correction1/fixtures.log)
- [プローブのログ](../../build/P0bVerification/Correction1/probes.log)
- [生成処理の検査](../../build/P0bVerification/Correction1/payload-check.log)

## 基準値（2026-09-25、オーケストレータ）

KaitoFinder 1f1ba35 + P0b、GyoshukuKit c0df9fb、KaitoKit b518014。-O・wholemodule の Debug、M4 Max。
1 byte のファイルの表は 100k が全形式、500k が zip・tar・tar.gz。本文の表は現実的な本文（修正 1 の後）で測った。
最初の本文の計測は 1 行の繰り返しで圧縮が極端に効き、再圧縮の費用を表さなかったため捨てた。

#### 1 byte のファイル N 件（ミリ秒）

| N | 形式 | 先頭削除 | 末尾削除 | 同長改名 | フォルダ改名 | 1 件追加 | 置換 | 保存（5 変更） | 書込み MB（先頭削除） |
|---|---|---|---|---|---|---|---|---|---|
| 100,000 | zip | 1697 | 1371 | 1566 | 1884 | 1028 | 2056 | 3644 | 14 |
| 100,000 | tar | 3042 | 3097 | 3222 | 3206 | 3026 | 3086 | 4383 | 102 |
| 100,000 | tar.gz | 2379 | 2442 | 2604 | 2690 | 2441 | 2516 | 3842 | 308 |
| 100,000 | tar.bz2 | 2613 | 2682 | 2882 | 2940 | 2661 | 2763 | 3979 | 307 |
| 100,000 | tar.xz | 3108 | 3106 | 3305 | 3349 | 3144 | 3214 | 4459 | 307 |
| 100,000 | 7z | 5487 | 5452 | 5523 | 5138 | 5135 | 5208 | 6429 | 7 |
| 100,000 | lha | 4007 | 4020 | 4222 | 4247 | 4078 | 4107 | 5767 | 7 |
| 500,000 | zip | 8322 | 6674 | 7733 | 9250 | 5101 | 10103 | 16669 | 69 |
| 500,000 | tar | 14858 | 14889 | 15906 | 16071 | 15102 | 15447 | 20272 | 512 |
| 500,000 | tar.gz | 11823 | 11788 | 12819 | 12976 | 12409 | 13148 | 17457 | 1541 |

#### 本文 256 MiB（48 個は辞書の文、16 個は乱数）+ 1,000 件（ミリ秒）

| N | 形式 | 先頭削除 | 末尾削除 | 同長改名 | フォルダ改名 | 1 件追加 | 置換 | 保存（5 変更） | 書込み MB（先頭削除） |
|---|---|---|---|---|---|---|---|---|---|
| 1,064 | zip | 278 | 78 | 41 | 294 | 36 | 288 | 75 | 161 |
| 1,064 | tar | 111 | 111 | 114 | 115 | 112 | 112 | 117 | 265 |
| 1,064 | tar.gz | 1880 | 1886 | 1895 | 1904 | 1913 | 1869 | 2188 | 955 |
| 1,064 | tar.bz2 | 21005 | 20861 | 20805 | 20659 | 20593 | 20468 | 20943 | 940 |
| 1,064 | tar.xz | 22739 | 22984 | 23055 | 22967 | 23052 | 22805 | 23403 | 931 |
| 1,064 | 7z | 11114 | 11058 | 11099 | 11059 | 11392 | 11011 | 11461 | 136 |
| 1,064 | lha | 5592 | 5698 | 5710 | 5698 | 5678 | 5581 | 5995 | 338 |

書込み MB は proc_pid_rusage のプロセス全体の差分（一時ファイルを含む）。圧縮 tar は開くたびに全体を一時ファイルへ展開するため、
1 回の編集で rewriter・公開前の検証・再読み込みの 3 回ぶん書く（50 万件の tar.gz で 1.5 GB、本文の tar.bz2 で 0.94 GB）。
本文の tar.bz2 は 1 回の展開が約 6.3 s（1 スレッド）で、それが 3 回ある。tar.xz と 7z は本文全体の再圧縮（18.3 s、11 s）が大半。
