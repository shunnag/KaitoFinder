import Darwin
import Foundation

nonisolated enum ExtractionQuarantine {
    static let name = "com.apple.quarantine"

    static func read(from url: URL) throws -> Data? {
        // サイズ取得と読み出しの間で属性が伸びた場合だけ、再取得する。
        for _ in 0..<3 {
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 {
                if errno == ENOATTR { return nil }
                throw ExtractionFailure.system(errno)
            }
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes {
                getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            if count >= 0 { return Data(data.prefix(count)) }
            if errno != ERANGE { throw ExtractionFailure.system(errno) }
        }
        throw ExtractionFailure.refused("quarantine 属性が読み取り中に変化しました")
    }

    static func apply(_ data: Data?, to url: URL) throws {
        guard let data else {
            if removexattr(url.path, name, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                throw ExtractionFailure.system(errno)
            }
            return
        }
        let result = data.withUnsafeBytes {
            setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw ExtractionFailure.system(errno) }
    }

    static func apply(_ data: Data?, toDescriptor descriptor: Int32) throws {
        guard let data else {
            if fremovexattr(descriptor, name, 0) != 0, errno != ENOATTR {
                throw ExtractionFailure.system(errno)
            }
            return
        }
        let result = data.withUnsafeBytes {
            fsetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0)
        }
        guard result == 0 else { throw ExtractionFailure.system(errno) }
    }
}
