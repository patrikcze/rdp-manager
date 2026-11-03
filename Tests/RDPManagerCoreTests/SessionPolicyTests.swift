import Foundation
import Testing
@testable import RDPManagerCore

@Suite("Session reconnect and credential policy")
struct SessionPolicyTests {
    private let policy = ReconnectPolicy()
    private let networkDrop = SessionEnd(kind: .failed, category: .network, title: "Connection lost", message: "")

    @Test func reconnectsANetworkDropWithBackoffThenStops() {
        #expect(policy.decision(after: networkDrop, wasShowingDesktop: true, attemptsMade: 0, enabled: true)
            == .reconnect(attempt: 1, after: .seconds(2)))
        #expect(policy.decision(after: networkDrop, wasShowingDesktop: true, attemptsMade: 2, enabled: true)
            == .reconnect(attempt: 3, after: .seconds(10)))
        // Bounded: no infinite loop.
        #expect(policy.decision(after: networkDrop, wasShowingDesktop: true, attemptsMade: 3, enabled: true) == .stop)
    }

    @Test(arguments: [FailureCategory.authentication, .certificate, .server, .unsupported, .client])
    func neverReconnectsNonNetworkFailures(category: FailureCategory) {
        let end = SessionEnd(kind: .failed, category: category, title: "", message: "")
        #expect(policy.decision(after: end, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
    }

    @Test func neverReconnectsWhatNeverShowedTheDesktopOrWasEndedOnPurpose() {
        #expect(policy.decision(after: networkDrop, wasShowingDesktop: false, attemptsMade: 0, enabled: true) == .stop)
        #expect(policy.decision(after: .userDisconnected, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
        let signedOut = SessionEnd(kind: .remoteEnded, category: .none, title: "", message: "")
        #expect(policy.decision(after: signedOut, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
        #expect(policy.decision(after: networkDrop, wasShowingDesktop: true, attemptsMade: 0, enabled: false) == .stop)
    }

    @Test func credentialPlans() {
        let connectionID = UUID()
        let profile = CredentialProfile(name: "Admin", username: "admin", domain: "EMEA")
        #expect(CredentialPlan.plan(for: .shared(profile.id), connectionID: connectionID, profiles: [profile])
            == .keychain(username: "admin", domain: "EMEA", account: .credential(profile.id)))
        #expect(CredentialPlan.plan(for: .direct(username: "u", domain: "d"), connectionID: connectionID, profiles: [])
            == .keychain(username: "u", domain: "d", account: .connection(connectionID)))
        #expect(CredentialPlan.plan(for: .prompt, connectionID: connectionID, profiles: [])
            == .prompt(username: "", domain: "", saveTo: .connection(connectionID)))
        // A deleted shared profile asks rather than failing silently.
        #expect(CredentialPlan.plan(for: .shared(UUID()), connectionID: connectionID, profiles: [])
            == .prompt(username: "", domain: "", saveTo: nil))
        // Quick Connect has nowhere to save.
        #expect(CredentialPlan.plan(for: .prompt, connectionID: nil, profiles: [])
            == .prompt(username: "", domain: "", saveTo: nil))
    }

    @Test func secretAccountsRoundTrip() throws {
        let id = UUID()
        for account in [SecretAccount.credential(id), .connection(id)] {
            #expect(SecretAccount(rawValue: account.rawValue) == account)
        }
        #expect(SecretAccount(rawValue: "other:\(id.uuidString)") == nil)

        let store = InMemorySecretStore()
        try store.setPassword("s3cret", for: .credential(id))
        #expect(try store.password(for: .credential(id)) == "s3cret")
        try store.deletePassword(for: .credential(id))
        #expect(try store.password(for: .credential(id)) == nil)
    }

    /// Writes, reads and deletes a real login-Keychain item. Opt in: it touches the user's
    /// Keychain. `RDPM_KEYCHAIN_TESTS=1 swift test`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RDPM_KEYCHAIN_TESTS"] == "1"))
    func keychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.rdpmanager.tests.\(UUID().uuidString)")
        let account = SecretAccount.connection(UUID())
        try store.setPassword("first", for: account)
        try store.setPassword("second ✓", for: account)
        #expect(try store.password(for: account) == "second ✓")
        #expect(try store.allAccounts() == [account])
        try store.deletePassword(for: account)
        #expect(try store.password(for: account) == nil)
    }
}
