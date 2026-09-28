import Foundation

/// テストが読む環境変数の一覧。キーの名前と意味はここで一度だけ述べ、値の解釈（既定値、"1" か、空でないか）は
/// 読む側が持つ。xcodebuild には `TEST_RUNNER_` を前置して渡す（例: `TEST_RUNNER_KAITOFINDER_PERFORMANCE_PROBES=1`）。
/// Tools/verify_*.py は .xctestrun の環境変数として渡す。
nonisolated enum TestEnvironment {
    enum Key: String {
        // MARK: 性能計測（Probes/）

        /// "1" のとき Probes/ の性能計測を実行し、`PROBE-*` の行を出力する。
        case performanceProbes = "KAITOFINDER_PERFORMANCE_PROBES"
        /// 計測に使う項目数。既定値は probe ごとに異なる（ArchiveProbeConfiguration は 100,000、フォルダ移動は 500,000）。
        case probeEntries = "KAITOFINDER_PROBE_ENTRIES"
        /// 多数の file の追加・作成の probe で足す file の数。未設定なら 0 で、その probe を skip する。
        case probeAddFiles = "KAITOFINDER_PROBE_ADD_FILES"
        /// 内容の大きい書庫の probe の payload（MiB）。
        case probePayloadMiB = "KAITOFINDER_PROBE_PAYLOAD_MIB"
        /// 分割保存の probe の 1 巻の大きさ（MiB）。
        case probeSplitVolumeMiB = "KAITOFINDER_PROBE_SPLIT_VOLUME_MIB"
        /// 計測する形式。カンマか空白で区切る（zip, tar, tar.gz, tar.bz2, tar.xz, 7z, lha）。
        case probeFormats = "KAITOFINDER_PROBE_FORMATS"
        /// "1" のとき、probe の所要時間の上限を assertion として検査する。
        case probeAssert = "KAITOFINDER_PROBE_ASSERT"
        /// 編集の probe で項目を足す位置（`ArchivePreferences.AdditionPosition` の rawValue）。
        case probeAdditionPlacement = "KAITOFINDER_PROBE_ADDITION_PLACEMENT"
        /// パスワード編集の probe で使う暗号方式。カンマか空白で区切る（aes, zipcrypto, 7z）。
        case probeEncryption = "KAITOFINDER_PROBE_ENCRYPTION"
        /// "1" のとき、編集の probe の前に改名用の索引を作り終えておく。
        case probeWarmIndex = "KAITOFINDER_PROBE_WARM_INDEX"

        // MARK: 通常の実行では skip する重いテスト

        /// "1" のとき、100,000 項目の ZIP の session を開く時間を測る（ArchiveCapabilityInspectionTests）。
        case scaleTiming = "KAITOFINDER_SCALE_TIMING"
        /// "1" のとき、4 GiB + 1 byte の ZIP64 項目を実際に展開する（LargeArchiveTests）。
        case largeEntryTests = "KAITOFINDER_LARGE_ENTRY_TESTS"
        /// 空でないとき、そのボリュームへ tar の backslash を含む名前を展開する（TarBackslashExtractionTests）。
        case tarBackslashDestination = "KAITOFINDER_P13_DESTINATION"
        /// 設定されているとき、BatchImportExportProbeTests が作成・追加の結果をこのフォルダへ書き出す。
        /// その file は古い tree へ単独で複写して使うため、この enum を使わず文字列で読む。
        case batchImportExportDirectory = "KAITOFINDER_P7_EXPORT_DIRECTORY"

        // MARK: 画面の記録と Tools/ の検証 driver

        /// UISnapshot の出力先。未設定か空なら一時フォルダの下に実行ごとのフォルダを作る。
        case snapshotDirectory = "KAITOFINDER_SNAPSHOT_DIR"
        /// 設定されているとき、衝突確認の内容比較の実画面をこのフォルダへ記録する（ArchiveConflictUITests）。
        case conflictCaptureDirectory = "KAITOFINDER_CONFLICT_CAPTURE_DIRECTORY"
        /// 設定されているとき、保存パネルの animation をこのフォルダへ記録する（Tools/verify_save_panel_animation.py）。
        case savePanelCaptureDirectory = "KAITOFINDER_SAVE_PANEL_CAPTURE_DIRECTORY"
        /// プレビューの撮影を外部ツールへ頼む要求 file（Tools/verify_preview_sidebar.py）。
        case previewCaptureRequest = "KAITOFINDER_PREVIEW_CAPTURE_REQUEST"
        /// 実際の保存パネルのボタンを外部ツールに押させる要求 file（Tools/verify_ui_integration.py）。未設定なら skip する。
        case nativeSaveRequest = "KAITOFINDER_NATIVE_SAVE_REQUEST"
        /// Finder と同じ実入力を外部ツールに送らせる要求 file（Tools/verify_finder_interactions.py）。未設定なら skip する。
        case finderInputRequest = "KAITOFINDER_FINDER_INPUT_REQUEST"
        /// 最近使った項目を起動をまたいで検査するときの段階（Tools/verify_ui_integration.py）。未設定なら skip する。
        case recentsPhase = "KAITOFINDER_RECENTS_PHASE"
        /// 上の検査で使う、検証専用のランダムな bundle ID。
        case recentsBundleID = "KAITOFINDER_RECENTS_BUNDLE_ID"
        /// 上の検査で開く書庫の path。
        case recentsArchive = "KAITOFINDER_RECENTS_ARCHIVE"

        // MARK: 実行環境

        /// 設定されていれば（値は問わない）CI 上の実行とみなし、所要時間の assertion だけを省く。
        case ci = "CI"
    }

    /// `environment`（既定は今のプロセスの環境変数）での `key` の値。
    static func value(_ key: Key, in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[key.rawValue]
    }

    /// `key` の値がちょうど "1" のとき true。
    static func isEnabled(_ key: Key, in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        value(key, in: environment) == "1"
    }

    /// CI が設定されているとき true。
    static var isCI: Bool { value(.ci) != nil }
}
