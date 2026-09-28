/// アプリが組み立てる NSError の domain。AppKit の表示と XCTest の照合が値を見るため、文字列は変えない。
nonisolated enum KaitoFinderErrorDomain {
    /// アーカイブを開けなかった（ArchiveDocument.openingError）。
    static let document = "com.shunnag.KaitoFinder.document"
    /// 保存前モードの保存の失敗と、保存中に見つけた外部変更。
    static let deferred = "com.shunnag.KaitoFinder.deferred"
    /// 分割アーカイブの中断した保存を探す段階の失敗。
    static let splitDiscovery = "com.shunnag.KaitoFinder.split-discovery"
    /// 中断した保存の回復を提案するエラー（ArchiveVolumeOpenError）。
    static let splitRecovery = "com.shunnag.KaitoFinder.split-recovery"
    /// アーカイブ作成・保存パネルの検証エラー（ArchiveUserError.creation）。ReadOnlyDropConversionUITests が値を照合する。
    static let creation = "com.shunnag.KaitoFinder.creation"
    /// パスワード入力欄の検証エラー（ArchiveUserError.password）。
    static let password = "com.shunnag.KaitoFinder.password"
}
