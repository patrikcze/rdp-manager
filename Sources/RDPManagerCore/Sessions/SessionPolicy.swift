import Foundation

/// Where a session is in its life, as the UI shows it. The backend maps engine events onto
/// these; nothing here is guessed or simulated.
public enum SessionPhase: Equatable, Sendable {
    /// Created, not started.
    case idle
    /// Reading the password from the Keychain (which may show its access dialog).
    case resolvingCredentials
    /// The engine is connecting. `detail` is the engine's own stage or retry note, when known.
    case connecting(detail: String?)
    /// Waiting for the user to enter credentials, saying why when a sign-in was refused.
    case awaitingCredentials(message: String?)
    /// The server's certificate was refused before any credential was sent; the user decides.
    case awaitingCertificateDecision(CertificateIssue)
    /// The remote desktop is showing.
    case connected
    /// The connection dropped; connecting again on its own.
    case reconnecting(attempt: Int, of: Int)
    /// Ended. The session keeps its last state so the user can reconnect.
    case ended(SessionEnd)

    public var isActive: Bool {
        if case .connected = self { true } else { false }
    }

    public var isInProgress: Bool {
        switch self {
        case .resolvingCredentials, .connecting, .reconnecting: true
        default: false
        }
    }

    public var shortLabel: String {
        switch self {
        case .idle: "Not connected"
        case .resolvingCredentials: "Reading Keychain…"
        case .connecting: "Connecting…"
        case .awaitingCredentials: "Sign-in required"
        case .awaitingCertificateDecision: "Certificate needs review"
        case .connected: "Connected"
        case let .reconnecting(attempt, total): "Reconnecting (\(attempt)/\(total))…"
        case let .ended(end): end.kind == .failed ? "Failed" : "Disconnected"
        }
    }
}

public struct CertificateIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Neither macOS nor the user trusts it.
        case untrusted
        /// It differs from the certificate the user trusted for this host and port before.
        case changed
    }

    public var kind: Kind
    public var host: String
    public var port: UInt16
    public var sha256: String?
    public var subject: String?
    public var issuer: String?
    public var validUntil: Date?
    /// What macOS said about the chain, when it had something to say.
    public var systemTrustDetail: String?

    public init(
        kind: Kind,
        host: String,
        port: UInt16,
        sha256: String?,
        subject: String? = nil,
        issuer: String? = nil,
        validUntil: Date? = nil,
        systemTrustDetail: String? = nil
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.sha256 = sha256
        self.subject = subject
        self.issuer = issuer
        self.validUntil = validUntil
        self.systemTrustDetail = systemTrustDetail
    }
}

/// Why a session ended.
public struct SessionEnd: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The user disconnected or closed the session.
        case userDisconnected
        /// The server ended the session normally (sign-out, another connection took over…).
        case remoteEnded
        /// The connection or sign-in failed.
        case failed
    }

    public var kind: Kind
    public var category: FailureCategory
    public var title: String
    public var message: String

    public init(kind: Kind, category: FailureCategory, title: String, message: String) {
        self.kind = kind
        self.category = category
        self.title = title
        self.message = message
    }

    public static let userDisconnected = SessionEnd(
        kind: .userDisconnected,
        category: .none,
        title: "Disconnected",
        message: "You disconnected. The Windows session keeps running on the server until it times out or you sign out."
    )
}

/// What kind of problem ended a session; decides what may happen on its own afterwards.
public enum FailureCategory: Equatable, Sendable {
    case none
    /// Name resolution, TCP, a dropped connection or a timeout.
    case network
    /// Credentials missing or refused. Never retried automatically.
    case authentication
    /// The server's certificate was refused.
    case certificate
    /// The server ended or refused the session for a reason of its own.
    case server
    /// The server needs a protocol or feature the engine lacks.
    case unsupported
    /// Something on this Mac failed.
    case client
}

/// Whether a session that ended reconnects on its own. Bounded, with backoff; only for
/// network failures of a session that was showing the desktop, so a wrong password, a refused
/// certificate or a server that logged the user off never loops.
public struct ReconnectPolicy: Equatable, Sendable {
    public var delays: [Duration]

    public init(delays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]) {
        self.delays = delays
    }

    public var maxAttempts: Int { delays.count }

    public enum Decision: Equatable, Sendable {
        case reconnect(attempt: Int, after: Duration)
        case stop
    }

    /// `attemptsMade` counts automatic reconnects since the desktop last showed.
    public func decision(
        after end: SessionEnd,
        wasShowingDesktop: Bool,
        attemptsMade: Int,
        enabled: Bool
    ) -> Decision {
        guard enabled, end.kind == .failed, end.category == .network, wasShowingDesktop,
              attemptsMade < delays.count
        else {
            return .stop
        }
        return .reconnect(attempt: attemptsMade + 1, after: delays[attemptsMade])
    }
}

/// How a session gets the password it signs in with.
public enum CredentialPlan: Equatable, Sendable {
    /// Ask the user; prefill what is known.
    case prompt(username: String, domain: String, saveTo: SecretAccount?)
    /// Read the Keychain item; ask if it is missing.
    case keychain(username: String, domain: String, account: SecretAccount)

    public static func plan(for assignment: CredentialAssignment, connectionID: UUID?, profiles: [CredentialProfile]) -> CredentialPlan {
        switch assignment {
        case let .shared(id):
            guard let profile = profiles.first(where: { $0.id == id }) else {
                return .prompt(username: "", domain: "", saveTo: nil)
            }
            return .keychain(username: profile.username, domain: profile.domain, account: .credential(id))
        case let .direct(username, domain):
            guard let connectionID else {
                return .prompt(username: username, domain: domain, saveTo: nil)
            }
            return .keychain(username: username, domain: domain, account: .connection(connectionID))
        case .prompt:
            return .prompt(username: "", domain: "", saveTo: connectionID.map(SecretAccount.connection))
        }
    }
}
