import AppKit
import RDPManagerCore

/// A session in the workspace, whatever its protocol. Tabs, windows, status dots, close and
/// quit work through this; views switch on the case only where the protocols differ, so an SSH
/// session never offers an RDP-only action, or the reverse.
enum WorkspaceSession: Identifiable, Equatable {
    case rdp(RemoteSession)
    case ssh(SSHSession)

    var id: UUID {
        switch self {
        case let .rdp(session): session.id
        case let .ssh(session): session.id
        }
    }

    static func == (lhs: WorkspaceSession, rhs: WorkspaceSession) -> Bool {
        lhs.id == rhs.id
    }

    var connectionProtocol: ConnectionProtocol {
        switch self {
        case .rdp: .rdp
        case .ssh: .ssh
        }
    }

    /// The saved connection this session opened, or nil for Quick Connect.
    @MainActor var connectionID: UUID? {
        switch self {
        case let .rdp(session): session.connectionID
        case let .ssh(session): session.connectionID
        }
    }

    @MainActor var title: String {
        switch self {
        case let .rdp(session): session.title
        case let .ssh(session): session.title
        }
    }

    @MainActor var hostLabel: String {
        switch self {
        case let .rdp(session): session.hostLabel
        case let .ssh(session): session.hostLabel
        }
    }

    @MainActor var status: SessionStatus {
        switch self {
        case let .rdp(session): session.phase.status
        case let .ssh(session): session.status
        }
    }

    @MainActor var surface: NSView {
        switch self {
        case let .rdp(session): session.surface
        case let .ssh(session): session.surface
        }
    }

    @MainActor func connect() {
        switch self {
        case let .rdp(session): session.connect()
        case let .ssh(session): session.connect()
        }
    }

    @MainActor func disconnect() {
        switch self {
        case let .rdp(session): session.disconnect()
        case let .ssh(session): session.disconnect()
        }
    }

    @MainActor func close() {
        switch self {
        case let .rdp(session): session.close()
        case let .ssh(session): session.close()
        }
    }

    @MainActor func focusInput() {
        switch self {
        case let .rdp(session): session.focusRemoteInput()
        case let .ssh(session): session.focusInput()
        }
    }

    @MainActor func waitUntilEnded(timeout: TimeInterval) async {
        switch self {
        case let .rdp(session): await session.waitUntilEnded(timeout: timeout)
        case let .ssh(session): await session.waitUntilEnded(timeout: timeout)
        }
    }

    @MainActor var isEnded: Bool {
        switch self {
        case let .rdp(session): if case .ended = session.phase { true } else { false }
        case let .ssh(session): session.phase.isEnded
        }
    }

    var symbol: String {
        connectionProtocol.symbol
    }
}

extension ConnectionProtocol {
    /// SF Symbol for the protocol, shared by the sidebar, tabs and tables.
    var symbol: String {
        switch self {
        case .rdp: "desktopcomputer"
        case .ssh: "terminal"
        }
    }
}
