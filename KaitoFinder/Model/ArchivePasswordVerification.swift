import Foundation
import KaitoKit
import Synchronization

nonisolated enum ArchivePasswordVerification {
    #if DEBUG
    enum Execution: Sendable { case automatic, serial, parallel }
    enum Event: Sendable {
        case workers(Int)
        case willVerify(Int)
        case didRead(Int, Int)
    }
    static let execution = TaskLocal<Execution>(wrappedValue: .automatic)
    static let observer = TaskLocal<(@Sendable (Event) -> Void)?>(wrappedValue: nil)
    #endif

    private struct State {
        let reader: ArchiveReader
        var outcomes: [Result<Int, any Error>] = []
    }

    private final class Worker: Sendable {
        let range: Range<Int>
        let state: Mutex<State>

        init(reader: sending ArchiveReader, range: Range<Int>) {
            self.range = range
            state = Mutex(State(reader: reader))
        }
    }

    static func workerCount(entries: [ArchiveEntry], requested: Int, hasPassword: Bool) -> Int {
        // 不明サイズの累積制限と solid の復号状態は直列で維持する。
        guard hasPassword, entries.allSatisfy({ $0.uncompressedSize != nil && $0.solidGroup < 0 }) else { return 1 }
        #if DEBUG
        switch execution.get() {
        case .serial: return 1
        case .parallel: return max(1, min(requested, entries.count))
        case .automatic: break
        }
        #endif
        let minimumBytes: UInt64 = 8 * 1024 * 1024
        let bytes = entries.reduce(UInt64(0)) { min(minimumBytes, $0 + min(minimumBytes, $1.uncompressedSize ?? 0)) }
        // 小項目が多数ある AES では本文サイズより鍵導出の件数が支配する。
        guard entries.count >= 64 || bytes >= minimumBytes else { return 1 }
        return max(1, min(requested, entries.count))
    }

    static func verify(_ entries: [ArchiveEntry], using reader: ArchiveReader, workers requested: Int,
                       progress: Progress? = nil) throws -> Set<Int> {
        guard !entries.isEmpty else { return [] }
        func checkCancellation() throws {
            try Task.checkCancellation()
            if progress?.isCancelled == true { throw CancellationError() }
        }
        try checkCancellation()
        let count = workerCount(entries: entries, requested: requested, hasPassword: reader.password != nil)
        #if DEBUG
        let observer = observer.get()
        #endif
        guard count > 1 else {
            return try serial(entries, reader: reader, checkCancellation: checkCancellation)
        }

        // 既知の鍵を引き継ぐため、worker から password provider は呼ばれない。
        assert(reader.password != nil)
        var workers: [Worker] = []
        do {
            for index in 0..<count {
                try checkCancellation()
                workers.append(try Worker(reader: reader.reopen(),
                    range: (entries.count * index / count)..<(entries.count * (index + 1) / count)))
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // 複製できない形式も元の reader の検証結果に従う。
            return try serial(entries, reader: reader, checkCancellation: checkCancellation)
        }
        #if DEBUG
        observer?(.workers(count))
        #endif
        let stopped = Mutex(false), group = DispatchGroup()
        for worker in workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                worker.state.withLock { state in
                    assert(state.reader.password != nil)
                    var buffer = [UInt8](repeating: 0, count: 128 * 1024)
                    #if DEBUG
                    var bytes: UInt64 = 0
                    defer { ArchiveSession.passwordVerificationBytes.withLock { $0 += bytes } }
                    #endif
                    func checkCancellation() throws {
                        if progress?.isCancelled == true || stopped.withLock({ $0 }) { throw CancellationError() }
                    }
                    state.outcomes.reserveCapacity(worker.range.count)
                    for position in worker.range {
                        let entry = entries[position]
                        do {
                            try checkCancellation()
                            #if DEBUG
                            observer?(.willVerify(entry.index))
                            #endif
                            try checkCancellation()
                            try ExtractionService.consume(state.reader.stream(entry), buffer: &buffer,
                                                          checkCancellation: checkCancellation) { chunk in
                                #if DEBUG
                                bytes += UInt64(chunk.count)
                                observer?(.didRead(entry.index, chunk.count))
                                #endif
                            }
                            state.outcomes.append(.success(entry.index))
                        } catch is CancellationError {
                            stopped.withLock { $0 = true }
                            return
                        } catch KaitoError.wrongPassword {
                            state.outcomes.append(.failure(KaitoError.wrongPassword))
                        } catch {
                            state.outcomes.append(.failure(error))
                            return
                        }
                    }
                }
            }
        }
        // GCD に Task の取消しを伝え、全 worker の終了まで reader を保持する。
        while group.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            if Task.isCancelled || progress?.isCancelled == true { stopped.withLock { $0 = true } }
        }
        try checkCancellation()
        if stopped.withLock({ $0 }) { throw CancellationError() }
        var verified = Set<Int>(), wrongPassword = false
        // 完了順ではなく、連続する batch と各 entry の書庫順でエラーを選ぶ。
        for worker in workers {
            try checkCancellation()
            try worker.state.withLock { state in
                for outcome in state.outcomes {
                    do { verified.insert(try outcome.get()) }
                    catch KaitoError.wrongPassword { wrongPassword = true }
                }
            }
        }
        try checkCancellation()
        return try finish(verified, wrongPassword: wrongPassword)
    }

    private static func serial(_ entries: [ArchiveEntry], reader: ArchiveReader,
                               checkCancellation: () throws -> Void) throws -> Set<Int> {
        #if DEBUG
        observer.get()?(.workers(1))
        #endif
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var verified = Set<Int>(), wrongPassword = false
        for entry in entries {
            do {
                try checkCancellation()
                try consume(entry, reader: reader, buffer: &buffer, checkCancellation: checkCancellation)
                verified.insert(entry.index)
            } catch KaitoError.wrongPassword { wrongPassword = true }
        }
        return try finish(verified, wrongPassword: wrongPassword)
    }

    private static func consume(_ entry: ArchiveEntry, reader: ArchiveReader, buffer: inout [UInt8],
                                checkCancellation: () throws -> Void) throws {
        #if DEBUG
        let observer = observer.get()
        observer?(.willVerify(entry.index))
        #endif
        try checkCancellation()
        // ZipCrypto の短い照合値だけでなく、CRC / HMAC まで読む。
        try ExtractionService.consume(reader.stream(entry), buffer: &buffer, checkCancellation: checkCancellation) { bytes in
            #if DEBUG
            ArchiveSession.passwordVerificationBytes.withLock { $0 += UInt64(bytes.count) }
            observer?(.didRead(entry.index, bytes.count))
            #endif
        }
    }

    private static func finish(_ verified: Set<Int>, wrongPassword: Bool) throws -> Set<Int> {
        if wrongPassword {
            guard verified.isEmpty else {
                throw ExtractionFailure.refused(String(localized: "選択した項目には異なるパスワードが設定されています。同じパスワードの項目ごとに展開してください。"))
            }
            throw KaitoError.wrongPassword
        }
        return verified
    }
}
