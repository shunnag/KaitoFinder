import Foundation
import XCTest

nonisolated enum SingleCopyZIPFixtures {
    enum Kind: String, CaseIterable { case zip64, ditto, unsignedDescriptor, zipCrypto, aes, reordered, gaps, unicodePath }

    static func make(_ kind: Kind, in directory: ArchiveTestDirectory) throws -> URL {
        let url = directory.url.appendingPathComponent(kind.rawValue + ".zip")
        switch kind {
        case .ditto:
            let folder = directory.url.appendingPathComponent("input")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for name in ["keep", "remove", "other"] {
                let file = folder.appendingPathComponent(name)
                try Data(name.utf8).write(to: file)
                try Data("resource".utf8).write(to: URL(fileURLWithPath: file.path + "/..namedfork/rsrc"))
            }
            try directory.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, url.path])
        case .zipCrypto, .aes:
            for name in ["keep", "remove", "other"] { try Data(name.utf8).write(to: directory.url.appendingPathComponent(name)) }
            if kind == .zipCrypto {
                try directory.run("/usr/bin/zip", ["-q", "-P", "fixture-key", url.path, "keep", "remove", "other"])
                let data = try Data(contentsOf: url)
                XCTAssertNotEqual(data[6] & 8, 0, "ZipCrypto fixture must have bit 3")
            } else {
                try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-tzip", "-mem=AES256", "-pfixture-key", url.path, "keep", "remove", "other"])
            }
        default:
            try directory.run("/usr/bin/python3", ["-c", #"""
            import sys, pathlib, struct, zlib, zipfile
            p, kind = pathlib.Path(sys.argv[1]), sys.argv[2]
            if kind == 'zip64':
                with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as z:
                    for i in range(65536):
                        info = zipfile.ZipInfo('entry-%05d' % i, (2024, 1, 2, 3, 4, 6))
                        z.writestr(info, b'x')
                assert b'PK\x06\x06' in p.read_bytes()
            else:
                local, central = b'', []
                for i, name in enumerate([b'keep', b'remove', b'other']):
                    payload = bytes([65+i])*17
                    crc = zlib.crc32(payload)
                    extra = b''
                    if kind == 'unicodePath':
                        text = ('caf\u00e9-%d' % i).encode('utf8')
                        field = b'\x01' + struct.pack('<I', zlib.crc32(name)) + text
                        extra = struct.pack('<HH', 0x7075, len(field)) + field
                    flags = 8 if kind == 'unsignedDescriptor' else 0
                    offset = len(local)
                    local += struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, flags, 0, 0, 0x5821,
                        0 if flags else crc, 0 if flags else len(payload), 0 if flags else len(payload), len(name), len(extra)) + name + extra + payload
                    if flags: local += struct.pack('<III', crc, len(payload), len(payload))
                    if kind == 'gaps': local += b'gap\0\0'
                    central.append(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 0x0314, 20, flags, 0, 0, 0x5821,
                        crc, len(payload), len(payload), len(name), len(extra), 0, 0, 0, 0o100644<<16, offset) + name + extra)
                if kind == 'reordered': central.reverse()
                cd = b''.join(central)
                p.write_bytes(local + cd + struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(central), len(central), len(cd), len(local), 0))
            """#, url.path, kind.rawValue])
        }
        return url
    }
}
