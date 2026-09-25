import Foundation
import os

/// 利用者向けの文言を変えず、検証のどこで拒否したかだけを残す。
nonisolated enum ArchiveVerificationFailure: Sendable, Equatable, CustomStringConvertible {
    enum Phase: String, Sendable { case beforeVerification, beforePublication }
    enum Anchor: String, Sendable { case path, descriptor }
    struct FailureCode: Sendable, Equatable, CustomStringConvertible {
        let type: String
        let code: Int
        init(_ error: any Error) {
            type = String(reflecting: Swift.type(of: error))
            code = (error as NSError).code
        }
        var description: String { "\(type)(\(code))" }
    }
    struct Entry: Sendable, Equatable, CustomStringConvertible {
        let index: Int
        let fileName: String
        let kind: String
        let size: UInt64?
        init(index: Int, name: String, kind: String, size: UInt64?) {
            self.index = index
            // 書庫内の親パスもログへ持ち込まない。
            fileName = name.split(separator: "/").last.map(String.init) ?? ""
            self.kind = kind; self.size = size
        }
        var description: String { "entry[\(index)] name=\(fileName) kind=\(kind) size=\(size.map(String.init) ?? "unknown")" }
    }
    case sourceOpen(FailureCode)
    case identity(Phase, Anchor, expected: ArchiveFileIdentity, actual: ArchiveFileIdentity?, error: FailureCode?)
    case readerOpen(FailureCode)
    case format(expected: String, actual: String)
    case projection(expected: Entry?, actual: Entry?)
    case encryption(index: Int, expected: String, actual: String?, isEncrypted: Bool)
    case outputProbe(FailureCode)
    case outputCount(expected: UInt64, actual: UInt64)

    var description: String {
        switch self {
        case .sourceOpen(let error): "source_open: \(error)"
        case .identity(let phase, let anchor, let expected, let actual, let error):
            "identity \(phase.rawValue) \(anchor.rawValue): expected=\(expected) actual=\(actual.map(String.init(describing:)) ?? "unavailable") error=\(error.map(String.init(describing:)) ?? "none")"
        case .readerOpen(let error): "reader_open: \(error)"
        case .format(let expected, let actual): "format: expected=\(expected) actual=\(actual)"
        case .projection(let expected, let actual):
            "projection: expected=\(expected.map(String.init(describing:)) ?? "none") actual=\(actual.map(String.init(describing:)) ?? "none")"
        case .encryption(let index, let expected, let actual, let isEncrypted):
            "encryption: entry[\(index)] expected=\(expected) actual=\(actual ?? "unknown") encrypted=\(isEncrypted)"
        case .outputProbe(let error): "output_probe: \(error)"
        case .outputCount(let expected, let actual): "output_count: expected=\(expected) actual=\(actual)"
        }
    }

    private static let logger = Logger(subsystem: "com.shunnag.KaitoFinder", category: "PublicationVerification")
    #if DEBUG
    static let observer = TaskLocal<(@Sendable (ArchiveVerificationFailure) -> Void)?>(wrappedValue: nil)
    #endif
    func reported(file: URL) -> ArchivePublicationError {
        // 下位 error の説明には鍵やパスが含まれ得るので、型と数値 code だけを記録する。
        Self.logger.error("Verification failed for \(file.lastPathComponent, privacy: .public): \(description, privacy: .public)")
        #if DEBUG
        Self.observer.get()?(self)
        #endif
        return ArchivePublicationError(reason: self)
    }
}
