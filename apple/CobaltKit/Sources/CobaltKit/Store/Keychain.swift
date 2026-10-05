import Foundation
import Security
import Synchronization

struct KeychainError: Error, Sendable, Equatable { var status: OSStatus }

/// The four Security calls the keychain makes, so tests can stand in for a build the system keychain
/// refuses (unsigned: every call answers -34018, even on the default keychain).
protocol KeychainBackend: Sendable {
    func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ item: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], data: Data) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, status == errSecSuccess ? result as? Data : nil)
    }
    func add(_ item: [String: Any]) -> OSStatus { SecItemAdd(item as CFDictionary, nil) }
    func update(_ query: [String: Any], data: Data) -> OSStatus {
        SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Last resort for a build that has no keychain at all (unsigned simulator and Mac builds answer
/// errSecMissingEntitlement to every keychain call, the default keychain included). One small file per
/// account in this process's own container, excluded from backup. A signed build never gets here: its
/// default keychain always works, so a release never writes a key to disk.
struct SecretFiles: Sendable {
    let directory: URL

    static var standard: SecretFiles {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return SecretFiles(directory: base.appendingPathComponent("com.capybaraharmony.cobalt/unentitled-secrets", isDirectory: true))
    }

    private func url(_ service: String, _ account: String) -> URL {
        let safe = "\(service)--\(account)".map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : Character("_") }
        return directory.appendingPathComponent(String(safe), isDirectory: false)
    }

    func get(_ service: String, _ account: String) -> String? {
        (try? Data(contentsOf: url(service, account))).flatMap { String(data: $0, encoding: .utf8) }
    }

    func set(_ value: String?, service: String, account: String) throws {
        let file = url(service, account)
        guard let value else { try? FileManager.default.removeItem(at: file); return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutable = file
        try? mutable.setResourceValues(excluded)
    }
}

/// Generic-password items in the Keychain, optionally in a shared access group (so the share
/// extension reads the key the app saved). Builds without the keychain-sharing entitlement
/// (unsigned simulator and Mac builds) have no group: every operation then falls back to the
/// process's default keychain, and an item an earlier build left there is still found. A build whose
/// keychain is unusable altogether (see `SecretFiles`) keeps the value in its own container instead.
public struct Keychain: Sendable {
    private let service: String
    private let accessGroup: String?
    private let memory: MemoryStore?
    private let backend: any KeychainBackend
    private let files: SecretFiles?

    public init(service: String = "com.capybaraharmony.cobalt", accessGroup: String?) {
        self.init(service: service, accessGroup: accessGroup, backend: SystemKeychainBackend(), files: Self.unentitledFallback)
    }

    /// The plaintext file fallback exists only for unsigned DEBUG builds (simulator testing without
    /// entitlements). A release build never writes a secret outside the keychain; it reports
    /// `.couldNotSave` instead.
    private static var unentitledFallback: SecretFiles? {
        #if DEBUG
        return .standard
        #else
        return nil
        #endif
    }

    init(service: String, accessGroup: String?, backend: any KeychainBackend, files: SecretFiles?) {
        self.service = service
        self.accessGroup = accessGroup
        self.memory = nil
        self.backend = backend
        self.files = files
    }

    /// Keeps values in memory only (previews and tests never touch the real keychain).
    static func memory() -> Keychain { Keychain(memory: MemoryStore()) }

    private init(memory: MemoryStore) {
        self.service = "memory"
        self.accessGroup = nil
        self.memory = memory
        self.backend = SystemKeychainBackend()
        self.files = nil
    }

    /// The shared access group when the build is entitled for one, else the default keychain.
    public static let shared = Keychain(accessGroup: Keychain.entitledGroup())

    public func string(for account: String) -> String? {
        if let memory { return memory.get(account) }
        for query in queries(account) {
            let found = backend.copy(query)
            if found.status == errSecSuccess, let data = found.data, let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return files?.get(service, account)
    }

    public func set(_ value: String?, for account: String) throws {
        if let memory { memory.set(value, for: account); return }
        guard let value else {
            try? files?.set(nil, service: service, account: account)
            for query in queries(account) {
                let status = backend.delete(query)
                if status != errSecSuccess && status != errSecItemNotFound && !Self.isEntitlementFailure(status) {
                    throw KeychainError(status: status)
                }
            }
            return
        }
        let data = Data(value.utf8)
        var lastFailure: OSStatus = errSecSuccess
        for query in queries(account) {
            let update = backend.update(query, data: data)
            if update == errSecSuccess { try? files?.set(nil, service: service, account: account); return }
            if update == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let status = backend.add(add)
                if status == errSecSuccess { try? files?.set(nil, service: service, account: account); return }
                lastFailure = status
            } else {
                lastFailure = update
            }
            // A group this build is not entitled to (-34018 and friends): try the default keychain.
            guard Self.isEntitlementFailure(lastFailure) else { throw KeychainError(status: lastFailure) }
        }
        // Every keychain query was refused for lack of an entitlement: this build has no keychain.
        if let files {
            do { try files.set(value, service: service, account: account); return } catch { /* report the keychain's status */ }
        }
        throw KeychainError(status: lastFailure)
    }

    /// The queries for one account, most specific first: the shared group, then the default.
    private func queries(_ account: String) -> [[String: Any]] {
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let accessGroup else { return [base] }
        var grouped = base
        grouped[kSecAttrAccessGroup as String] = accessGroup
        base[kSecAttrAccessGroup as String] = nil
        return [grouped, base]
    }

    static func isEntitlementFailure(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecNoAccessForItem || status == errSecParam
    }

    /// The access group new items land in for this build: the app's first keychain group, which
    /// project.yml sets to `$(AppIdentifierPrefix)com.capybaraharmony.cobalt` for both targets.
    /// Found by adding a throwaway item and asking where it went, then checking that the group
    /// answers a query. Unsigned builds have none (or cannot use it), so this is nil.
    static func entitledGroup() -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.capybaraharmony.cobalt.probe",
            kSecAttrAccount as String: "probe-\(UUID().uuidString)",
        ]
        var add = base
        add[kSecValueData as String] = Data("probe".utf8)
        add[kSecReturnAttributes as String] = true
        var added: CFTypeRef?
        guard SecItemAdd(add as CFDictionary, &added) == errSecSuccess,
              let attrs = added as? [String: Any]
        else { return nil }
        defer { SecItemDelete(base as CFDictionary) }
        guard let group = attrs[kSecAttrAccessGroup as String] as? String, !group.isEmpty else { return nil }
        var check = base
        check[kSecAttrAccessGroup as String] = group
        check[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(check as CFDictionary, nil) == errSecSuccess ? group : nil
    }
}

private final class MemoryStore: Sendable {
    private let values = Mutex<[String: String]>([:])
    func get(_ account: String) -> String? { values.withLock { $0[account] } }
    func set(_ value: String?, for account: String) { values.withLock { $0[account] = value } }
}
