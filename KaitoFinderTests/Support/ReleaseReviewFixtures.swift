import Foundation

/// Small, deterministic archives built without external fixture tools.
nonisolated enum ReleaseReviewFixtures {
    static func zip(_ members: [(String, Data)]) -> Data {
        var local = Data(), central = Data()
        for (path, payload) in members {
            let name = Data(path.utf8), offset = UInt32(local.count)
            var crc: UInt32 = .max
            for byte in payload {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            crc = ~crc
            append(UInt32(0x04034b50), to: &local)
            for value in [UInt16(20), 0, 0, 0, 0x5a21] { append(value, to: &local) }
            for value in [crc, UInt32(payload.count), UInt32(payload.count)] { append(value, to: &local) }
            append(UInt16(name.count), to: &local); append(UInt16(0), to: &local)
            local += name + payload
            append(UInt32(0x02014b50), to: &central)
            for value in [UInt16(20), 20, 0, 0, 0, 0x5a21] { append(value, to: &central) }
            for value in [crc, UInt32(payload.count), UInt32(payload.count)] { append(value, to: &central) }
            for value in [UInt16(name.count), 0, 0, 0, 0] { append(value, to: &central) }
            // DOS creator and external_attr == 0: no stored Unix permissions.
            append(UInt32(0), to: &central); append(offset, to: &central)
            central += name
        }
        var end = Data()
        append(UInt32(0x06054b50), to: &end)
        for value in [UInt16(0), 0, UInt16(members.count), UInt16(members.count)] { append(value, to: &end) }
        append(UInt32(central.count), to: &end); append(UInt32(local.count), to: &end)
        append(UInt16(0), to: &end)
        return local + central + end
    }

    static func paxTar(_ members: [(String, String, Data)]) -> Data {
        var archive = Data()
        for (name, mtime, payload) in members {
            let value = " mtime=\(mtime)\n"
            var length = value.utf8.count + 1
            while String(length).utf8.count + value.utf8.count != length {
                length = String(length).utf8.count + value.utf8.count
            }
            archive += tarMember("PaxHeader", type: 0x78, data: Data("\(length)\(value)".utf8))
            archive += tarMember(name, type: 0x30, data: payload)
        }
        return archive + Data(repeating: 0, count: 1024)
    }

    private static func tarMember(_ name: String, type: UInt8, data: Data) -> Data {
        var header = Data(repeating: 0, count: 512)
        func field(_ offset: Int, _ width: Int, _ value: Int) {
            let digits = String(value, radix: 8)
            header.replaceSubrange(offset..<(offset + width),
                with: (String(repeating: "0", count: width - 1 - digits.count) + digits + "\0").utf8)
        }
        header.replaceSubrange(0..<name.utf8.count, with: name.utf8)
        field(100, 8, 0o644); field(108, 8, 0); field(116, 8, 0)
        field(124, 12, data.count); field(136, 12, 0)
        header.replaceSubrange(148..<156, with: repeatElement(UInt8(0x20), count: 8))
        header[156] = type
        header.replaceSubrange(257..<265, with: "ustar\000".utf8)
        let checksum = header.reduce(0) { $0 + Int($1) }
        field(148, 7, checksum); header[155] = 0x20
        return header + data + Data(repeating: 0, count: (512 - data.count % 512) % 512)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
