import Foundation
import Security

/// The Keychain account a password is stored under.
public enum SecretAccount: Hashable, Sendable {
    /// A shared `CredentialProfile`'s password.
    case credential(UUID)
    /// The password of a connection's own (`.direct`) identity.
    case connection(UUID)

    public var rawValue: String {
        switch self {
        case let .credential(id): "credential:\(id.uuidString)"
        case let .connection(id): "connection:\(id.uuidString)"
        }
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else {
            return nil
        }
        switch parts[0] {
        case "credential": self = .credential(id)
        case "connection": self = .connection(id)
        default: return nil
        }
    }
}

public enum SecretStoreError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain: \(message)"
        case .invalidData:
            return "The Keychain item could not be read."
        }
    }
}

/// Where passwords go. Calls can block on the Keychain's access dialog, so call them off the
/// main actor (`SecretStore` methods are synchronous on purpose; wrap them in a detached task).
public protocol SecretStore: Sendable {
    func password(for account: SecretAccount) throws(SecretStoreError) -> String?
    func setPassword(_ password: String, for account: SecretAccount) throws(SecretStoreError)
    func deletePassword(for account: SecretAccount) throws(SecretStoreError)
    /// Every account this store holds an item for, to clean up orphans.
    func allAccounts() throws(SecretStoreError) -> [SecretAccount]
}

/// macOS Keychain Services, generic passwords under one service name.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ account: SecretAccount) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
        ]
    }

    public func password(for account: SecretAccount) throws(SecretStoreError) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                throw .invalidData
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status)
        }
    }

    public func setPassword(_ password: String, for account: SecretAccount) throws(SecretStoreError) {
        let data = Data(password.utf8)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrLabel: "RDP Manager (\(account.rawValue))",
            kSecAttrDescription: "RDP Manager password",
        ]
        let updateStatus = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account)
            add.merge(attributes) { $1 }
            // Only while the Mac is unlocked, and never migrated to another device by a backup.
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw .keychain(addStatus)
            }
        default:
            throw .keychain(updateStatus)
        }
    }

    public func deletePassword(for account: SecretAccount) throws(SecretStoreError) {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(status)
        }
    }

    public func allAccounts() throws(SecretStoreError) -> [SecretAccount] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[CFString: Any]] ?? []
            return items.compactMap { ($0[kSecAttrAccount] as? String).flatMap(SecretAccount.init(rawValue:)) }
        case errSecItemNotFound:
            return []
        default:
            throw .keychain(status)
        }
    }
}

/// Keeps passwords in memory only: for tests, and for "use once, don't save" sign-ins.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SecretAccount: String] = [:]

    public init() {}

    public func password(for account: SecretAccount) throws(SecretStoreError) -> String? {
        lock.withLock { items[account] }
    }

    public func setPassword(_ password: String, for account: SecretAccount) throws(SecretStoreError) {
        lock.withLock { items[account] = password }
    }

    public func deletePassword(for account: SecretAccount) throws(SecretStoreError) {
        _ = lock.withLock { items.removeValue(forKey: account) }
    }

    public func allAccounts() throws(SecretStoreError) -> [SecretAccount] {
        lock.withLock { Array(items.keys) }
    }
}
