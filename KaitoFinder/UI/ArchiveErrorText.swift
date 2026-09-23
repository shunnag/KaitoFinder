import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

nonisolated enum ArchiveErrorText {
    static func describe(_ error: any Error, bundle: Bundle = .main) -> String {
        switch error {
        case is CancellationError:
            return String(localized: "キャンセルされました", bundle: bundle)
        case let error as KaitoError:
            switch error {
            case .unsupportedFormat: return String(localized: "対応していないアーカイブ形式です", bundle: bundle)
            case .unsupportedMethod(let method): return String(localized: "対応していない圧縮方式です: \(method)", bundle: bundle)
            case .malformed(let reason): return String(localized: "アーカイブの構造が壊れています: \(reason)", bundle: bundle)
            case .truncated: return String(localized: "アーカイブが途中で切れています", bundle: bundle)
            case .passwordRequired: return String(localized: "パスワードが必要です", bundle: bundle)
            case .wrongPassword: return String(localized: "パスワードが正しくありません", bundle: bundle)
            case .checksumMismatch(let index): return String(localized: "項目 \(String(index)) のチェックサムが一致しません", bundle: bundle)
            case .limitExceeded(let reason): return String(localized: "アーカイブが大きすぎるか複雑すぎるため、読み込みの上限を超えました(\(reason))", bundle: bundle)
            case .io(let code): return posix(code)
            case .notFound(let name): return String(localized: "見つかりません: \(name)", bundle: bundle)
            }
        case let error as WriterError:
            switch error {
            case .invalidOption(let option): return String(localized: "書き込みオプションが不正です: \(option)", bundle: bundle)
            case .unsupportedOption(let option): return String(localized: "対応していない書き込みオプションです: \(option)", bundle: bundle)
            case .invalidPath(let path): return String(localized: "このパスは使えません: \(path)", bundle: bundle)
            case .duplicatePath(let path): return String(localized: "同じパスが重複しています: \(path)", bundle: bundle)
            case .unsupportedFileType(let type): return String(localized: "対応していないファイルの種類です: \(type)", bundle: bundle)
            case .sourceChanged(let path): return String(localized: "追加中にファイルが変更されました: \(path)", bundle: bundle)
            case .invalidDate: return String(localized: "日付が不正です", bundle: bundle)
            case .invalidState: return String(localized: "内部状態が不正です", bundle: bundle)
            case .io(let operation, let code): return String(localized: "\(operation): \(posix(code))", bundle: bundle)
            case .compression(let code): return String(localized: "圧縮に失敗しました(コード \(code))", bundle: bundle)
            case .sizeOverflow: return String(localized: "サイズが上限を超えています", bundle: bundle)
            }
        case let error as RewriterError:
            switch error {
            case .unrepresentable(let entry, let reason):
                return String(localized: "書き直せない項目があります: \(entry)(\(reason))", bundle: bundle)
            case .password(nil): return String(localized: "暗号化されたアーカイブです", bundle: bundle)
            case .password(let entry?): return String(localized: "暗号化された項目があります: \(entry)", bundle: bundle)
            case .invalidArchive(let reason): return String(localized: "アーカイブが不正です: \(reason)", bundle: bundle)
            case .invalidState: return String(localized: "内部状態が不正です", bundle: bundle)
            }
        case let error as UpdaterError:
            switch error {
            case .editingRefused(_, let reason): return reason
            case .invalidArchive(let reason): return String(localized: "アーカイブが不正です: \(reason)", bundle: bundle)
            case .invalidEntryIndex(let index): return String(localized: "項目の番号が不正です: \(index)", bundle: bundle)
            case .nonRelocatableEntry(_, let name, let reason):
                return String(localized: "移動できない項目があります: \(name)(\(reason))", bundle: bundle)
            case .sourceChanged: return String(localized: "アーカイブが変更されています。開き直してください", bundle: bundle)
            case .invalidState: return String(localized: "内部状態が不正です", bundle: bundle)
            }
        case let error as VolumePublishError: return error.message(bundle: bundle)
        case let error as ArchiveEditError: return error.errorDescription ?? error.localizedDescription
        case let error as ExtractionFailure: return error.description
        default: return error.localizedDescription
        }
    }

    private static func posix(_ code: Int32) -> String { String(cString: strerror(code)) }
}
