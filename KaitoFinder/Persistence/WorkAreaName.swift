import Foundation

/// KaitoFinder が作る作業領域と退避物の名前。ディスク上の名前は版を跨いで安定でなければならないので、ここだけで定義する。
///
/// - `add` / `new` / `staging`: 書庫の隣に作る一時ディレクトリ。`PendingWorkRegistry` が台帳に記録し、次回起動時に回収する。
/// - `volume`: 分割セット公開の staging ディレクトリ。台帳は `RecoverableWorkIndex`、回収は `VolumePublishRecovery` が担う。
/// - `deleted` / `ownerLock`: `StagingRegistry` の root 内部の名前（退避物の墓標と、所有を示す flock ファイル）。
/// - `rename`: 保存の再生で改名を一時退避する書庫内の項目名。ファイルシステム上には現れない。
/// - `commonPrefix`: すべてに共通する接頭辞。取り込みの除外判定に使う。
nonisolated enum WorkAreaName {
    static let commonPrefix = ".KaitoFinder-"
    static let add = ".KaitoFinder-add-"
    static let new = ".KaitoFinder-new-"
    static let staging = ".KaitoFinder-staging-"
    static let volume = ".KaitoFinder-vol-"
    static let rename = ".KaitoFinder-rename-"
    static let deleted = ".KaitoFinder-deleted-"
    static let ownerLock = ".KaitoFinder-owner.lock"
}
