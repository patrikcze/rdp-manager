import AppKit
import Observation
import RDPKit
import RDPManagerCore

/// The prompt shown when a session needs credentials.
struct CredentialPrompt: Equatable {
    var username: String
    var domain: String
    var message: String?
    /// Where "Save in Keychain" writes; nil when the session cannot save (Quick Connect).
    var saveAccount: SecretAccount?
}

/// One remote desktop connection and the state the UI observes: credentials, certificate
/// decisions, reconnects and lifecycle, whatever engine runs it. Every session is
/// independent; closing one leaves the others alone.
@MainActor
@Observable
final class RemoteSession: Identifiable {
    let id = UUID()
    /// The saved connection this session opened, or nil for Quick Connect.
    let connectionID: UUID?
    private(set) var title: String
    let address: HostAddress
    private(set) var settings: ResolvedSettings
    let engineChoice: EngineChoice

    private(set) var phase: SessionPhase = .idle
    private(set) var connectedAt: Date?
    private(set) var reconnectCount = 0
    private(set) var desktopPixelSize: CGSize?
    private(set) var signedInAs: String?
    private(set) var certificateSHA256: String?
    private(set) var certificateTrustedBySystem: Bool?
    private(set) var certificateTrustedByUser = false
    /// The session runs on Standard RDP Security: nothing verifies the server.
    private(set) var isUnverifiedServer = false
    /// Asks the user to allow Standard RDP Security for this session; set by the workspace.
    @ObservationIgnored var confirmStandardRDPSecurity: @MainActor (RemoteSession) -> Bool = { _ in false }
    @ObservationIgnored private var standardRDPConfirmed = false
    private(set) var tlsProtocol: String?
    private(set) var credentialPrompt: CredentialPrompt?
    private(set) var statistics: SessionStatistics?
    private(set) var clipboardEnabled: Bool
    private(set) var lastNotice: String?
    private(set) var isSigningOut = false

    /// Called once per connection that showed the desktop, to record "last connected".
    @ObservationIgnored var onDesktopShown: ((RemoteSession) -> Void)?
    /// Called when the user asked to save credentials and the server verified them.
    @ObservationIgnored var onVerifiedCredentials: ((RemoteSession, _ username: String, _ domain: String) -> Void)?

    @ObservationIgnored private let engine: SessionEngine
    @ObservationIgnored private let credentials: CredentialService
    @ObservationIgnored private let trustStore: CertificateTrustStore
    @ObservationIgnored private let profiles: [CredentialProfile]
    @ObservationIgnored private let reconnectPolicy = ReconnectPolicy()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var credentialTask: Task<Void, Never>?
    @ObservationIgnored private var signOutTask: Task<Void, Never>?
    @ObservationIgnored private var refusedCertificate: CertificateIssue?
    @ObservationIgnored private var isRunning = false

    /// The identity this attempt signs in with. The password stays in memory only for the
    /// session's lifetime, so Reconnect needs no new prompt; it is cleared when refused.
    @ObservationIgnored private var username = ""
    @ObservationIgnored private var domain = ""
    @ObservationIgnored private var password = ""
    @ObservationIgnored private var saveVerifiedPasswordTo: SecretAccount?
    @ObservationIgnored private var didAskForCredentials = false
    @ObservationIgnored private var isClosed = false

    init(
        connectionID: UUID?,
        title: String,
        address: HostAddress,
        settings: ResolvedSettings,
        profiles: [CredentialProfile],
        credentials: CredentialService,
        trustStore: CertificateTrustStore
    ) {
        self.connectionID = connectionID
        self.title = title
        self.address = address
        self.settings = settings
        self.profiles = profiles
        self.credentials = credentials
        self.trustStore = trustStore
        clipboardEnabled = settings.clipboardEnabled
        engineChoice = settings.engine
        switch engineChoice.kind {
        case .rdpKit:
            engine = RDPKitEngine(trustStore: trustStore, sendsCommandShortcutsToRemote: settings.sendsCommandShortcutsToRemote)
        case .freeRDP:
            engine = FreeRDPEngine(trustStore: trustStore, sendsCommandShortcutsToRemote: settings.sendsCommandShortcutsToRemote)
        }
        engine.delegate = self
    }

    var hostLabel: String {
        address.port == 3389 ? address.host : "\(address.host):\(address.port)"
    }

    var surface: NSView { engine.surface }
    var engineKind: RDPEngineKind { engine.kind }
    var hasInputFocus: Bool { engine.hasInputFocus }

    // MARK: - Lifecycle

    /// Starts a connection the user asked for: resets automatic reconnects, finds the
    /// password (Keychain, then prompt) and connects.
    func connect() {
        guard isClosed == false else { return }
        cancelPendingWork()
        reconnectCount = 0
        // Standard RDP Security can't verify the server, so the user confirms it before any
        // password is read or typed. Once per session tab; automatic reconnects don't ask.
        if settings.security == .standardRDP, standardRDPConfirmed == false {
            guard confirmStandardRDPSecurity(self) else {
                phase = .ended(SessionEnd(
                    kind: .userDisconnected, category: .none, title: "Not connected",
                    message: "Standard RDP Security was not allowed. Choose another security layer in Edit… to connect."
                ))
                return
            }
            standardRDPConfirmed = true
        }
        lastNotice = engineChoice.ignoredSettings.isEmpty
            ? nil
            : "RDPKit can't redirect \(engineChoice.ignoredSettings.joined(separator: ", ")). Set the engine to Automatic or FreeRDP."
        if password.isEmpty == false || didAskForCredentials {
            startAttempt()
            return
        }
        switch CredentialPlan.plan(for: settings.credential, connectionID: connectionID, profiles: profiles) {
        case let .prompt(username, domain, saveTo):
            askForCredentials(username: username, domain: domain, message: nil, saveTo: saveTo)
        case let .keychain(username, domain, account):
            self.username = username
            self.domain = domain
            phase = .resolvingCredentials
            credentialTask = Task { [weak self, credentials] in
                let stored: String?
                do {
                    stored = try await credentials.password(for: account)
                } catch {
                    self?.askForCredentials(
                        username: username, domain: domain,
                        message: "The saved password could not be read: \(error.localizedDescription)",
                        saveTo: account
                    )
                    return
                }
                guard let self, Task.isCancelled == false else { return }
                if let stored, stored.isEmpty == false {
                    password = stored
                    startAttempt()
                } else {
                    askForCredentials(username: username, domain: domain, message: nil, saveTo: account)
                }
            }
        }
    }

    /// Credentials the user typed. `save` writes them to the Keychain once the server has
    /// verified them, never before.
    func submitCredentials(username: String, domain: String, password: String, save: Bool) {
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        saveVerifiedPasswordTo = save ? credentialPrompt?.saveAccount : nil
        credentialPrompt = nil
        didAskForCredentials = true
        reconnectCount = 0
        startAttempt()
    }

    func cancelCredentialPrompt() {
        credentialPrompt = nil
        phase = .ended(SessionEnd(kind: .userDisconnected, category: .none, title: "Not connected", message: "Sign-in was cancelled."))
    }

    /// Ends the RDP connection. The Windows session stays on the server (disconnected, not
    /// signed out) until its policy ends it.
    func disconnect() {
        cancelPendingWork()
        stopEngine()
        if case .ended = phase {} else {
            phase = .ended(.userDisconnected)
        }
    }

    /// Signs out of the Windows session: opens Run (Win+R), types `logoff` and presses Enter,
    /// as an administrator would. The server then ends the connection, which shows as
    /// "Signed out". Fails quietly where policy disables the Run dialog; the session stays.
    func signOut() {
        guard phase.isActive, isSigningOut == false else { return }
        isSigningOut = true
        lastNotice = "Signing out of the Windows session…"
        signOutTask = Task { [weak self] in
            guard let self else { return }
            await runCommand("logoff")
            try? await Task.sleep(for: .seconds(15))
            // Still connected: the Run dialog was blocked or the command refused.
            if Task.isCancelled == false, phase.isActive {
                isSigningOut = false
                lastNotice = "The session did not sign out. Run may be disabled by policy; sign out from the Start menu."
            }
        }
    }

    /// Runs `command` in the remote session through the Run dialog (Win+R, type, Enter).
    func runCommand(_ command: String) async {
        guard phase.isActive else { return }
        engine.focusInput()
        engine.sendKeyChord([.windows, .r])
        try? await Task.sleep(for: .milliseconds(900))
        // One character at a time: Windows drops Unicode key events sent in a burst.
        for character in command {
            guard phase.isActive, Task.isCancelled == false else { return }
            engine.sendText(String(character))
            try? await Task.sleep(for: .milliseconds(15))
        }
        try? await Task.sleep(for: .milliseconds(250))
        engine.sendKeyChord([.enter])
    }

    /// Disconnects and releases everything; the session cannot be used again.
    func close() {
        guard isClosed == false else { return }
        disconnect()
        isClosed = true
        password = ""
    }

    func waitUntilEnded(timeout: TimeInterval) async {
        await engine.waitUntilEnded(timeout: timeout)
    }

    // MARK: - Certificate decision

    /// Trusts the certificate that was refused, for this host and port, and connects again.
    func trustCertificateAndConnect() {
        guard let issue = refusedCertificate,
              let key = RDPServerCertificateTrustKey(host: issue.host, port: issue.port, sha256: issue.sha256)
        else { return }
        trustStore.trust(key)
        refusedCertificate = nil
        startAttempt()
    }

    func rejectCertificate() {
        refusedCertificate = nil
        phase = .ended(SessionEnd(
            kind: .failed, category: .certificate, title: "Certificate not trusted",
            message: "The connection was closed before any credential was sent."
        ))
    }

    // MARK: - Commands

    func focusRemoteInput() {
        engine.focusInput()
    }

    /// Ctrl+Alt+Del on the remote computer (the Secure Attention Sequence goes as scancodes;
    /// the Mac never sees it). Ctrl+Option+End in the session does the same.
    func sendCtrlAltDelete() {
        engine.sendKeyChord([.control, .alt, .delete])
    }

    /// The Windows key with `key`, or alone when nil.
    func sendWindowsKey(with key: RemoteScancode?) {
        engine.sendKeyChord([.windows] + (key.map { [$0] } ?? []))
    }

    func sendAltTab() {
        engine.sendKeyChord([.alt, .tab])
    }

    func setClipboardEnabled(_ enabled: Bool) {
        clipboardEnabled = enabled
        engine.setClipboardEnabled(enabled)
        if enabled, settings.clipboardEnabled == false, phase.isActive {
            lastNotice = "Clipboard sharing starts with the next connection."
        }
    }

    // MARK: - Attempts

    private func askForCredentials(username: String, domain: String, message: String?, saveTo: SecretAccount?) {
        credentialPrompt = CredentialPrompt(username: username, domain: domain, message: message, saveAccount: saveTo)
        phase = .awaitingCredentials(message: message)
    }

    private func startAttempt() {
        stopEngine()
        if reconnectCount == 0 {
            phase = .connecting(detail: nil)
        }
        statistics = nil
        certificateSHA256 = nil
        certificateTrustedBySystem = nil
        certificateTrustedByUser = false
        isUnverifiedServer = false
        tlsProtocol = nil
        desktopPixelSize = nil
        isSigningOut = false
        let identity = Self.splitDomain(username: username, domain: domain)
        signedInAs = identity.username.isEmpty ? nil : (identity.domain.isEmpty ? identity.username : "\(identity.domain)\\\(identity.username)")
        isRunning = true
        engine.start(EngineConnectRequest(
            address: address,
            username: identity.username,
            domain: identity.domain,
            password: password,
            settings: settings,
            clipboardEnabled: clipboardEnabled
        ))
    }

    /// `DOMAIN\user` typed into the user name, with no domain, is split as Windows clients do;
    /// `user@domain` (UPN) stays whole.
    nonisolated static func splitDomain(username: String, domain: String) -> (username: String, domain: String) {
        guard domain.isEmpty, let separator = username.firstIndex(of: "\\") else { return (username, domain) }
        return (String(username[username.index(after: separator)...]), String(username[..<separator]))
    }

    private func stopEngine() {
        signOutTask?.cancel()
        signOutTask = nil
        isRunning = false
        engine.stop()
        connectedAt = nil
    }

    private func cancelPendingWork() {
        reconnectTask?.cancel()
        reconnectTask = nil
        credentialTask?.cancel()
        credentialTask = nil
    }
}

// MARK: - Engine events

extension RemoteSession: SessionEngineDelegate {
    func engine(receivedCertificateSHA256 sha256: String?, trustedBySystem: Bool?, trustedByUser: Bool) {
        certificateSHA256 = sha256
        certificateTrustedBySystem = trustedBySystem
        certificateTrustedByUser = trustedByUser
        isUnverifiedServer = sha256 == nil && trustedBySystem == nil
    }

    func engine(refusedCertificate issue: CertificateIssue) {
        refusedCertificate = issue
        stopEngine()
        phase = .awaitingCertificateDecision(issue)
    }

    func engineActivated(credentialsVerified: Bool) {
        // Over NLA the server checked the password before activating: only then is it worth
        // saving.
        guard let account = saveVerifiedPasswordTo, credentialsVerified else { return }
        saveVerifiedPasswordTo = nil
        let password = password
        Task { [weak self, credentials] in
            do {
                try await credentials.setPassword(password, for: account)
                if let self {
                    onVerifiedCredentials?(self, username, domain)
                }
            } catch {
                self?.lastNotice = "The password could not be saved: \(error.localizedDescription)"
            }
        }
    }

    func engine(showedDesktopOfSize size: CGSize, firstFrame: Bool) {
        desktopPixelSize = size
        guard firstFrame else { return }
        reconnectCount = 0
        connectedAt = Date()
        phase = .connected
        if isUnverifiedServer {
            lastNotice = "Standard RDP Security: the server's identity is not verified and the encryption is weak."
        }
        onDesktopShown?(self)
    }

    func engine(updatedStatistics statistics: SessionStatistics?, tlsProtocol: String?, connectAttempt: Int?) {
        self.statistics = statistics
        if let tlsProtocol {
            self.tlsProtocol = tlsProtocol
        }
        if case .connecting = phase, let connectAttempt, connectAttempt > 1 {
            phase = .connecting(detail: "Trying again (\(connectAttempt)/3)…")
        }
    }

    func engine(ended end: EngineEnd, showedDesktop: Bool) {
        isRunning = false
        connectedAt = nil
        signOutTask?.cancel()
        isSigningOut = false
        switch end {
        case let .promptForCredentials(message):
            password = ""
            didAskForCredentials = false
            let saveTo: SecretAccount? = switch CredentialPlan.plan(for: settings.credential, connectionID: connectionID, profiles: profiles) {
            case let .keychain(_, _, account): account
            case let .prompt(_, _, account): account
            }
            askForCredentials(username: username, domain: domain, message: message, saveTo: saveTo)
        case let .end(end):
            if end.category == .authentication {
                password = ""
                didAskForCredentials = false
            }
            switch reconnectPolicy.decision(
                after: end,
                wasShowingDesktop: showedDesktop || reconnectCount > 0,
                attemptsMade: reconnectCount,
                enabled: settings.autoReconnect
            ) {
            case let .reconnect(attempt, delay):
                reconnectCount = attempt
                phase = .reconnecting(attempt: attempt, of: reconnectPolicy.maxAttempts)
                reconnectTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard Task.isCancelled == false else { return }
                    self?.startAttempt()
                }
            case .stop:
                phase = .ended(end)
            }
        }
    }
}
