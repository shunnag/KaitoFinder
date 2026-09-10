import CryptoKit
import Darwin
import Foundation
import Security

/// 書庫ごとの Keychain 項目は ad-hoc 署名の再ビルドごとに許可を求められる。
/// マスターキーだけを Keychain に置き、パスワードはまとめて AES-GCM で封緘する。
/// 読めない既存ファイルは空と見なさない。一過性の障害で全件を失わないため。
actor ArchivePasswordVault {
    static let shared = ArchivePasswordVault()

    nonisolated struct Key: Hashable, Sendable {
        let components: [String]

        static func file(_ url: URL) -> Key {
            // 書庫の編集は inode を置換するので、ファイルの同一性にはパスを使う。
            Key(components: [url.standardizedFileURL.resolvingSymlinksInPath().path])
        }

        var storageString: String? {
            // 区切り文字はファイル名にも現れる。将来の階層化でも衝突しない配列にする。
            guard let data = try? JSONEncoder().encode(components) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    nonisolated private struct FileContents: Codable {
        let version: Int
        let entries: [String: String]
    }

    private enum State {
        case unloaded, unavailable
        case ready([String: String])
    }

    private var state = State.unloaded
    private var masterKey: SymmetricKey?
    private let usesKeychain: Bool
    private let directory: URL
    private var forgetGeneration: UInt64 = 0

    private init() {
        usesKeychain = true
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.shunnag.KaitoFinder", isDirectory: true)
            .appendingPathComponent("Passwords", isDirectory: true)
    }

    /// 鍵と保存先を同時に注入し、テストから実データと Keychain への経路をなくす。
    /// 環境変数による鍵の差し替えは提供しない。
    init(key: SymmetricKey, directory: URL) {
        masterKey = key
        usesKeychain = false
        self.directory = directory
    }

    func password(for key: Key) -> String? {
        guard case .ready(let entries) = load(), let name = key.storageString else { return nil }
        return entries[name]
    }

    func isAvailable() -> Bool {
        if case .ready = load() { return true }
        return false
    }

    func generation() -> UInt64 { forgetGeneration }

    @discardableResult
    func save(_ password: String, for key: Key, generation: UInt64? = nil) -> Bool {
        // 入力・検証中に「すべて削除」された値を、遅れて保存し直さない。
        guard !Task.isCancelled, generation == nil || generation == forgetGeneration,
              case .ready(var entries) = load(), let name = key.storageString else { return false }
        entries[name] = password
        guard persist(entries) else { return false }
        state = .ready(entries)
        return true
    }

    @discardableResult
    func remove(for key: Key, matching password: String) -> Bool {
        guard case .ready(var entries) = load(), let name = key.storageString else { return false }
        guard entries[name] == password else { return true }
        entries.removeValue(forKey: name)
        guard persist(entries) else {
            // 削除を書き戻せなくても、この起動中に古い値を再び自動入力しない。
            state = .unavailable
            return false
        }
        state = .ready(entries)
        return true
    }

    @discardableResult
    func forgetAll() -> Bool {
        guard !isUninjectedTestRun else { state = .unavailable; return false }
        forgetGeneration &+= 1
        do { try FileManager.default.removeItem(at: vaultURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch { state = .unavailable; return false }
        // 復号できない庫も、明示的に削除できた後は保存を再開できる。鍵は残す。
        state = .ready([:])
        return true
    }

    private var vaultURL: URL { directory.appendingPathComponent("vault.enc") }

    private var isUninjectedTestRun: Bool {
        let environment = ProcessInfo.processInfo.environment
        return usesKeychain && (environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil)
    }

    private func load() -> State {
        // 注入を忘れたテストも、実データや Keychain に触れる前に止める。
        if isUninjectedTestRun {
            state = .unavailable
            return state
        }
        guard case .unloaded = state else { return state }
        state = .unavailable
        do {
            let data = try Data(contentsOf: vaultURL)
            if data.isEmpty { state = .ready([:]); return state }
            guard let key = encryptionKey(create: false),
                  let box = try? AES.GCM.SealedBox(combined: data),
                  let plain = try? AES.GCM.open(box, using: key),
                  let contents = try? JSONDecoder().decode(FileContents.self, from: plain),
                  contents.version == 1 else { return state }
            state = .ready(contents.entries)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // リンク先が一時的にない場合も read は ENOENT になる。リンク自体を
            // 空の庫で置き換えないよう、実体の不在を lstat で確かめる。
            var attributes = stat()
            if lstat(vaultURL.path, &attributes) != 0, errno == ENOENT { state = .ready([:]) }
        } catch { }
        return state
    }

    private func encryptionKey(create: Bool) -> SymmetricKey? {
        if let masterKey { return masterKey }
        guard usesKeychain else { return nil }
        masterKey = Self.keychainKey(create: create)
        return masterKey
    }

    private func persist(_ entries: [String: String]) -> Bool {
        // seal が成功するまでディスクには何も作らない。例外の内容も外へ出さない。
        guard let key = encryptionKey(create: true) else {
            // Keychain を拒否された起動中に、保存のたびに許可を要求し直さない。
            state = .unavailable
            return false
        }
        guard let plain = try? JSONEncoder().encode(FileContents(version: 1, entries: entries)),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return false }
        let manager = FileManager.default
        let temporary = directory.appendingPathComponent(".vault-" + UUID().uuidString + ".tmp")
        defer { try? manager.removeItem(at: temporary) }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try sealed.write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // rename は初回作成にも置換にも使え、途中のファイルを読ませない。
            return rename(temporary.path, vaultURL.path) == 0
        } catch { return false }
    }

    private static func keychainKey(create: Bool) -> SymmetricKey? {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.shunnag.KaitoFinder") + ".archive-password-vault",
            kSecAttrAccount as String: "master-key"
        ]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        // 許可拒否や読取障害を「鍵がない」と見なして新しい鍵を作らない。
        guard status == errSecItemNotFound, create else { return nil }
        let key = SymmetricKey(size: .bits256)
        var attributes = identity
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return key }
        if added == errSecDuplicateItem { return keychainKey(create: false) }
        return nil
    }
}
