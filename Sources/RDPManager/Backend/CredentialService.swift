import Foundation
import RDPManagerCore

/// Keychain access off the main actor: a read or write can block on macOS's access dialog,
/// which must never freeze the window.
struct CredentialService: Sendable {
    let store: any SecretStore

    func password(for account: SecretAccount) async throws -> String? {
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            try store.password(for: account)
        }.value
    }

    func setPassword(_ password: String, for account: SecretAccount) async throws {
        let store = store
        try await Task.detached(priority: .userInitiated) {
            try store.setPassword(password, for: account)
        }.value
    }

    func deletePassword(for account: SecretAccount) async throws {
        let store = store
        try await Task.detached(priority: .userInitiated) {
            try store.deletePassword(for: account)
        }.value
    }

    /// Never reads the secret, so it neither prompts nor fails on a Keychain item an earlier
    /// build of the app created.
    func hasPassword(for account: SecretAccount) async -> Bool {
        let store = store
        return await Task.detached(priority: .userInitiated) {
            (try? store.hasPassword(for: account)) ?? false
        }.value
    }

    /// Deletes Keychain items nothing refers to any more; returns how many.
    func removeOrphans(keeping isReferenced: @escaping @Sendable (SecretAccount) -> Bool) async throws -> Int {
        let store = store
        return try await Task.detached(priority: .utility) {
            let orphans = try store.allAccounts().filter { isReferenced($0) == false }
            for account in orphans {
                try store.deletePassword(for: account)
            }
            return orphans.count
        }.value
    }
}
