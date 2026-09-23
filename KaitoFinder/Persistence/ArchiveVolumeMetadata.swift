import Darwin
import Foundation
import KaitoKit
import Synchronization

nonisolated enum ArchiveVolumeMetadata {
    static let layoutKey = "com.shunnag.KaitoFinder.volume-layout"
    static let setKey = "com.shunnag.KaitoFinder.volume-set"

    struct Layout: Codable, Sendable, Equatable {
        let stem: String
        let width: Int
        let schedule: VolumePlan.Schedule
        var scheme: ArchiveVolumeSet.Scheme { .numbered(stem: stem, width: width) }
        func validate() throws {
            _ = try VolumePlan(totalLength: 1, schedule: schedule, scheme: scheme)
        }
    }
    struct Marker: Codable, Sendable, Equatable {
        let setUUID: UUID
        let generation: UInt64
        let index: Int
        let count: Int
        let totalSHA256: String
    }
    struct Publication: Codable, Sendable {
        let layout: Layout
        let setUUID: UUID
        let generation: UInt64
        let count: Int
        let totalSHA256: String
        // AppleDouble targets keep all carried xattrs here, never beside the published set.
        var attributes: [[String: Data]]? = nil
        func marker(at index: Int) -> Marker {
            Marker(setUUID: setUUID, generation: generation, index: index, count: count, totalSHA256: totalSHA256)
        }
        func validate() throws {
            try layout.validate()
            guard (1...128).contains(count), generation > 0, totalSHA256.utf8.count == 64,
                  totalSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  attributes == nil || attributes?.count == count else { throw VolumePublishError.validationFailed }
        }
    }
    struct Inspection: Sendable {
        var layout: ArchiveVolumeLayout?
        var mixed = false
        var quarantine: Data?
    }

    static func read<T: Decodable>(_ type: T.Type, key: String, at url: URL) throws -> T? {
        let directory = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: url))
        let fd = try directory.openFile(url.lastPathComponent)
        defer { close(fd) }
        let size = fgetxattr(fd, key, nil, 0, 0, 0)
        if size < 0, errno == ENOATTR || errno == ENOTSUP { return nil }
        guard size >= 0, size < 1024 * 1024 else { throw VolumePublishError.validationFailed }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { fgetxattr(fd, key, $0.baseAddress, $0.count, 0, 0) }
        guard count == size else { throw VolumePublishError.setChanged }
        return try JSONDecoder().decode(type, from: data)
    }

    static func inspect(url: URL, volumeSet: ArchiveVolumeSet?, store: ArchiveVolumeMetadataStore) throws -> Inspection {
        var result = Inspection(layout: volumeSet.map { ArchiveVolumeLayout(volumeSet: $0) })
        guard let parsed = ArchiveVolumeSet.parse(fileName: url.lastPathComponent),
              case .numbered = parsed.scheme, parsed.index == 0 else { return result }
        let parent = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: url))
        let appleDouble = try VolumePublishFS.usesAppleDouble(parent)
        let saved: ArchiveVolumeMetadataStore.Entry?
        let layout: Layout?
        do {
            saved = try appleDouble ? store.entry(for: url) : nil
            layout = try appleDouble ? saved?.publication.layout : read(Layout.self, key: layoutKey, at: url)
            try layout?.validate()
        } catch {
            result.mixed = true
            return result
        }
        if let layout {
            guard layout.scheme.fileName(forVolumeAt: 0, count: 1) == url.lastPathComponent,
                  result.layout == nil || result.layout?.scheme == layout.scheme else {
                result.mixed = true; return result
            }
            if result.layout == nil {
                let identity = try ArchiveSetIdentity.capture(url: url)
                result.layout = ArchiveVolumeLayout(scheme: layout.scheme,
                    volumes: [.init(url: url, length: identity.volumes[0].size)], openedVolumeIndex: 0)
            }
            result.layout?.savedSchedule = layout.schedule
        }
        guard let actual = result.layout else { return result }
        if let saved {
            let identity = try ArchiveSetIdentity.capture(layout: actual)
            // A replaced member on an AppleDouble volume has no per-file marker; compare the stored members.
            result.mixed = saved.members.count != identity.volumes.count || saved.publication.count != actual.volumes.count
                || !zip(saved.members, identity.volumes).allSatisfy { $0.contentEquals($1) }
            result.quarantine = saved.publication.attributes?.lazy.compactMap { $0["com.apple.quarantine"] }.first
        } else if !appleDouble {
            var first: Marker?
            for (index, volume) in actual.volumes.enumerated() {
                do {
                    guard let marker = try read(Marker.self, key: setKey, at: volume.url) else { continue }
                    if marker.index != index || marker.count != actual.volumes.count || marker.generation == 0 {
                        result.mixed = true
                    }
                    if let first, first.setUUID != marker.setUUID || first.generation != marker.generation
                        || first.count != marker.count || first.totalSHA256 != marker.totalSHA256 { result.mixed = true }
                    if first == nil { first = marker }
                } catch { result.mixed = true }
            }
        }
        return result
    }

    static func prepare(plan: VolumePlan, schedule: VolumePlan.Schedule, oldLayout: ArchiveVolumeLayout?,
                        work: URL, store: ArchiveVolumeMetadataStore, additionalQuarantine: Data?,
                        checkCancellation: () throws -> Void) throws -> Publication {
        guard case .numbered(let stem, let width) = plan.scheme else { throw VolumePublishError.unsupportedScheme }
        let parent = try VolumePublishDirectory(work.deletingLastPathComponent())
        let totalHash = try VolumePublishFS.hash(parent, work.lastPathComponent, checkCancellation: checkCancellation)
        var previous: Marker?
        var attributes: [[String: Data]]?
        if let oldLayout {
            let sourceParent = try VolumePublishDirectory(oldLayout.gateURL.deletingLastPathComponent())
            if try VolumePublishFS.usesAppleDouble(sourceParent) {
                let entry = try store.entry(for: oldLayout.gateURL)
                previous = entry?.publication.marker(at: 0)
                var values: [[String: Data]] = []
                for (index, volume) in oldLayout.volumes.enumerated() {
                    var carried = entry?.publication.attributes.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? [:]
                    carried.merge(try VolumeSplitter.Attributes(directory: sourceParent, name: volume.url.lastPathComponent).xattrs) { _, new in new }
                    carried.removeValue(forKey: layoutKey); carried.removeValue(forKey: setKey)
                    values.append(carried)
                }
                let quarantine = values.lazy.compactMap { $0["com.apple.quarantine"] }.first ?? additionalQuarantine
                attributes = plan.volumes.indices.map { index in
                    var value = values[index < values.count ? index : 0]
                    value["com.apple.quarantine"] = quarantine
                    return value
                }
            } else { previous = try read(Marker.self, key: setKey, at: oldLayout.gateURL) }
        }
        guard previous?.generation != UInt64.max else { throw VolumePublishError.validationFailed }
        return Publication(layout: Layout(stem: stem, width: width, schedule: schedule),
            setUUID: previous?.setUUID ?? UUID(), generation: (previous?.generation ?? 0) + 1,
            count: plan.volumes.count, totalSHA256: totalHash, attributes: attributes)
    }

    static func writeNative(_ publication: Publication, in directory: VolumePublishDirectory) throws {
        try publication.validate()
        guard try !VolumePublishFS.usesAppleDouble(directory) else { return }
        for index in 0..<publication.count {
            let fd = try directory.openFile(publication.layout.scheme.fileName(forVolumeAt: index, count: publication.count))
            defer { close(fd) }
            func write<T: Encodable>(_ value: T, key: String) throws {
                let bytes = try JSONEncoder().encode(value)
                let result = bytes.withUnsafeBytes { fsetxattr(fd, key, $0.baseAddress, $0.count, 0, 0) }
                guard result == 0 else { throw VolumePublishError.system(errno) }
            }
            try write(publication.marker(at: index), key: setKey)
            if index == 0 { try write(publication.layout, key: layoutKey) }
            try VolumePublishFS.sync(fd)
        }
    }
}

/// Local, flock-protected atomic JSON. Gate inode prevents a new unrelated .001 inheriting a schedule.
nonisolated final class ArchiveVolumeMetadataStore: Sendable {
    struct Entry: Codable, Sendable {
        let volumeUUID: String
        let relativeGatePath: String
        let gateInode: UInt64
        let members: [ArchiveSetIdentity.Volume]
        let publication: ArchiveVolumeMetadata.Publication
    }
    static let shared = ArchiveVolumeMetadataStore(fileURL: VolumePublishFS.support.appendingPathComponent("volume-metadata.json"))
    private static let mutex = Mutex(())
    let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    private func location(_ gate: URL) throws -> (String, String, UInt64) {
        let parent = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: gate))
        let volume = try VolumePublishFS.volumeInfo(parent), root = try VolumePublishFS.volumeRoot(parent)
        let canonicalGate = parent.url.appendingPathComponent(gate.lastPathComponent)
        guard let path = VolumePublishFS.relativePath(canonicalGate, on: root), let info = try parent.info(gate.lastPathComponent),
              info.st_mode & S_IFMT == S_IFREG else { throw VolumePublishError.setChanged }
        return (volume.uuid, path, info.st_ino)
    }
    func entry(for gate: URL) throws -> Entry? {
        let key = try location(gate)
        return try access { directory in
            try read(directory).first { $0.volumeUUID == key.0 && $0.relativeGatePath == key.1 && $0.gateInode == key.2 }
        }
    }
    func save(_ publication: ArchiveVolumeMetadata.Publication, layout: ArchiveVolumeLayout) throws {
        try publication.validate()
        let key = try location(layout.gateURL), identity = try ArchiveSetIdentity.capture(layout: layout)
        let entry = Entry(volumeUUID: key.0, relativeGatePath: key.1, gateInode: key.2,
                          members: identity.volumes, publication: publication)
        try access { directory in
            var values = try read(directory)
            values.removeAll { $0.volumeUUID == key.0 && $0.relativeGatePath == key.1 }
            values.append(entry)
            let bytes = try JSONEncoder().encode(values), name = ".volume-metadata-" + UUID().uuidString
            let fd = try directory.openFile(name, flags: O_WRONLY | O_CREAT | O_EXCL)
            defer { close(fd); _ = unlinkat(directory.fd, name, 0) }
            try VolumePublishFS.write(fd, data: bytes, offset: 0)
            try VolumePublishFS.sync(fd, full: true)
            guard renameat(directory.fd, name, directory.fd, fileURL.lastPathComponent) == 0 else { throw VolumePublishError.system(errno) }
            try directory.sync(full: true)
        }
    }
    private func access<T>(_ body: (VolumePublishDirectory) throws -> T) throws -> T {
        try Self.mutex.withLock { _ in
            let directory = try VolumePublishFS.supportDirectory(fileURL.deletingLastPathComponent())
            let fd = try directory.openFile(fileURL.lastPathComponent + ".lock", flags: O_RDWR | O_CREAT)
            defer { close(fd) }
            while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw VolumePublishError.system(errno) } }
            return try body(directory)
        }
    }
    private func read(_ directory: VolumePublishDirectory) throws -> [Entry] {
        guard let info = try directory.info(fileURL.lastPathComponent) else { return [] }
        guard info.st_size >= 0, info.st_size < 16 * 1024 * 1024 else { throw VolumePublishError.validationFailed }
        let fd = try directory.openFile(fileURL.lastPathComponent)
        defer { close(fd) }
        return try JSONDecoder().decode([Entry].self, from: VolumePublishFS.read(fd, length: Int(info.st_size), offset: 0))
    }
}
