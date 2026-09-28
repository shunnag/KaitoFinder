import Darwin
import Foundation

nonisolated enum ExtractionFailure: Error, CustomStringConvertible {
    case refused(String)
    case system(Int32)

    var description: String {
        switch self {
        case .refused(let reason): reason
        case .system(let code): String(localized: "POSIX \(code): \(String(cString: strerror(code)))")
        }
    }
}
