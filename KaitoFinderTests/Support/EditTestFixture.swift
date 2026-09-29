import Foundation

/// 編集テストの書庫と作業ディレクトリを保持する。
nonisolated final class EditTestFixture {
    let directory: ArchiveTestDirectory
    var root: URL { directory.url }
    let archive: URL

    init(filename: String = "archive.zip", script: String = #"""
    with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for name, data in [('keep.txt', b'keep\x00bytes'), ('remove.txt', b'remove me'),
                           ('folder/', b''), ('folder/a.txt', b'alpha'), ('folder/deep/', b''),
                           ('folder/deep/b.bin', bytes(range(256))*4), ('virtual/a.txt', b'virtual a'),
                           ('virtual/deeper/b.txt', b'virtual b'), ('folderish/keep.txt', b'outside')]:
            z.writestr(name, data)
    """#) throws {
        directory = try ArchiveTestDirectory()
        archive = directory.url.appendingPathComponent(filename)
        try directory.run(ExternalTool.python3, ["-c", "import sys, zipfile, tarfile, io, struct, zlib\np=sys.argv[1]\n" + script, archive.path])
    }

    struct Record {
        let nameBytes: [UInt8]
        let local: Data
        let payload: Data
        let contents: Data
    }
}
