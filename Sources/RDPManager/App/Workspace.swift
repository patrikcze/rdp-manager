import AppKit
import Observation
import RDPManagerCore

/// What the sidebar has selected; the Overview tab lists what it contains.
enum SidebarSelection: Hashable {
    case favorites
    case recent
    case allConnections
    case folder(UUID)
    case connection(UUID)
    case credentials
}

/// The tab shown in the main window: the Overview, or a session.
enum WorkspaceTab: Hashable {
    case overview
    case session(UUID)
}

/// Open sessions of both protocols and how they are arranged: tabs in the main window, or
/// detached windows.
@MainActor
@Observable
final class Workspace {
    private(set) var sessions: [WorkspaceSession] = []
    var selectedTab: WorkspaceTab = .overview
    private(set) var detachedSessionIDs: Set<UUID> = []
    /// Hides the sidebar, tab bar and inspector so the remote desktop gets the whole window.
    var isFocusMode = false

    @ObservationIgnored private let inventory: InventoryStore
    @ObservationIgnored private let credentials: CredentialService
    @ObservationIgnored private let trustStore: CertificateTrustStore
    /// Appearance of new and open terminals; set by the app from Settings.
    @ObservationIgnored var terminalPreferences: TerminalPreferences {
        didSet {
            for case let .ssh(session) in sessions { session.apply(terminalPreferences) }
        }
    }

    init(inventory: InventoryStore, credentials: CredentialService, trustStore: CertificateTrustStore,
         terminalPreferences: TerminalPreferences = TerminalPreferences()) {
        self.inventory = inventory
        self.credentials = credentials
        self.trustStore = trustStore
        self.terminalPreferences = terminalPreferences
    }

    var tabbedSessions: [WorkspaceSession] {
        sessions.filter { detachedSessionIDs.contains($0.id) == false }
    }

    var selectedSession: WorkspaceSession? {
        guard case let .session(id) = selectedTab else { return nil }
        return session(id)
    }

    func session(_ id: UUID) -> WorkspaceSession? {
        sessions.first { $0.id == id }
    }

    /// Sessions open for a saved connection, for the sidebar's status dots.
    func sessions(for connectionID: UUID) -> [WorkspaceSession] {
        sessions.filter { $0.connectionID == connectionID }
    }

    // MARK: - Opening

    /// Opens a saved connection in a new tab, or shows the tab already open for it.
    func open(_ connectionID: UUID, newSession: Bool = false) {
        if newSession == false, let existing = sessions(for: connectionID).first {
            show(existing)
            if existing.isEnded {
                existing.connect()
            }
            return
        }
        guard let connection = inventory.connection(connectionID) else { return }
        if connection.isSSH {
            openSSH(connection)
            return
        }
        let session = RemoteSession(
            connectionID: connection.id,
            title: connection.name,
            address: HostAddress(host: connection.host, port: connection.port),
            settings: inventory.resolvedSettings(for: connection),
            profiles: inventory.credentials,
            credentials: credentials,
            trustStore: trustStore
        )
        add(session)
    }

    /// An SSH session for a saved connection: its resolved SSH settings, its user, and the
    /// Keychain accounts its prompts may be answered from.
    private func openSSH(_ connection: Connection) {
        let settings = inventory.resolvedSSHSettings(for: connection)
        var passwordAccount: SecretAccount?
        var passphraseAccount: SecretAccount?
        var profileKey: String?
        switch settings.secret {
        case .none:
            // Nothing saved yet; a password typed at the prompt may be saved for this host.
            passwordAccount = .sshPassword(connection.id)
        case .connectionSecret:
            passwordAccount = .sshPassword(connection.id)
        case let .profile(id):
            if let profile = inventory.credential(id) {
                switch profile.kind {
                case .sshPassword: passwordAccount = .credential(id)
                case .sshKey:
                    passphraseAccount = .sshKeyPassphrase(id)
                    profileKey = profile.keyPath
                case .rdpPassword: break // never used for SSH
                }
            }
        }
        let target = SSHTarget(
            host: connection.host, port: connection.port,
            username: inventory.sshUsername(for: connection),
            settings: settings, profileKeyPath: profileKey
        )
        let session = SSHSession(
            connectionID: connection.id, title: connection.name, target: target,
            passwordAccount: passwordAccount, passphraseAccount: passphraseAccount,
            credentials: credentials, preferences: terminalPreferences
        )
        addSSH(session)
    }

    /// An SSH session to a typed address. Nothing is saved, passwords included.
    func quickConnectSSH(username: String, address: HostAddress) {
        let session = SSHSession(
            connectionID: nil, title: address.host,
            target: SSHTarget(host: address.host, port: address.port, username: username),
            passwordAccount: nil, passphraseAccount: nil,
            credentials: credentials, preferences: terminalPreferences
        )
        addSSH(session)
    }

    private func addSSH(_ session: SSHSession) {
        session.onConnected = { [weak inventory] session in
            if let id = session.connectionID { inventory?.recordConnected(id) }
        }
        session.onSavedConnectionPassword = { [weak inventory] session in
            // A connection that had nothing saved now uses its own saved password.
            guard let inventory, let id = session.connectionID, var connection = inventory.connection(id) else { return }
            if inventory.resolvedSSHSettings(for: connection).secret == SSHSecretSource.none {
                connection.ssh.secret = .connectionSecret
                inventory.update(connection)
            }
        }
        sessions.append(.ssh(session))
        selectedTab = .session(session.id)
        // Start once the tab's view is in the window, so the first terminal size is the view's.
        Task { @MainActor in
            await Task.yield()
            session.connect()
        }
    }

    /// Connects to a typed address without saving it.
    func quickConnect(_ address: HostAddress, settings: ResolvedSettings = .builtIn) {
        let session = RemoteSession(
            connectionID: nil,
            title: address.host,
            address: address,
            settings: settings,
            profiles: inventory.credentials,
            credentials: credentials,
            trustStore: trustStore
        )
        add(session)
    }

    private func add(_ session: RemoteSession) {
        session.confirmStandardRDPSecurity = { confirmStandardRDPSecurity(for: $0) }
        session.onDesktopShown = { [weak inventory] session in
            if let id = session.connectionID {
                inventory?.recordConnected(id)
            }
        }
        session.onVerifiedCredentials = { [weak inventory] session, username, domain in
            // A connection that asked every time now has a saved identity of its own.
            guard let inventory, let id = session.connectionID, var connection = inventory.connection(id) else { return }
            if inventory.resolvedSettings(for: connection).credential == .prompt {
                connection.settings.credential = .direct(username: username, domain: domain)
                inventory.update(connection)
            }
        }
        sessions.append(.rdp(session))
        selectedTab = .session(session.id)
        // Connect once the tab's view is in the window, so the first desktop size is the view's.
        Task { @MainActor in
            await Task.yield()
            session.connect()
        }
    }

    func show(_ session: WorkspaceSession) {
        if detachedSessionIDs.contains(session.id) {
            NSApp.windows.first { $0.identifier?.rawValue == Self.windowIdentifier(for: session.id) }?
                .makeKeyAndOrderFront(nil)
        } else {
            selectedTab = .session(session.id)
        }
    }

    // MARK: - Closing

    func close(_ session: WorkspaceSession) {
        session.close()
        if selectedTab == .session(session.id) {
            let tabs = tabbedSessions
            let index = tabs.firstIndex { $0.id == session.id } ?? 0
            let remaining = tabs.filter { $0.id != session.id }
            selectedTab = remaining.isEmpty ? .overview : .session(remaining[min(index, remaining.count - 1)].id)
        }
        detachedSessionIDs.remove(session.id)
        sessions.removeAll { $0.id == session.id }
    }

    func closeAll() async {
        let open = sessions
        for session in open {
            session.close()
        }
        // Give each engine thread a moment to tell its server goodbye.
        for session in open {
            await session.waitUntilEnded(timeout: 2)
        }
        sessions.removeAll()
    }

    var activeSessionCount: Int {
        sessions.count { $0.status.isActive || $0.status.isInProgress || $0.status.tone == .needsUser }
    }

    // MARK: - Tabs and windows

    func moveTab(_ id: UUID, before target: UUID?) {
        guard let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: from)
        if let target, let to = sessions.firstIndex(where: { $0.id == target }) {
            sessions.insert(session, at: to)
        } else {
            sessions.append(session)
        }
    }

    func selectTab(offset: Int) {
        let tabs: [WorkspaceTab] = [.overview] + tabbedSessions.map { .session($0.id) }
        guard let index = tabs.firstIndex(of: selectedTab) else { return }
        selectedTab = tabs[(index + offset + tabs.count) % tabs.count]
    }

    func selectTab(number: Int) {
        let tabs = tabbedSessions
        if number == 0 {
            selectedTab = .overview
        } else if number <= tabs.count {
            selectedTab = .session(tabs[number - 1].id)
        }
    }

    func markDetached(_ id: UUID) {
        detachedSessionIDs.insert(id)
        if selectedTab == .session(id) {
            selectedTab = tabbedSessions.last.map { .session($0.id) } ?? .overview
        }
    }

    /// The detached window closed or the user moved the session back into the main window.
    func reattach(_ id: UUID) {
        guard detachedSessionIDs.remove(id) != nil else { return }
        selectedTab = .session(id)
    }

    static func windowIdentifier(for sessionID: UUID) -> String {
        "session-\(sessionID.uuidString)"
    }
}
