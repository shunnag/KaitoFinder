import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated enum TarUpdateFixture {
    static func checksum(_ header: inout Data) {
        header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
        let value = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
        header.replaceSubrange(148..<156, with: (String(repeating: "0", count: 6 - value.count) + value + "\0 ").utf8)
    }

    static func member(_ name: String, type: UInt8 = 48, body: Data = Data("payload".utf8), link: String = "") -> Data {
        var header = Data(count: 512)
        func text(_ value: String, _ offset: Int) { header.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8) }
        func number(_ value: Int, _ offset: Int, _ width: Int) {
            let digits = String(value, radix: 8)
            text(String(repeating: "0", count: width - 1 - digits.count) + digits + "\0", offset)
        }
        text(name, 0); number(0o755, 100, 8); number(501, 108, 8); number(20, 116, 8)
        number(body.count, 124, 12); number(1_700_000_000, 136, 12)
        header[156] = type; text(link, 157); text("ustar\0" + "00", 257); text("alice", 265); text("staff", 297)
        checksum(&header)
        return header + body + Data(count: (512 - body.count % 512) % 512)
    }

    static func pax(_ key: String, _ value: String, type: UInt8 = 120) -> Data {
        let suffix = " \(key)=\(value)\n"
        var count = suffix.utf8.count + 1
        while String(count).utf8.count + suffix.utf8.count != count { count = String(count).utf8.count + suffix.utf8.count }
        return member("PaxHeader", type: type, body: Data("\(count)\(suffix)".utf8))
    }

    static var bytes: Data {
        pax("SCHILY.xattr.user.kaito", "kept") + member("keep") + member("remove")
            + member("folder/", type: 53, body: Data()) + member("folder/child") + member("last") + Data(count: 1024)
    }

    static func archive(_ root: URL, bytes: Data = bytes, name: String = "original.tar") throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    static func groups(_ bytes: Data) -> [Data] {
        var result: [Data] = [], offset = 0, start = 0
        while offset + 512 <= bytes.count, bytes[offset..<(offset + 512)].contains(where: { $0 != 0 }) {
            let size = Int(String(decoding: bytes[(offset + 124)..<(offset + 136)].prefix { $0 != 0 && $0 != 32 }, as: UTF8.self), radix: 8)!
            let type = bytes[offset + 156]
            offset += 512 + (size + 511) / 512 * 512
            if ![UInt8(120), 103, 76, 75].contains(type) {
                result.append(bytes.subdata(in: start..<offset)); start = offset
            }
        }
        return result
    }

    static func selection(_ entry: ArchiveEntry) -> ArchiveEditSelection {
        .init(path: entry.name, isDirectory: entry.kind == .directory, entries: [entry])
    }
}
