import CryptoKit
import Darwin
import Foundation
import KaitoKit
import Synchronization

nonisolated struct VolumePublishProcessIdentity: Codable, Sendable, Equatable {
    let bootSession: String
    let pid: Int32
    let startSeconds: Int64
    let startMicroseconds: Int64

    static func capture(pid: Int32 = getpid()) throws -> Self? {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 0 else {
            throw VolumePublishError.system(errno)
        }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else {
            throw VolumePublishError.system(errno)
        }
        let boot = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &process, &size, nil, 0) == 0 else {
            throw VolumePublishError.system(errno)
        }
        guard size > 0, Int32(process.kp_proc.p_stat) != SZOMB else { return nil }
        return Self(bootSession: boot, pid: pid,
                    startSeconds: Int64(process.kp_proc.p_starttime.tv_sec),
                    startMicroseconds: Int64(process.kp_proc.p_starttime.tv_usec))
    }
}

nonisolated struct VolumePublishJournalRecord: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, retiring, placing, placed, done, abandoned }
    struct OldVolume: Codable, Sendable {
        let name: String
        let inode: UInt64
        let size: UInt64
        let mode: UInt16
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let sha256: String?

        init(_ volume: ArchiveSetIdentity.Volume, sha256: String?) {
            name = volume.fileName; inode = volume.inode; size = volume.size; mode = volume.mode
            modificationSeconds = volume.modificationSeconds; modificationNanoseconds = volume.modificationNanoseconds
            self.sha256 = sha256
        }

        func matches(in directory: VolumePublishDirectory, useHash: Bool) throws -> Bool {
            guard let info = try directory.info(name), info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, UInt64(info.st_size) == size else { return false }
            if useHash {
                // FAT の inode と 2 秒単位 mtime は参考値。全 byte を読んでから判断する。
                guard let sha256 else { return false }
                return try VolumePublishFS.hash(directory, name) == sha256
            }
            return info.st_ino == inode && Int64(info.st_mtimespec.tv_sec) == modificationSeconds
                && Int64(info.st_mtimespec.tv_nsec) == modificationNanoseconds
        }
    }
    struct NewVolume: Codable, Sendable, Equatable {
        let name: String
        let length: UInt64
        let sha256: String

        func matches(in directory: VolumePublishDirectory) throws -> Bool {
            guard let info = try directory.info(name), info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, UInt64(info.st_size) == length else { return false }
            return try VolumePublishFS.hash(directory, name) == sha256
        }
    }

    var phase: Phase
    let schemeTag: String
    let stagingName: String
    let stem: String
    let width: Int
    let volumeUUID: String // 診断用。再マウント後の st_dev とは比較しない。
    let hashesOldVolumes: Bool
    let usesExclusiveRenameFallback: Bool
    let oldVolumes: [OldVolume]
    var newVolumes: [NewVolume]
    let oldGate: String?
    let newGate: String
    let workName: String
    var totalLength: UInt64
    let createdAt: Date
    let appVersion: String
    var owner: VolumePublishProcessIdentity?

    var scheme: ArchiveVolumeSet.Scheme { .numbered(stem: stem, width: width) }
    var nextName: String { scheme.fileName(forVolumeAt: newVolumes.count, count: newVolumes.count + 1) }

    func validate(stagingName: String) throws {
        guard schemeTag == "numbered", self.stagingName == stagingName, stagingName.hasPrefix(VolumePublishFS.stagingPrefix),
              VolumePublishFS.isName(stagingName), VolumePublishFS.isName(stem), VolumePublishFS.isName(workName),
              width >= 3, width <= 255, stem.utf8.count + 1 + width <= 255, oldVolumes.count <= ReadLimits().maxVolumeCount,
              newVolumes.count <= ReadLimits().maxVolumeCount,
              newGate == scheme.fileName(forVolumeAt: 0, count: 1),
              oldGate == (oldVolumes.isEmpty ? nil : newGate) else { throw VolumePublishError.journalUnreadable }
        for (index, volume) in oldVolumes.enumerated() {
            guard volume.name == scheme.fileName(forVolumeAt: index, count: oldVolumes.count),
                  volume.mode & S_IFMT == S_IFREG,
                  !hashesOldVolumes || Self.validHash(volume.sha256 ?? "") else {
                throw VolumePublishError.journalUnreadable
            }
        }
        var sum: UInt64 = 0
        for (index, volume) in newVolumes.enumerated() {
            let addition = sum.addingReportingOverflow(volume.length)
            guard volume.name == scheme.fileName(forVolumeAt: index, count: newVolumes.count),
                  volume.length > 0, Self.validHash(volume.sha256), !addition.overflow else {
                throw VolumePublishError.journalUnreadable
            }
            sum = addition.partialValue
        }
        guard sum == totalLength, sum <= UInt64(Int64.max),
              !newVolumes.isEmpty || phase == .prepared || phase == .abandoned else {
            throw VolumePublishError.journalUnreadable
        }
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case phase, stagingName, stem, width, volumeUUID, hashesOldVolumes, usesExclusiveRenameFallback
        case oldVolumes, newVolumes, oldGate, newGate, workName, totalLength, createdAt, appVersion, owner
        case schemeTag = "scheme"
    }
}

/// 固定長の二重スロット。payload の上書きが途切れても、直前の有効な世代が残る。
nonisolated final class VolumePublishJournal: Sendable {
    static let fileName = "journal"
    static let slotSize = 256 * 1024
    static let headerSize = 64
    private static let magic = Data("KFVOLJ01".utf8)
    private static let liveOwners = Mutex<Set<String>>([])
    private let ownershipKey: String
    private let descriptor: Mutex<Int32>
    private let hasWritten = Mutex(false)
    let usesOwnerFallback: Bool

    init(staging: VolumePublishDirectory, create: Bool, lock: @Sendable (Int32, Int32) -> Int32 = { flock($0, $1) },
         processIdentity: @Sendable (Int32) throws -> VolumePublishProcessIdentity? = { try VolumePublishProcessIdentity.capture(pid: $0) }) throws {
        let fd = try staging.openFile(Self.fileName, flags: O_RDWR | (create ? O_CREAT | O_EXCL : 0))
        do {
            var identity = stat()
            guard fstat(fd, &identity) == 0, identity.st_nlink == 1 else { throw VolumePublishError.journalUnreadable }
            let key = String(identity.st_dev) + ":" + String(identity.st_ino)
            var fallback = false
            while lock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                if errno == ENOTSUP || errno == EOPNOTSUPP { fallback = true; break }
                if errno == EWOULDBLOCK { throw VolumePublishError.ownerAlive }
                throw VolumePublishError.system(errno)
            }
            if create {
                var allocation = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG), fst_posmode: F_PEOFPOSMODE,
                                         fst_offset: 0, fst_length: off_t(2 * Self.slotSize), fst_bytesalloc: 0)
                if fcntl(fd, F_PREALLOCATE, &allocation) != 0 {
                    allocation.fst_flags = UInt32(F_ALLOCATEALL)
                    guard fcntl(fd, F_PREALLOCATE, &allocation) == 0 else { throw VolumePublishError.system(errno) }
                }
                guard ftruncate(fd, off_t(2 * Self.slotSize)) == 0 else { throw VolumePublishError.system(errno) }
            } else if fallback {
                let record = try Self.latest(fd).record
                guard let owner = record.owner else { throw VolumePublishError.journalUnreadable }
                if try processIdentity(owner.pid) == owner,
                   owner.pid != getpid() || Self.liveOwners.withLock({ $0.contains(key) }) {
                    throw VolumePublishError.ownerAlive
                }
            }
            guard Self.liveOwners.withLock({ $0.insert(key).inserted }) else { throw VolumePublishError.ownerAlive }
            ownershipKey = key
            descriptor = Mutex(fd)
            usesOwnerFallback = fallback
            hasWritten.withLock { $0 = !create }
        } catch { close(fd); throw error }
    }

    deinit { release() }
    func release() {
        descriptor.withLock { fd in
            if fd >= 0 {
                close(fd); fd = -1
                _ = Self.liveOwners.withLock { $0.remove(ownershipKey) }
            }
        }
    }

    func read() throws -> VolumePublishJournalRecord { try descriptor.withLock { try Self.latest($0).record } }

    func verifyPath(_ staging: VolumePublishDirectory) throws {
        try descriptor.withLock { fd in
            var info = stat()
            guard fstat(fd, &info) == 0, let current = try staging.info(Self.fileName),
                  VolumePublishFS.sameFile(info, current) else { throw VolumePublishError.setChanged }
        }
    }

    /// S0 の未解決検出用。所有者が生存中でも journal を読むだけなら待たない。
    static func inspect(_ staging: VolumePublishDirectory) throws -> VolumePublishJournalRecord {
        let fd = try staging.openFile(fileName)
        defer { close(fd) }
        return try latest(fd).record
    }

    func write(_ record: VolumePublishJournalRecord) throws {
        try record.validate(stagingName: record.stagingName)
        let payload = try JSONEncoder().encode(record)
        guard payload.count <= Self.slotSize - Self.headerSize else { throw VolumePublishError.journalTooLarge }
        try descriptor.withLock { fd in
            guard fd >= 0 else { throw VolumePublishError.alreadyUsed }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size == off_t(2 * Self.slotSize) else {
                throw VolumePublishError.journalUnreadable
            }
            let a = try Self.slot(fd, index: 0), b = try Self.slot(fd, index: 1)
            if a == nil, b == nil, hasWritten.withLock({ $0 }) { throw VolumePublishError.journalUnreadable }
            let sequence = max(a?.sequence ?? 0, b?.sequence ?? 0)
            guard sequence < .max else { throw VolumePublishError.journalTooLarge }
            let index = (a?.sequence ?? 0) <= (b?.sequence ?? 0) ? 0 : 1
            var bytes = Self.magic
            Self.append(UInt32(1), to: &bytes)
            Self.append(UInt32(payload.count), to: &bytes)
            Self.append(sequence + 1, to: &bytes)
            bytes.append(contentsOf: SHA256.hash(data: payload))
            bytes.append(Data(count: Self.headerSize - bytes.count))
            bytes.append(payload)
            bytes.append(Data(count: Self.slotSize - bytes.count))
            try VolumePublishFS.write(fd, data: bytes, offset: UInt64(index * Self.slotSize))
            try VolumePublishFS.sync(fd, full: true)
            hasWritten.withLock { $0 = true }
        }
    }

    private static func append<T: FixedWidthInteger>(_ number: T, to data: inout Data) {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private static func integer(_ data: Data, _ start: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | (UInt64(data[start + $1]) << (8 * $1)) }
    }
    private static func slot(_ fd: Int32, index: Int) throws -> (sequence: UInt64, record: VolumePublishJournalRecord)? {
        guard let bytes = try? VolumePublishFS.read(fd, length: slotSize, offset: UInt64(index * slotSize)) else { return nil }
        guard bytes.prefix(8) == magic, integer(bytes, 8, 4) == 1 else { return nil }
        let length = Int(integer(bytes, 12, 4)), sequence = integer(bytes, 16, 8)
        guard length <= slotSize - headerSize, length > 0, sequence > 0 else { return nil }
        let payload = bytes.subdata(in: headerSize..<(headerSize + length))
        guard Data(SHA256.hash(data: payload)) == bytes.subdata(in: 24..<56),
              let record = try? JSONDecoder().decode(VolumePublishJournalRecord.self, from: payload) else { return nil }
        return (sequence, record)
    }
    private static func latest(_ fd: Int32) throws -> (sequence: UInt64, record: VolumePublishJournalRecord) {
        let a = try slot(fd, index: 0), b = try slot(fd, index: 1)
        guard let result = [a, b].compactMap({ $0 }).max(by: { $0.sequence < $1.sequence }) else {
            throw VolumePublishError.journalUnreadable
        }
        return result
    }
}
