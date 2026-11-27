import Darwin
import Foundation
import KaitoKit
import Synchronization

/// One budget for an extraction, including independent GCD workers.
nonisolated final class ExtractionOutputBudget: Sendable {
    struct File {
        let device: dev_t
        let maximum: UInt64
        let isStaged: Bool
        var size: UInt64 = 0
    }

    private struct Volume {
        let reserve: UInt64
        let maximum: UInt64
        var pending: UInt64 = 0
    }

    private struct State {
        var archiveRemaining: UInt64
        var totalRemaining: UInt64
        var volumes: [dev_t: Volume] = [:]
    }

    private let state: Mutex<State>
    private let available: @Sendable (Int32) throws -> UInt64
    private let maximum: @Sendable (Int32) throws -> UInt64?

    init(archiveLimit: UInt64, totalLimit: UInt64 = FinderArchiveLimits.total,
         available: @escaping @Sendable (Int32) throws -> UInt64 = ExtractionVolume.availableBytes,
         maximum: @escaping @Sendable (Int32) throws -> UInt64? = ExtractionVolume.maximumFileSize) {
        state = Mutex(State(archiveRemaining: archiveLimit, totalRemaining: totalLimit))
        self.available = available
        self.maximum = maximum
    }

    private func reserve(for free: UInt64) -> UInt64 { min(1 << 30, free / 20) }

    private func volume(on fd: Int32, device: dev_t, free: UInt64, state: inout State) throws -> Volume {
        if let existing = state.volumes[device] { return existing }
        let value = Volume(reserve: reserve(for: free), maximum: min(try maximum(fd) ?? .max, FinderArchiveLimits.entry))
        state.volumes[device] = value
        return value
    }

    func usableCapacity(on fd: Int32) throws -> UInt64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ExtractionFailure.system(errno) }
        return try state.withLock { state in
            let free = try available(fd)
            let volume = try volume(on: fd, device: info.st_dev, free: free, state: &state)
            return free >= volume.reserve ? free - volume.reserve : 0
        }
    }

    private func checkSpace(_ count: UInt64, available: UInt64, volume: Volume) throws {
        guard available >= volume.reserve, available - volume.reserve >= volume.pending,
              count <= available - volume.reserve - volume.pending else { throw ExtractionFailure.system(ENOSPC) }
    }

    func begin(on fd: Int32, declared: UInt64, isStaged: Bool) throws -> File {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ExtractionFailure.system(errno) }
        return try state.withLock { state in
            guard declared <= state.totalRemaining, isStaged || declared <= state.archiveRemaining else {
                throw KaitoError.limitExceeded("extraction output")
            }
            let free = try available(fd)
            let volume = try volume(on: fd, device: info.st_dev, free: free, state: &state)
            guard declared <= volume.maximum else { throw ExtractionFailure.system(EFBIG) }
            try checkSpace(declared, available: free, volume: volume)
            return File(device: info.st_dev, maximum: volume.maximum, isStaged: isStaged)
        }
    }

    /// Pending bytes cover writes admitted on this device that have not returned yet.
    func writing(_ bytes: Int, on fd: Int32, file: inout File, body: () throws -> Void) throws {
        let count = UInt64(bytes)
        guard count <= file.maximum - file.size else { throw ExtractionFailure.system(EFBIG) }
        let device = file.device
        try state.withLock { state in
            guard count <= state.totalRemaining, file.isStaged || count <= state.archiveRemaining else {
                throw KaitoError.limitExceeded("extraction output")
            }
            try checkSpace(count, available: available(fd), volume: state.volumes[device]!)
            state.volumes[device]!.pending += count
            state.totalRemaining -= count
            if !file.isStaged { state.archiveRemaining -= count }
        }
        defer { state.withLock { $0.volumes[device]!.pending -= count } }
        try body()
        file.size += count
    }
}
