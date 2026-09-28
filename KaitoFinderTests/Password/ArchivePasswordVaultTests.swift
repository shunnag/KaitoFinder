import CryptoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePasswordVaultTests: XCTestCase {
    private final class Fixture {
        let root: ArchiveTestDirectory

        init() throws { root = try ArchiveTestDirectory() }
        let key = SymmetricKey(size: .bits256)
        var directory: URL { root.url.appendingPathComponent("passwords", isDirectory: true) }
        var file: URL { directory.appendingPathComponent("vault.enc") }
        var archive: ArchivePasswordVault.Key { .file(root.url.appendingPathComponent("archive.zip")) }
        var otherArchive: ArchivePasswordVault.Key { .file(root.url.appendingPathComponent("other.zip")) }

        func vault(key: SymmetricKey? = nil) -> ArchivePasswordVault {
            ArchivePasswordVault(key: key ?? self.key, directory: directory)
        }

        func write(_ data: Data) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file)
        }

        func seal(_ text: String) throws -> Data {
            try XCTUnwrap(AES.GCM.seal(Data(text.utf8), using: key).combined)
        }
    }

    private func assertPassword(_ vault: ArchivePasswordVault, for key: ArchivePasswordVault.Key,
                                equals expected: String?, file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await vault.password(for: key)
        // 失敗時の XCTest 出力にもパスワードを含めない。
        XCTAssertTrue(actual == expected, "Vault password state", file: file, line: line)
    }

    func testSaveReloadAndUnknownKey() async throws {
        let fixture = try Fixture(), vault = fixture.vault(), password = "vault-roundtrip-日本語-2026"
        let saved = await vault.save(password, for: fixture.archive)
        XCTAssertTrue(saved)
        let reopened = fixture.vault()
        await assertPassword(reopened, for: fixture.archive, equals: password)
        await assertPassword(reopened, for: fixture.otherArchive, equals: nil)
    }

    func testSavingSameKeyReplacesPassword() async throws {
        let fixture = try Fixture(), vault = fixture.vault()
        let first = await vault.save("previous password", for: fixture.archive)
        let second = await vault.save("replacement password", for: fixture.archive)
        XCTAssertTrue(first && second)
        await assertPassword(fixture.vault(), for: fixture.archive, equals: "replacement password")
    }

    func testDiskContainsOnlySealedBytesWithPrivatePermissions() async throws {
        let fixture = try Fixture(), password = "plaintext-must-not-occur-in-this-file-日本語"
        let saved = await fixture.vault().save(password, for: fixture.archive)
        XCTAssertTrue(saved)
        let data = try Data(contentsOf: fixture.file)
        XCTAssertNil(data.range(of: Data(password.utf8)))
        let box = try AES.GCM.SealedBox(combined: data)
        let decoded = try JSONSerialization.jsonObject(with: AES.GCM.open(box, using: fixture.key)) as? [String: Any]
        XCTAssertEqual(decoded?["version"] as? Int, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        XCTAssertEqual(files, ["vault.enc"])
    }

    private func assertUnavailable(_ bytes: Data, fixture: Fixture, key: SymmetricKey? = nil) async throws {
        try fixture.write(bytes)
        let vault = fixture.vault(key: key)
        let available = await vault.isAvailable()
        XCTAssertFalse(available)
        await assertPassword(vault, for: fixture.archive, equals: nil)
        let saved = await vault.save("must not replace original", for: fixture.archive)
        XCTAssertFalse(saved)
        XCTAssertTrue(try Data(contentsOf: fixture.file) == bytes, "Existing vault bytes must be preserved")
    }

    func testRandomCorruptFileIsUnavailableAndUnchanged() async throws {
        let fixture = try Fixture()
        try await assertUnavailable(Data((0..<97).map { _ in UInt8.random(in: .min ... .max) }), fixture: fixture)
    }

    func testTruncatedFileIsUnavailableAndUnchanged() async throws {
        let fixture = try Fixture()
        let bytes = try fixture.seal(#"{"version":1,"entries":{}}"#)
        try await assertUnavailable(Data(bytes.dropLast(7)), fixture: fixture)
    }

    func testUnknownVersionIsUnavailableAndUnchanged() async throws {
        let fixture = try Fixture()
        try await assertUnavailable(fixture.seal(#"{"version":2,"entries":{}}"#), fixture: fixture)
    }

    func testOlderUnknownVersionIsAlsoUnavailableAndUnchanged() async throws {
        let fixture = try Fixture()
        try await assertUnavailable(fixture.seal(#"{"version":0,"entries":{}}"#), fixture: fixture)
    }

    func testAuthenticatedInvalidJSONIsUnavailableAndUnchanged() async throws {
        let fixture = try Fixture()
        try await assertUnavailable(fixture.seal("not valid JSON"), fixture: fixture)
    }

    func testWrongKeyIsUnavailableAndUnchanged() async throws {
        let fixture = try Fixture()
        try await assertUnavailable(fixture.seal(#"{"version":1,"entries":{}}"#), fixture: fixture,
                                    key: SymmetricKey(size: .bits256))
    }

    func testTransientReadFailureDoesNotOverwriteFile() async throws {
        let fixture = try Fixture(), bytes = try fixture.seal(#"{"version":1,"entries":{}}"#)
        try fixture.write(bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path) }
        XCTAssertThrowsError(try Data(contentsOf: fixture.file))
        let vault = fixture.vault()
        let available = await vault.isAvailable(), saved = await vault.save("refused", for: fixture.archive)
        XCTAssertFalse(available)
        XCTAssertFalse(saved)
        await assertPassword(vault, for: fixture.archive, equals: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        XCTAssertTrue(try Data(contentsOf: fixture.file) == bytes, "Read failure must preserve original bytes")
    }

    func testAbsentFileStartsEmptyAndCanSave() async throws {
        let fixture = try Fixture(), vault = fixture.vault()
        await assertPassword(vault, for: fixture.archive, equals: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let saved = await vault.save("first password", for: fixture.archive)
        XCTAssertTrue(saved)
        await assertPassword(fixture.vault(), for: fixture.archive, equals: "first password")
    }

    func testDanglingSymlinkIsUnavailableAndNotReplaced() async throws {
        let fixture = try Fixture(), missing = fixture.root.url.appendingPathComponent("missing.enc")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: missing)
        let vault = fixture.vault(), available = await vault.isAvailable()
        XCTAssertFalse(available)
        await assertPassword(vault, for: fixture.archive, equals: nil)
        let saved = await vault.save("must not replace symlink", for: fixture.archive)
        XCTAssertFalse(saved)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.file.path), missing.path)
    }

    func testZeroByteFileStartsEmptyAndCanSave() async throws {
        let fixture = try Fixture()
        try fixture.write(Data())
        let vault = fixture.vault()
        await assertPassword(vault, for: fixture.archive, equals: nil)
        let saved = await vault.save("first password", for: fixture.archive)
        XCTAssertTrue(saved)
        await assertPassword(fixture.vault(), for: fixture.archive, equals: "first password")
    }

    func testComponentArraysAvoidDeliberateSeparatorCollision() async throws {
        let fixture = try Fixture(), vault = fixture.vault(), separator = "\u{1f}"
        // 将来の入れ子キーを含め、単純連結だと同じ文字列になる二組を意図的に作る。
        let first = ArchivePasswordVault.Key(components: [fixture.root.url.path + "/a" + separator + "b.zip", "c.zip"])
        let second = ArchivePasswordVault.Key(components: [fixture.root.url.path + "/a", "b.zip" + separator + "c.zip"])
        XCTAssertEqual(first.components.joined(separator: separator), second.components.joined(separator: separator))
        XCTAssertNotEqual(first.storageString, second.storageString)
        let savedFirst = await vault.save("first archive password", for: first)
        let savedSecond = await vault.save("second archive password", for: second)
        XCTAssertTrue(savedFirst && savedSecond)
        let reopened = fixture.vault()
        await assertPassword(reopened, for: first, equals: "first archive password")
        await assertPassword(reopened, for: second, equals: "second archive password")
        let encoded = try XCTUnwrap(first.storageString).data(using: .utf8)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: XCTUnwrap(encoded)), first.components)
    }

    func testFileKeyNormalizesPathAndSymlinkAliases() async throws {
        let fixture = try Fixture(), file = fixture.root.url.appendingPathComponent("archive.zip")
        try Data().write(to: file)
        let alias = fixture.root.url.appendingPathComponent("alias.zip")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let key = ArchivePasswordVault.Key.file(file)
        XCTAssertEqual(key.components.count, 1)
        let saved = await fixture.vault().save("normalized password", for: key)
        XCTAssertTrue(saved)
        let reopened = fixture.vault()
        await assertPassword(reopened, for: .file(alias), equals: "normalized password")
        await assertPassword(reopened, for: .file(fixture.root.url.appendingPathComponent("tmp/../archive.zip")),
                             equals: "normalized password")
    }

    func testForgetRemovesAllEntriesAndImmediatelyAllowsSave() async throws {
        let fixture = try Fixture(), vault = fixture.vault()
        let first = await vault.save("first", for: fixture.archive)
        let second = await vault.save("second", for: fixture.otherArchive)
        XCTAssertTrue(first && second)
        let forgotten = await vault.forgetAll()
        XCTAssertTrue(forgotten)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        await assertPassword(vault, for: fixture.archive, equals: nil)
        await assertPassword(vault, for: fixture.otherArchive, equals: nil)
        let saved = await vault.save("after forgetting", for: fixture.archive)
        XCTAssertTrue(saved)
        let reopened = fixture.vault()
        await assertPassword(reopened, for: fixture.archive, equals: "after forgetting")
        await assertPassword(reopened, for: fixture.otherArchive, equals: nil)
    }

    func testForgetUnavailableVaultImmediatelyAllowsSave() async throws {
        let fixture = try Fixture()
        try fixture.write(Data("unreadable vault".utf8))
        let vault = fixture.vault(), available = await vault.isAvailable()
        XCTAssertFalse(available)
        let forgotten = await vault.forgetAll()
        XCTAssertTrue(forgotten)
        let saved = await vault.save("after recovery", for: fixture.archive)
        XCTAssertTrue(saved)
        await assertPassword(fixture.vault(), for: fixture.archive, equals: "after recovery")
    }

    func testForgetBeforeFirstLookupAlsoRecoversCorruptVault() async throws {
        let fixture = try Fixture()
        try fixture.write(Data("unreadable vault".utf8))
        let vault = fixture.vault(), forgotten = await vault.forgetAll()
        XCTAssertTrue(forgotten)
        let saved = await vault.save("after recovery", for: fixture.archive)
        XCTAssertTrue(saved)
        await assertPassword(fixture.vault(), for: fixture.archive, equals: "after recovery")
    }

    func testForgetAbsentVaultAllowsFirstSave() async throws {
        let fixture = try Fixture(), vault = fixture.vault(), forgotten = await vault.forgetAll()
        XCTAssertTrue(forgotten)
        let saved = await vault.save("first password", for: fixture.archive)
        XCTAssertTrue(saved)
    }

    func testForgetRejectsSaveFromPendingPasswordRequest() async throws {
        let fixture = try Fixture(), vault = fixture.vault(), generation = await vault.generation()
        let forgotten = await vault.forgetAll()
        let saved = await vault.save("pending password", for: fixture.archive, generation: generation)
        XCTAssertTrue(forgotten)
        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let freshSave = await vault.save("new request", for: fixture.archive, generation: vault.generation())
        XCTAssertTrue(freshSave)
    }

    func testRemovingStaleValuePreservesOtherEntriesAndNewerPassword() async throws {
        let fixture = try Fixture(), vault = fixture.vault()
        let first = await vault.save("replacement", for: fixture.archive)
        let second = await vault.save("other", for: fixture.otherArchive)
        XCTAssertTrue(first && second)
        let notRemoved = await vault.remove(for: fixture.archive, matching: "outdated")
        XCTAssertTrue(notRemoved)
        await assertPassword(vault, for: fixture.archive, equals: "replacement")
        let removed = await vault.remove(for: fixture.archive, matching: "replacement")
        XCTAssertTrue(removed)
        let reopened = fixture.vault()
        await assertPassword(reopened, for: fixture.archive, equals: nil)
        await assertPassword(reopened, for: fixture.otherArchive, equals: "other")
    }

    func testSealingFailureCreatesNoFileOrPlaintext() async throws {
        let fixture = try Fixture(), vault = fixture.vault(key: SymmetricKey(data: Data(repeating: 0, count: 7)))
        let saved = await vault.save("never write this plaintext", for: fixture.archive)
        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        await assertPassword(vault, for: fixture.archive, equals: nil)
    }
}
