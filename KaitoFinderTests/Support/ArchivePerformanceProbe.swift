#if DEBUG
import CommonCrypto
import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated enum ProbeArchiveFormat: String, Sendable {
    case zip, tar, tarGzip = "tar.gz", tarBzip2 = "tar.bz2", tarXZ = "tar.xz", sevenZip = "7z", lha

    var writerFormat: GyoshukuKit.ArchiveFormat {
        switch self {
        case .zip: .zip
        case .tar: .tar
        case .tarGzip: .tarGzip
        case .tarBzip2: .tarBzip2
        case .tarXZ: .tarXZ
        case .sevenZip: .sevenZip
        case .lha: .lha
        }
    }

    func editorStage(placement: ArchivePreferences.AdditionPosition) -> ArchiveStageDiagnostics.Stage {
        if self == .zip { return .updaterOpen }
        return placement == .end && [.tar, .tarGzip, .tarBzip2, .tarXZ, .lha].contains(self) ? .updaterOpen : .rewriterOpen
    }
}

nonisolated enum ProbeArchiveEncryption: String, Sendable {
    case aes, zipcrypto

    var method: ZipEncryption { self == .aes ? .aes256 : .zipCrypto }
    var entryMethod: String { self == .aes ? "AES-256" : "ZipCrypto" }

    static func configured() throws -> [Self] {
        guard let value = ProcessInfo.processInfo.environment["KAITOFINDER_PROBE_ENCRYPTION"] else {
            throw XCTSkip("Set KAITOFINDER_PROBE_ENCRYPTION=aes,zipcrypto to run password probes")
        }
        let names = value.lowercased().split(whereSeparator: { $0 == "," || $0.isWhitespace })
        guard !names.isEmpty else { throw ConfigurationError.invalid(value) }
        var methods: [Self] = []
        for name in names {
            guard let method = Self(rawValue: String(name)) else { throw ConfigurationError.invalid(String(name)) }
            if !methods.contains(method) { methods.append(method) }
        }
        return methods
    }

    private enum ConfigurationError: Error { case invalid(String) }
}

nonisolated struct ArchiveProbeConfiguration: Sendable {
    let entries: Int
    let payloadMiB: Int
    let splitVolumeMiB: Int
    let formats: [ProbeArchiveFormat]
    let asserts: Bool
    let additionPosition: ArchivePreferences.AdditionPosition

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard environment["KAITOFINDER_PERFORMANCE_PROBES"] == "1" else {
            throw XCTSkip("Set KAITOFINDER_PERFORMANCE_PROBES=1 to run performance probes")
        }
        func positive(_ key: String, default fallback: Int, minimum: Int) throws -> Int {
            guard let text = environment[key] else { return fallback }
            guard let value = Int(text), value >= minimum, value <= Int.max / 1_048_576 else {
                throw ConfigurationError.invalid(key)
            }
            return value
        }
        entries = try positive("KAITOFINDER_PROBE_ENTRIES", default: 100_000, minimum: 2)
        payloadMiB = try positive("KAITOFINDER_PROBE_PAYLOAD_MIB", default: 256, minimum: 1)
        splitVolumeMiB = try positive("KAITOFINDER_PROBE_SPLIT_VOLUME_MIB", default: 32, minimum: 1)
        let names = (environment["KAITOFINDER_PROBE_FORMATS"] ?? "zip").lowercased()
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
        guard !names.isEmpty else { throw ConfigurationError.invalid("KAITOFINDER_PROBE_FORMATS") }
        var formats: [ProbeArchiveFormat] = []
        for name in names {
            guard let format = ProbeArchiveFormat(rawValue: String(name)) else { throw ConfigurationError.invalid(String(name)) }
            if !formats.contains(format) { formats.append(format) }
        }
        self.formats = formats
        asserts = environment["KAITOFINDER_PROBE_ASSERT"] == "1"
        guard let placement = ArchivePreferences.AdditionPosition(rawValue: environment["KAITOFINDER_PROBE_ADDITION_PLACEMENT"] ?? "end") else {
            throw ConfigurationError.invalid("KAITOFINDER_PROBE_ADDITION_PLACEMENT")
        }
        additionPosition = placement
    }

    private enum ConfigurationError: Error { case invalid(String) }
}

nonisolated struct ArchiveProbeFixture: Sendable {
    enum Kind: String, CaseIterable { case entries, payload }
    let directory: ArchiveTestDirectory
    let url: URL
    let format: ProbeArchiveFormat
    let kind: Kind
    let smallCount: Int
    let payloadMiB: Int
    let encryption: ProbeArchiveEncryption?
    var password: String? { encryption == nil ? nil : "probe-fixture-key" }
    var inputBytes: UInt64 { UInt64(payloadMiB) * 1_048_576 + UInt64(smallCount) }
    var entryCount: Int { smallCount + (kind == .payload ? 64 : 0) }
    var firstPath: String { kind == .payload ? Self.payloadPath(0) : Self.smallPath(0) }
    var lastPath: String { Self.smallPath(smallCount - 1) }
    var folderPath: String { kind == .payload ? "payload" : "d000" }

    static func smallPath(_ index: Int) -> String {
        String(format: "d%03d/s%d/f%07d.txt", index / 1000, (index / 100) % 10, index)
    }

    static func payloadPath(_ index: Int) -> String { String(format: "payload/p%07d.txt", index) }
}

nonisolated enum ArchiveProbeFixtures {
    // 本文・暗号化の生成規則を変えたら更新する。
    private static let version = 3
    private static let cache = Mutex<[String: ArchiveProbeFixture]>([:])
    private static let splitVersion = 1
    private static let splitCache = Mutex<[String: ArchiveProbeSplitFixture]>([:])

    static func removeAll() {
        splitCache.withLock { $0.removeAll() }
        cache.withLock { $0.removeAll() }
    }

    @concurrent static func splitFixture(format: ProbeArchiveFormat, configuration: ArchiveProbeConfiguration) async throws
        -> ArchiveProbeSplitFixture {
        let payload = try await fixture(.payload, format: format, configuration: configuration)
        return try splitCache.withLock { cache in
            let key = "\(format.rawValue)-\(configuration.payloadMiB)-\(configuration.splitVolumeMiB)-v\(version)-split-v\(splitVersion)"
            if let fixture = cache[key] { return fixture }
            let directory = try ArchiveTestDirectory()
            let length = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: payload.url.path)[.size] as? NSNumber).uint64Value
            let plan = try VolumePlan(totalLength: length, schedule: .uniform(size: UInt64(configuration.splitVolumeMiB) * 1_048_576),
                                      scheme: .numbered(stem: "fixture." + format.rawValue, width: 3))
            let input = try FileHandle(forReadingFrom: payload.url)
            defer { try? input.close() }
            var volumes: [URL] = []
            for volume in plan.volumes {
                let url = directory.url.appendingPathComponent(volume.name)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: url)
                defer { try? output.close() }
                var remaining = volume.length
                while remaining > 0 {
                    guard let bytes = try input.read(upToCount: Int(min(1_048_576, remaining))), !bytes.isEmpty else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try output.write(contentsOf: bytes)
                    remaining -= UInt64(bytes.count)
                }
                volumes.append(url)
            }
            let fixture = ArchiveProbeSplitFixture(directory: directory, payload: payload, volumes: volumes)
            ArchiveProbeTrace.line("PROBE-SPLIT-FIXTURE\tversion=\(splitVersion)\tformat=\(format.rawValue)\tvolume_mib=\(configuration.splitVolumeMiB)\tvolumes=\(volumes.count)\tarchive_bytes=\(length)")
            cache[key] = fixture
            return fixture
        }
    }

    @concurrent static func fixture(_ kind: ArchiveProbeFixture.Kind, format: ProbeArchiveFormat,
                                    configuration: ArchiveProbeConfiguration,
                                    encryption: ProbeArchiveEncryption? = nil) async throws -> ArchiveProbeFixture {
        precondition(encryption == nil || format == .zip)
        return try cache.withLock { cache in
            let key = "\(format.rawValue)-\(kind.rawValue)-\(configuration.entries)-\(configuration.payloadMiB)-\(encryption?.rawValue ?? "plain")-v\(version)"
            if let fixture = cache[key] { return fixture }
            let directory = try ArchiveTestDirectory()
            let fixture = ArchiveProbeFixture(directory: directory,
                url: directory.url.appendingPathComponent("fixture." + format.rawValue), format: format, kind: kind,
                smallCount: kind == .entries ? configuration.entries : 1_000,
                payloadMiB: kind == .entries ? 0 : configuration.payloadMiB, encryption: encryption)
            let trace = ArchiveProbeTrace(fixture: fixture, mode: "fixture", operation: encryption.map { "build_" + $0.rawValue } ?? "build")
            let start = ContinuousClock.now
            try ArchiveStageDiagnostics.observer.withValue({ trace.record($0) }) {
                try ArchiveStageDiagnostics.measure(.fixtureBuild) {
                    let settings = ArchiveEncryptionSettings(password: fixture.password, zipEncryption: encryption?.method ?? .aes256)
                    let writer = try ArchiveWriter.create(url: fixture.url, format: format.writerFormat,
                        options: settings.applying(to: ArchivePreferences().writerOptions(for: format.writerFormat), format: format.writerFormat))
                    if kind == .payload {
                        let size = configuration.payloadMiB * 1_048_576 / 64
                        for index in 0..<64 {
                            let data = try ArchiveProbePayload.data(file: index, size: size)
                            try writer.add(data: data, as: ArchiveProbeFixture.payloadPath(index))
                        }
                    }
                    for index in 0..<fixture.smallCount {
                        try writer.add(data: Data([42]), as: ArchiveProbeFixture.smallPath(index))
                    }
                    try writer.finish()
                }
            }
            let duration = start.duration(to: .now)
            let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
            let archiveBytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fixture.url.path)[.size] as? NSNumber)
            ArchiveProbeTrace.line(["PROBE-FIXTURE", "version=\(version)", "format=\(format.rawValue)", "kind=\(kind.rawValue)",
                "encryption=\(encryption?.rawValue ?? "plain")", "entries=\(fixture.entryCount)",
                "input_bytes=\(fixture.inputBytes)", "archive_bytes=\(archiveBytes.uint64Value)",
                "build_ms=" + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), milliseconds),
                "dictionary=" + (kind == .payload ? ArchiveProbePayload.words.source : "NA")].joined(separator: "\t"))
            trace.finish(output: fixture.url)
            cache[key] = fixture
            return fixture
        }
    }
}

nonisolated struct ArchiveProbeSplitFixture: Sendable {
    let directory: ArchiveTestDirectory
    let payload: ArchiveProbeFixture
    let volumes: [URL]
}

nonisolated enum ArchiveProbePayload {
    static let words = WordList()

    static func data(file index: Int, size: Int, words: WordList = Self.words) throws -> Data {
        let random = try BlockRandom(seed: 20_260_925 + UInt64(index))
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { output in
            if index >= 48 { try random.fill(output); return }
            // 単語単位でコピーし、乱数は 64 KiB ずつ生成する。
            var draws = [UInt32](repeating: 0, count: BlockRandom.blockSize / MemoryLayout<UInt32>.size)
            try words.bytes.withUnsafeBytes { dictionary in
                var offset = 0
                while offset < output.count {
                    try draws.withUnsafeMutableBytes { try random.fill($0) }
                    for draw in draws {
                        let word = words.ranges[Int(UInt32(littleEndian: draw)) % words.ranges.count]
                        let count = min(word.count, output.count - offset)
                        output.baseAddress!.advanced(by: offset).copyMemory(
                            from: dictionary.baseAddress!.advanced(by: word.lowerBound), byteCount: count)
                        offset += count
                        if offset == output.count { break }
                    }
                }
            }
        }
        return data
    }

    struct WordList: Sendable {
        let bytes: Data
        let ranges: [Range<Int>]
        let source: String

        init(url: URL = URL(fileURLWithPath: "/usr/share/dict/words")) {
            let dictionary = (try? String(contentsOf: url, encoding: .utf8))?.split(whereSeparator: \.isWhitespace) ?? []
            let available = !dictionary.isEmpty
            let words = available ? dictionary : Self.fallback.split(whereSeparator: \.isWhitespace)
            var bytes = Data(), ranges: [Range<Int>] = []
            ranges.reserveCapacity(words.count)
            for word in words {
                let start = bytes.count
                bytes.append(contentsOf: word.utf8)
                bytes.append(32)
                ranges.append(start..<bytes.count)
            }
            self.bytes = bytes
            self.ranges = ranges
            source = available ? url.path : "builtin"
        }

        private static let fallback = """
        ability absent accept across action address adjust advice afternoon airport amber amount anchor animal answer
        apple archive arrange arrow autumn balance bamboo basket beach before begin below bicycle blanket blossom
        blue boat border bottle branch breeze bridge bright bronze browser build button cabin cable camera canyon
        captain carrot cedar center change chapter cherry circle citizen city clay clear clock cloud coast coffee
        color column common compare compass complete copper coral cotton country cover create crystal current
        dance data dawn decide deep desert design detail device diamond different dinner direction distant divide
        doctor document dragon dream drive early earth east edge editor effort eight electric emerald energy engine
        entry evening every example expect explain factory family feather field figure filter finish fire first
        flower forest format fountain frame fresh friend frost future garden gentle glass golden grain granite
        green group guide harbor harvest hazel heavy hidden history horizon hotel house hundred ice idea image
        include index input island ivory jacket journey judge jungle kernel keyboard kitchen ladder lake language
        lantern large last later lavender layer leader leaf learn lemon letter library light lilac limit linen
        list little local long machine magic marble market meadow measure memory metal midnight minute mirror
        model month morning moss mountain music name narrow nature network night north number ocean office olive
        orange orchid order origin output outside paper parent path pattern peach pearl people pepper period
        person picture pine planet plant pocket poem point pool prepare present process publish purple quartz
        question quiet rabbit rain reader record region replace result return review river road robin rock rose
        round ruby sail salt sample sand save scarlet school science season seed silver simple size sky snow
        source south space spring square stage star station stone store stream string study summer sunset
        surface table target temple text theory thread thunder ticket time tomato topic total tower train tree
        tulip under union unit update valley value velvet verify violet volume walk water wave weather west wheat
        white willow window winter wisdom wonder wood word worker world write year yellow young zebra zero
        """
    }

    private final class BlockRandom {
        static let blockSize = 65_536
        private static let zeros = Data(count: blockSize)
        private var cryptor: CCCryptorRef?

        init(seed: UInt64) throws {
            // 固定鍵とゼロ IV の CTR 出力を再現可能な乱数源としてだけ使う。
            var key = (seed.littleEndian, UInt64(0x4b6169746f507262).littleEndian)
            let status = withUnsafeBytes(of: &key) {
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), nil, $0.baseAddress, $0.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
            guard status == kCCSuccess else { throw GenerationError.crypto(status) }
        }

        deinit { if let cryptor { CCCryptorRelease(cryptor) } }

        func fill(_ output: UnsafeMutableRawBufferPointer) throws {
            try Self.zeros.withUnsafeBytes { zeros in
                for offset in stride(from: 0, to: output.count, by: Self.blockSize) {
                    let count = min(Self.blockSize, output.count - offset)
                    var written = 0
                    let status = CCCryptorUpdate(cryptor, zeros.baseAddress, count,
                        output.baseAddress!.advanced(by: offset), count, &written)
                    guard status == kCCSuccess, written == count else { throw GenerationError.crypto(status) }
                }
            }
        }
    }

    private enum GenerationError: Error { case crypto(CCCryptorStatus) }
}

nonisolated final class ArchiveProbeTrace: Sendable {
    private struct DiskIO {
        let read: UInt64
        let written: UInt64

        static func capture() -> Self? {
            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
                }
            }
            guard result == 0 else { return nil }
            return Self(read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten)
        }

        func since(_ previous: Self) -> Self? {
            guard read >= previous.read, written >= previous.written else { return nil }
            return Self(read: read - previous.read, written: written - previous.written)
        }
    }

    private struct Sample {
        let duration: Duration
        let disk: DiskIO?
    }

    private struct State {
        var starts: [UUID: DiskIO] = [:]
        var active: Set<UUID> = []
        var samples: [ArchiveStageDiagnostics.Stage: [Sample]] = [:]
    }

    private let fixture: ArchiveProbeFixture
    private let mode: String
    private let operation: String
    private let reportsPasswordVerification: Bool
    private let state = Mutex(State())

    init(fixture: ArchiveProbeFixture, mode: String, operation: String, reportsPasswordVerification: Bool = false) {
        self.fixture = fixture
        self.mode = mode
        self.operation = operation
        self.reportsPasswordVerification = reportsPasswordVerification
    }

    static func line(_ text: String) {
        // stdio のバッファを介さず、sample の開始目印を直ちに出す。
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    static func header() {
        line("PROBE-TSV-HEADER\tversion\tformat\tfixture\tmode\toperation\tstage\tcalls\tduration_ms\tread_bytes\twritten_bytes\toutput_bytes\tentries\tpayload_mib\tstatus")
        line("PROBE-PROCESS pid=\(getpid()) diskio=RUSAGE_INFO_V2")
        line("PROBE-SPLICE-HEADER\tversion\tformat\tfixture\tmode\toperation\tstrategy\tplan_ms\tencode_ms\tcopy_ms\tself_check_ms\treencoded_old_image_bytes\tcarried_compressed_bytes\tscratch_bytes\treencoded_image_bytes\tcarried_chunks\treencoded_chunks")
    }

    func recordSplice(_ statistics: CompressedTarCommitStatistics) {
        let strategy: String
        switch statistics.strategy {
        case .unchanged: strategy = "unchanged"
        case .splice: strategy = "splice"
        case .fullEncode: strategy = "fullEncode"
        }
        func ms(_ seconds: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds * 1_000) }
        Self.line(["PROBE-SPLICE", "1", fixture.format.rawValue, fixture.kind.rawValue, mode, operation, strategy,
            ms(statistics.planningSeconds), ms(statistics.encodingSeconds), ms(statistics.copyingSeconds), ms(statistics.selfCheckSeconds),
            String(statistics.reencodedOldImageBytes), String(statistics.carriedCompressedBytes), String(statistics.scratchBytes),
            String(statistics.reencodedImageBytes), String(statistics.carriedChunks), String(statistics.reencodedChunks)].joined(separator: "\t"))
    }

    func requireRoute(placement: ArchivePreferences.AdditionPosition) {
        let stage = fixture.format.editorStage(placement: placement)
        require([stage])
        forbid([stage == .updaterOpen ? .rewriterOpen : .updaterOpen, .workCopy])
    }

    func requireSaveValidation(file: StaticString = #filePath, line: UInt = #line) {
        require([.representabilityDifferential, .editingInstall], file: file, line: line)
        forbid([.planKeys], file: file, line: line)
        let rewrote = state.withLock { $0.samples[.rewriterOpen] != nil }
        if rewrote { require([.validateRepresentability, .representabilityProbe], file: file, line: line) }
        else { forbid([.validateRepresentability, .representabilityProbe], file: file, line: line) }
    }

    func record(_ event: ArchiveStageDiagnostics.Event) {
        switch event {
        case .began(let id, let stage):
            state.withLock {
                Self.line("PROBE-STAGE-BEGIN \(fixture.format.rawValue)/\(fixture.kind.rawValue)/\(mode)/\(operation)/\(stage.rawValue)")
                $0.active.insert(id)
                $0.starts[id] = DiskIO.capture()
            }
        case .ended(let id, let stage, let duration):
            let disk = DiskIO.capture()
            state.withLock {
                let previous = $0.starts.removeValue(forKey: id)
                $0.active.remove(id)
                $0.samples[stage, default: []].append(Sample(duration: duration,
                    disk: previous.flatMap { before in disk?.since(before) }))
            }
        }
    }

    func require(_ stages: [ArchiveStageDiagnostics.Stage], file: StaticString = #filePath, line: UInt = #line) {
        let recorded = state.withLock { Set($0.samples.keys) }
        for stage in stages {
            XCTAssertTrue(recorded.contains(stage), "Missing stage: \(mode)/\(operation)/\(stage.rawValue)", file: file, line: line)
        }
    }

    func forbid(_ stages: [ArchiveStageDiagnostics.Stage], file: StaticString = #filePath, line: UInt = #line) {
        let recorded = state.withLock { Set($0.samples.keys) }
        for stage in stages {
            XCTAssertFalse(recorded.contains(stage), "Unexpected stage: \(mode)/\(operation)/\(stage.rawValue)", file: file, line: line)
        }
    }

    func requireEditorOpen(file: StaticString = #filePath, line: UInt = #line) {
        let recorded = state.withLock { Set($0.samples.keys) }
        XCTAssertFalse(recorded.isDisjoint(with: [.updaterOpen, .rewriterOpen]),
                       "Missing editor open: \(mode)/\(operation)", file: file, line: line)
    }

    func finish(output: URL, status: String = "ok") {
        finish(outputs: [output], status: status)
    }

    func finish(outputs: [URL], status: String = "ok") {
        let snapshot = state.withLock { $0 }
        XCTAssertTrue(snapshot.active.isEmpty, "Unfinished probe stages: \(operation)")
        let sizes = outputs.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.uint64Value }
        let size = !outputs.isEmpty && sizes.count == outputs.count ? String(sizes.reduce(0, +)) : "NA"
        for stage in snapshot.samples.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let samples = snapshot.samples[stage]!
            let duration = samples.reduce(Duration.zero) { $0 + $1.duration }
            let ms = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
            let disks = samples.compactMap(\.disk)
            let reads = disks.count == samples.count ? String(disks.reduce(UInt64(0)) { $0 + $1.read }) : "NA"
            let writes = disks.count == samples.count ? String(disks.reduce(UInt64(0)) { $0 + $1.written }) : "NA"
            Self.line(["PROBE-TSV", "1", fixture.format.rawValue, fixture.kind.rawValue, mode, operation, stage.rawValue,
                       String(samples.count), String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), ms), reads, writes, size,
                       String(fixture.entryCount), String(fixture.payloadMiB), status].joined(separator: "\t"))
        }
        if reportsPasswordVerification, let totals = snapshot.samples[.total] {
            let total = totals.reduce(Duration.zero) { $0 + $1.duration }
            let verification = (snapshot.samples[.passwordVerification] ?? []).reduce(Duration.zero) { $0 + $1.duration }
            XCTAssertGreaterThanOrEqual(total, verification)
            let duration = total - verification
            let ms = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
            Self.line(["PROBE-TSV", "1", fixture.format.rawValue, fixture.kind.rawValue, mode, operation,
                "total_without_password_verification", String(totals.count),
                String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), ms), "NA", "NA", size,
                String(fixture.entryCount), String(fixture.payloadMiB), status].joined(separator: "\t"))
        }
    }
}
#endif
