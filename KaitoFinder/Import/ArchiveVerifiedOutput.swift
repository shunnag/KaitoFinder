import Darwin
import Foundation
import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit
import Synchronization

/// 検証した記述子を公開後まで保持し、パスの差し替えと区別する。
nonisolated final class ArchiveVerifiedFileSource: ByteSourceFileIdentityProviding {
    let descriptor: Int32
    let length: UInt64
    let identity: ArchiveSetIdentity
    let fileIdentity: ArchiveFileIdentity

    init(url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ExtractionFailure.system(errno) }
        do {
            fileIdentity = try ArchiveFileIdentity.capture(descriptor: fd)
            identity = ArchiveSetIdentity(file: fileIdentity, url: url)
            length = fileIdentity.size
            descriptor = fd
        } catch { Darwin.close(fd); throw error }
    }

    deinit { Darwin.close(descriptor) }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        guard offset <= UInt64(Int64.max) else { throw ExtractionFailure.system(EINVAL) }
        let count = Int(min(UInt64(buffer.count), length - offset))
        while true {
            let count = pread(descriptor, buffer.baseAddress!, count, off_t(offset))
            if count >= 0 { return count }
            if errno != EINTR { throw ExtractionFailure.system(errno) }
        }
    }

    func isUnchanged() -> Bool {
        (try? ArchiveFileIdentity.capture(descriptor: descriptor).contentEquals(fileIdentity)) == true
    }

    func currentFileIdentity() throws -> ByteSourceFileIdentity {
        let current = try ArchiveFileIdentity.capture(descriptor: descriptor)
        return ByteSourceFileIdentity(device: current.device, inode: current.inode, size: current.size,
            modificationSeconds: current.modificationSeconds, modificationNanoseconds: current.modificationNanoseconds)
    }
}

nonisolated final class ArchiveVerifiedOutputSink {
    var output: ArchiveVerifiedOutput?
    var publishedMode: ArchiveCapabilities.Mode?

    func take() -> ArchiveVerifiedOutput? {
        defer { output = nil }
        return output
    }
}

nonisolated final class ArchiveVerifiedOutput {
    let identity: ArchiveSetIdentity
    var reader: ArchiveReader?
    let source: ArchiveVerifiedFileSource
    let hint: URL
    var verificationPassword: String?
    let format: GyoshukuKit.ArchiveFormat
    #if DEBUG
    var didReleaseForTesting: (@Sendable () -> Void)?
    deinit { didReleaseForTesting?() }
    #endif

    init(identity: ArchiveSetIdentity, reader: ArchiveReader, source: ArchiveVerifiedFileSource,
         hint: URL, verificationPassword: String?, format: GyoshukuKit.ArchiveFormat) {
        self.identity = identity
        self.reader = reader
        self.source = source
        self.hint = hint
        self.verificationPassword = verificationPassword
        self.format = format
    }

    static func usesPublishedName(_ archive: URL, format: GyoshukuKit.ArchiveFormat) -> Bool {
        if let parsed = ArchiveVolumeSet.parse(fileName: archive.lastPathComponent) {
            switch parsed.scheme {
            case .numbered: return false
            case .zipSpanned: if parsed.index >= 0 { return false }
            }
        }
        if archive.pathExtension.lowercased() == "cue" { return false }
        switch format {
        case .zip, .sevenZip: return true
        case .tar, .tarGzip, .tarBzip2, .tarXZ, .lha:
            return ArchiveCreationPlan.hasAcceptedExtension(archive, for: format)
        }
    }

    // 新規 reader だけを排他的に移し、session の reader は別 thread と共有しない。
    static func openAfterPublication(url: URL, options: ReaderOptions) throws -> sending ArchiveReader {
        let transfer = try VolumePublishUncancelled.run {
            ReaderTransfer(try ArchiveReader.open(url: url, options: options))
        }
        return transfer.reader.withLock { reader in
            let result = reader!
            reader = nil
            return result
        }
    }

    private final class ReaderTransfer: Sendable {
        let reader: Mutex<ArchiveReader?>
        init(_ reader: sending ArchiveReader) { self.reader = Mutex(reader) }
    }
}

nonisolated enum ArchiveReaderAdoption: Sendable, Equatable {
    case adopted, fallback(Reason)
    enum Reason: Sendable { case noOutput, hint, identity, descriptor, splitSibling, password, format, reopenFailed }
}
