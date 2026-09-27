import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

#if DEBUG
nonisolated final class ArchivePasswordVerificationTests: XCTestCase {
    private enum Outcome: Equatable {
        case verified(Set<Int>), kaito(KaitoError), refused(String), cancelled, other(String)
    }

    private final class Provider: PasswordProvider {
        let calls = Mutex(0)
        func password(for format: KaitoKit.ArchiveFormat) throws -> String? {
            calls.withLock { $0 += 1 }
            return "known"
        }
    }

    private func archive(_ method: ZipEncryption, in directory: ArchiveTestDirectory,
                         password: String = "known", count: Int = 16, size: Int = 4096) throws -> URL {
        let url = directory.url.appendingPathComponent(UUID().uuidString + ".zip")
        let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .stored,
            password: password, zipEncryption: method, compressionThreads: 1))
        let data = Data(repeating: 0x5a, count: size)
        for index in 0..<count {
            try writer.add(data: data, as: "entry-\(index)", modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        try writer.finish()
        return url
    }

    private func outcome(_ body: () throws -> Set<Int>) -> Outcome {
        do { return .verified(try body()) }
        catch let error as KaitoError { return .kaito(error) }
        catch ExtractionFailure.refused(let reason) { return .refused(reason) }
        catch is CancellationError { return .cancelled }
        catch { return .other(String(reflecting: error)) }
    }

    private func verify(_ url: URL, password: String? = "known", execution: ArchivePasswordVerification.Execution,
                        provider: Provider? = nil, progress: Progress? = nil) throws -> Outcome {
        let reader = try ArchiveReader.open(url: url, options: .init(password: password, passwordProvider: provider))
        return ArchivePasswordVerification.execution.withValue(execution) {
            outcome { try ArchivePasswordVerification.verify(reader.entries, using: reader, workers: 4, progress: progress) }
        }
    }

    @discardableResult private func compare(_ url: URL, password: String = "known",
                                            file: StaticString = #filePath, line: UInt = #line) throws -> Outcome {
        let serial = try verify(url, password: password, execution: .serial)
        let parallel = try verify(url, password: password, execution: .parallel)
        XCTAssertEqual(serial, parallel, file: file, line: line)
        return serial
    }

    private struct Record {
        let local: Int, central: Int, data: Range<Int>
    }

    private func integer(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }

    private func records(_ data: Data) -> [Record] {
        var offset = integer(data, data.count - 6, 4), records: [Record] = []
        for _ in 0..<integer(data, data.count - 12, 2) {
            let local = integer(data, offset + 42, 4)
            let start = local + 30 + integer(data, local + 26, 2) + integer(data, local + 28, 2)
            records.append(.init(local: local, central: offset,
                data: start..<(start + integer(data, offset + 20, 4))))
            offset += 46 + integer(data, offset + 28, 2) + integer(data, offset + 30, 2) + integer(data, offset + 32, 2)
        }
        return records
    }

    private func unsupported(_ data: inout Data, record: Record, method: Int) throws {
        func replace(_ offset: Int) { data[offset] = UInt8(truncatingIfNeeded: method); data[offset + 1] = UInt8(method >> 8) }
        if integer(data, record.local + 8, 2) == 99 {
            for (offset, header, nameOffset, extraOffset) in [(record.local, 30, 26, 28), (record.central, 46, 28, 30)] {
                var start = offset + header + integer(data, offset + nameOffset, 2)
                let end = start + integer(data, offset + extraOffset, 2)
                while start < end, integer(data, start, 2) != 0x9901 { start += 4 + integer(data, start + 2, 2) }
                XCTAssertLessThan(start, end)
                replace(start + 9)
            }
        } else {
            replace(record.local + 8)
            replace(record.central + 10)
        }
    }

    func testAESAndZipCryptoReturnIdenticalSetsAndByteCounts() throws {
        let directory = try ArchiveTestDirectory()
        for method in [ZipEncryption.aes256, .zipCrypto] {
            let url = try archive(method, in: directory, count: 68, size: 1)
            for execution in [ArchivePasswordVerification.Execution.serial, .parallel, .automatic] {
                let provider = Provider(), counts = Mutex<[Int]>([])
                let before = ArchiveSession.passwordVerificationBytes.withLock { $0 }
                let result = try ArchivePasswordVerification.observer.withValue({ event in
                    if case .workers(let count) = event { counts.withLock { $0.append(count) } }
                }) { try verify(url, execution: execution, provider: provider) }
                XCTAssertEqual(result, .verified(Set(0..<68)))
                XCTAssertEqual(ArchiveSession.passwordVerificationBytes.withLock { $0 } - before, 68)
                XCTAssertEqual(provider.calls.withLock { $0 }, 0)
                XCTAssertEqual(counts.withLock { $0 }, execution == .serial ? [1] : [4])
            }
        }
    }

    func testMixedPasswordsAndAllWrongMatchSerial() throws {
        let directory = try ArchiveTestDirectory()
        for method in [ZipEncryption.aes256, .zipCrypto] {
            let url = try archive(method, in: directory)
            XCTAssertEqual(try compare(url, password: "incorrect"), .kaito(.wrongPassword))
            var data = try Data(contentsOf: url)
            let different = try Data(contentsOf: archive(method, in: directory, password: "different"))
            let record = records(data)[7], replacement = records(different)[7]
            data.replaceSubrange(record.data, with: different[replacement.data])
            try data.write(to: url)
            let refusal = Outcome.refused(String(localized: "選択した項目には異なるパスワードが設定されています。同じパスワードの項目ごとに展開してください。"))
            XCTAssertEqual(try compare(url), refusal)
            XCTAssertEqual(try compare(url, password: "different"), refusal)
        }
    }

    func testMiddleAuthenticationOrCRCFailureMatchesSerial() throws {
        let directory = try ArchiveTestDirectory()
        for method in [ZipEncryption.aes256, .zipCrypto] {
            let url = try archive(method, in: directory)
            var data = try Data(contentsOf: url)
            data[records(data)[7].data.upperBound - 1] ^= 0xff
            try data.write(to: url)
            let result = try compare(url)
            if case .verified = result { XCTFail("Corruption must fail verification") }
            if case .other = result { XCTFail("Expected a typed integrity error or password refusal") }
        }
    }

    func testFirstUnsupportedMethodInArchiveOrderWinsOverWrongPasswords() throws {
        let directory = try ArchiveTestDirectory()
        for method in [ZipEncryption.aes256, .zipCrypto] {
            let url = try archive(method, in: directory)
            var data = try Data(contentsOf: url)
            let entries = records(data)
            let wrong = try Data(contentsOf: archive(method, in: directory, password: "different"))
            data.replaceSubrange(entries[0].data, with: wrong[records(wrong)[0].data])
            try unsupported(&data, record: entries[7], method: 65534)
            try unsupported(&data, record: entries[12], method: 65535)
            try data.write(to: url)
            // 後方の batch が先に失敗しても、先頭側のエラーを返す。
            let result = try ArchivePasswordVerification.observer.withValue({ event in
                if case .willVerify(7) = event { Thread.sleep(forTimeInterval: 0.03) }
            }) { try compare(url) }
            XCTAssertEqual(result, .kaito(.unsupportedMethod("65534")))
        }
    }

    func testWorkerThresholdsAndMissingPasswordStaySerial() throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(.aes256, in: directory, count: 64, size: 1)
        let small = try ArchiveReader.open(url: url)
        XCTAssertEqual(ArchivePasswordVerification.workerCount(entries: Array(small.entries.prefix(63)), requested: 4, hasPassword: true), 1)
        XCTAssertEqual(ArchivePasswordVerification.workerCount(entries: small.entries, requested: 4, hasPassword: true), 4)
        XCTAssertEqual(ArchivePasswordVerification.workerCount(entries: small.entries, requested: 0, hasPassword: true), 1)
        let large = try ArchiveReader.open(url: archive(.aes256, in: directory, count: 2, size: 4 * 1024 * 1024))
        XCTAssertEqual(ArchivePasswordVerification.workerCount(entries: large.entries, requested: 4, hasPassword: true), 2)
        let counts = Mutex<[Int]>([])
        let result = try ArchivePasswordVerification.observer.withValue({ event in
            if case .workers(let count) = event { counts.withLock { $0.append(count) } }
        }) { try verify(url, password: nil, execution: .parallel) }
        XCTAssertEqual(result, .kaito(.passwordRequired))
        XCTAssertEqual(counts.withLock { $0 }, [1])
    }

    func testProgressCancellationDuringStreamingMatchesSerial() throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(.aes256, in: directory, size: 512 * 1024)
        for execution in [ArchivePasswordVerification.Execution.serial, .parallel] {
            let progress = Progress(), bytes = Mutex(0)
            let result = try ArchivePasswordVerification.observer.withValue({ event in
                if case .didRead(_, let count) = event {
                    bytes.withLock { $0 += count }
                    progress.cancel()
                }
            }) { try verify(url, execution: execution, progress: progress) }
            XCTAssertEqual(result, .cancelled)
            XCTAssertGreaterThan(bytes.withLock { $0 }, 0)
            XCTAssertLessThanOrEqual(bytes.withLock { $0 }, 4 * 128 * 1024)
        }
    }

    func testTaskCancellationStopsWorkersAndDoesNotPublishVerification() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(.aes256, in: directory, count: 32, size: 512 * 1024)
        for execution in [ArchivePasswordVerification.Execution.serial, .parallel] {
            let session = try ArchiveSession(url: url, password: "known", writerOptions: { _ in .init(compressionThreads: 4) })
            let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let release = DispatchSemaphore(value: 0)
            let paused = Mutex(false)
            let task = Task {
                defer { started.continuation.finish() }
                try await ArchivePasswordVerification.execution.withValue(execution) {
                    try await ArchivePasswordVerification.observer.withValue({ event in
                        if case .didRead = event, paused.withLock({ value in
                            guard !value else { return false }
                            value = true
                            return true
                        }) {
                            started.continuation.yield(())
                            _ = release.wait(timeout: .now() + .seconds(3))
                        }
                    }) { _ = try await session.preparedPassword() }
                }
            }
            var iterator = started.stream.makeAsyncIterator()
            let didStart: Void? = await iterator.next()
            XCTAssertNotNil(didStart)
            let start = ContinuousClock.now
            task.cancel()
            release.signal()
            do { try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            XCTAssertNil(session.entryVerification)
            started.continuation.finish()
            await session.close()
        }
    }

    func testSessionCachesOnlySuccessfulVerificationAndUsesWriterThreads() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(.aes256, in: directory, count: 70, size: 1)
        for execution in [ArchivePasswordVerification.Execution.serial, .parallel] {
            let session = try ArchiveSession(url: url, password: "known", writerOptions: { _ in .init(compressionThreads: 3) })
            let before = ArchiveSession.passwordVerificationBytes.withLock { $0 }
            let counts = Mutex<[Int]>([]), stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
            try await ArchivePasswordVerification.execution.withValue(execution) {
                let payload = ArchiveEntryPayload(archiveURL: url, generation: 0, entryIndex: 17, path: "entry-17", isDirectory: false)
                _ = try await session.resolveForExtraction([payload])
                XCTAssertEqual(session.entryVerification?.indices, [17])
                try await ArchivePasswordVerification.observer.withValue({ event in
                    if case .workers(let count) = event { counts.withLock { $0.append(count) } }
                }) {
                    try await ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .ended(_, let stage, _) = event { stages.withLock { $0.append(stage) } }
                    }) { _ = try await session.deferredSnapshot() }
                }
                XCTAssertEqual(session.entryVerification?.indices, Set(0..<70))
                _ = try await session.preparedPassword()
            }
            XCTAssertEqual(counts.withLock { $0 }, execution == .serial ? [1] : [3])
            XCTAssertTrue(stages.withLock { $0.contains(.passwordVerification) })
            XCTAssertEqual(ArchiveSession.passwordVerificationBytes.withLock { $0 } - before, 70)
            await session.close()
        }
    }

    func testFailureKeepsOnlyPreviouslyVerifiedEntries() async throws {
        let directory = try ArchiveTestDirectory()
        for method in [ZipEncryption.aes256, .zipCrypto] {
            let url = try archive(method, in: directory)
            var data = try Data(contentsOf: url)
            data[records(data)[7].data.upperBound - 1] ^= 0xff
            try data.write(to: url)
            for execution in [ArchivePasswordVerification.Execution.serial, .parallel] {
                let session = try ArchiveSession(url: url, password: "known", writerOptions: { _ in .init(compressionThreads: 4) })
                try await ArchivePasswordVerification.execution.withValue(execution) {
                    let payload = ArchiveEntryPayload(archiveURL: url, generation: 0, entryIndex: 2, path: "entry-2", isDirectory: false)
                    _ = try await session.resolveForExtraction([payload])
                    do { _ = try await session.preparedPassword(); XCTFail("Expected integrity failure") }
                    catch { XCTAssertTrue(error is ExtractionFailure) }
                    XCTAssertEqual(session.entryVerification?.indices, [2])
                }
                await session.close()
            }
        }
    }

    func testPromptRetriesSeriallyBeforeParallelCandidateVerification() async throws {
        let directory = try ArchiveTestDirectory()
        for method in [ZipEncryption.aes256, .zipCrypto] {
            let url = try archive(method, in: directory, count: 68, size: 1)
            let session = try ArchiveSession(url: url, writerOptions: { _ in .init(compressionThreads: 4) })
            let challenges = Mutex<[ArchivePasswordChallenge]>([]), counts = Mutex<[Int]>([])
            session.setPasswordPrompt { challenge in
                let count = challenges.withLock { $0.append(challenge); return $0.count }
                guard count <= 2 else { throw CancellationError() }
                return count == 1 ? "incorrect" : "known"
            }
            try await ArchivePasswordVerification.execution.withValue(.parallel) {
                try await ArchivePasswordVerification.observer.withValue({ event in
                    if case .workers(let count) = event { counts.withLock { $0.append(count) } }
                }) { _ = try await session.preparedPassword() }
            }
            XCTAssertEqual(challenges.withLock { $0 }, [.required, .incorrect])
            XCTAssertEqual(counts.withLock { $0 }, [1, 4, 4])
            XCTAssertEqual(session.entryVerification?.indices, Set(0..<68))
            await session.close()
        }
    }

    func testCancelledEditAndExtractionLeaveInputAndDestinationUntouched() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(.aes256, in: directory, count: 68, size: 4096)
        let original = try Data(contentsOf: url)
        for editing in [true, false] {
            let session = try ArchiveSession(url: url, password: "known", writerOptions: { _ in .init(compressionThreads: 4) })
            let progress = Progress()
            let destination = directory.url.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                try await ArchivePasswordVerification.observer.withValue({ event in
                    if case .didRead = event { progress.cancel() }
                }) {
                    if editing { _ = try await session.createFolder(in: "", progress: progress) }
                    else {
                        let entries = await session.entries()
                        let payloads = entries.map { ArchiveEntryPayload(archiveURL: url, generation: 0, entryIndex: $0.index,
                            path: $0.name, isDirectory: false) }
                        _ = try await ExtractionService.extract(payloads, from: session, to: destination, progress: progress)
                    }
                }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(session.entryVerification)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            await session.close()
        }
    }
}
#endif
