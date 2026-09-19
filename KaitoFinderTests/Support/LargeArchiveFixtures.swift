import Foundation

/// サイズ制限を実データの大量書き込みなしで検証するため、本文は sparse hole にする。
nonisolated enum LargeArchiveFixtures {
    static let fourGiB: UInt64 = 4 * 1_024 * 1_024 * 1_024
    static let zipEntrySize = fourGiB + 1
    static let tarEntryNames = (0..<17).map { String(format: "part%02d.bin", $0) }

    static func zip64(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("big-zip64.zip")
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let name = Data("big.bin".utf8)
        // 4 GiB + 1 個のゼロの CRC-32。全量を走査せず、全展開時の検証も成立させる。
        let crc: UInt32 = 0x41d912ff
        var extra = ZIPRecord()
        extra.append16(1, 16)
        extra.append64(zipEntrySize, zipEntrySize)

        var local = ZIPRecord()
        local.append32(0x04034b50)
        local.append16(45, 0, 0, 0, 0x5a21)
        local.append32(crc, .max, .max)
        local.append16(UInt16(name.count), UInt16(extra.data.count))
        try file.write(contentsOf: local.data + name + extra.data)
        let dataStart = try file.offset()
        try file.seek(toOffset: dataStart + zipEntrySize - 1)
        try file.write(contentsOf: Data([0]))

        let centralStart = try file.offset()
        var central = ZIPRecord()
        central.append32(0x02014b50)
        central.append16(45, 45, 0, 0, 0, 0x5a21)
        central.append32(crc, .max, .max)
        central.append16(UInt16(name.count), UInt16(extra.data.count), 0, 0, 0)
        central.append32(0, 0)
        try file.write(contentsOf: central.data + name + extra.data)
        let zip64Start = try file.offset()
        let centralSize = zip64Start - centralStart

        var end = ZIPRecord()
        end.append32(0x06064b50)
        end.append64(44)
        end.append16(45, 45)
        end.append32(0, 0)
        end.append64(1, 1, centralSize, centralStart)
        end.append32(0x07064b50, 0)
        end.append64(zip64Start)
        end.append32(1, 0x06054b50)
        end.append16(0, 0, 1, 1)
        end.append32(UInt32(centralSize), .max)
        end.append16(0)
        try file.write(contentsOf: end.data)
        return url
    }

    static func hugeTotalTar(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("huge-total.tar")
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        for name in tarEntryNames {
            var header = Data(repeating: 0, count: 512)
            header.replaceSubrange(0..<name.utf8.count, with: name.utf8)
            header.replaceSubrange(100..<108, with: octal(0o644, width: 8))
            header.replaceSubrange(108..<116, with: octal(0, width: 8))
            header.replaceSubrange(116..<124, with: octal(0, width: 8))
            header.replaceSubrange(124..<136, with: octal(fourGiB, width: 12))
            header.replaceSubrange(136..<148, with: octal(1_735_689_600, width: 12))
            header.replaceSubrange(148..<156, with: repeatElement(UInt8(0x20), count: 8))
            header[156] = 0x30
            header.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
            header.replaceSubrange(263..<265, with: Data("00".utf8))
            let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
            header.replaceSubrange(148..<156, with: octal(checksum, width: 7) + Data([0x20]))
            try file.write(contentsOf: header)
            let dataStart = try file.offset()
            try file.seek(toOffset: dataStart + fourGiB - 1)
            try file.write(contentsOf: Data([0]))
        }
        try file.write(contentsOf: Data(repeating: 0, count: 1_024))
        return url
    }

    private static func octal(_ value: UInt64, width: Int) -> Data {
        let digits = String(value, radix: 8)
        return Data((String(repeating: "0", count: width - 1 - digits.count) + digits + "\0").utf8)
    }

    private struct ZIPRecord {
        var data = Data()

        mutating func append16(_ values: UInt16...) { append(values) }
        mutating func append32(_ values: UInt32...) { append(values) }
        mutating func append64(_ values: UInt64...) { append(values) }

        private mutating func append<T: FixedWidthInteger>(_ values: [T]) {
            for value in values {
                var littleEndian = value.littleEndian
                withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
            }
        }
    }
}
