import Foundation

/// テストが読むリポジトリ内のパス。この file の位置（KaitoFinderTests/Support/）から 1 回だけ求めるので、
/// テスト file をサブディレクトリへ移しても参照先は変わらない。
nonisolated enum TestPaths {
    /// KaitoFinderTests/
    static let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    /// リポジトリの root（KaitoFinder/、KaitoFinderTests/、Documentation/ を含む）。
    static let repositoryRoot = testsRoot.deletingLastPathComponent()
    /// KaitoFinderTests/Fixtures/
    static let fixtures = testsRoot.appendingPathComponent("Fixtures")
    /// 隣に checkout した KaitoKit の Tests/Fixtures/。
    static let kaitoKitFixtures = repositoryRoot.deletingLastPathComponent().appendingPathComponent("KaitoKit/Tests/Fixtures")
}
