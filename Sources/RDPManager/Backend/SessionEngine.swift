import AppKit
import RDPManagerCore

/// What a session asks an engine to connect with.
struct EngineConnectRequest {
    var address: HostAddress
    var username: String
    var domain: String
    /// In memory only for the attempt; never logged.
    var password: String
    var settings: ResolvedSettings
    var clipboardEnabled: Bool
}

/// Measured numbers of a live session. Nil means the engine does not measure it.
struct SessionStatistics: Equatable {
    var framesPerSecond: Double?
    var wireMegabitsPerSecond: Double?
    var averageDecodeMilliseconds: Double?
    var hardwareDecoding: Bool?
    var codec: String?
    var decodedFrames: Int
    var failedDecodes: Int
    var firstFrameMilliseconds: Double?
}

/// How an attempt ended, as the engine read it.
enum EngineEnd {
    /// The sign-in was missing or refused before the desktop showed: ask again.
    case promptForCredentials(message: String)
    case end(SessionEnd)
}

/// A key on the remote keyboard, by its scancode.
struct RemoteScancode: Hashable, Sendable {
    var code: UInt16
    var extended: Bool

    static let control = RemoteScancode(code: 0x1D, extended: false)
    static let alt = RemoteScancode(code: 0x38, extended: false)
    static let delete = RemoteScancode(code: 0x53, extended: true)
    static let windows = RemoteScancode(code: 0x5B, extended: true)
    static let tab = RemoteScancode(code: 0x0F, extended: false)
    static let enter = RemoteScancode(code: 0x1C, extended: false)
    static let escape = RemoteScancode(code: 0x01, extended: false)
    static let r = RemoteScancode(code: 0x13, extended: false)
    static let e = RemoteScancode(code: 0x12, extended: false)
    static let l = RemoteScancode(code: 0x26, extended: false)
}

@MainActor
protocol SessionEngineDelegate: AnyObject {
    /// The server's certificate, whether or not it was accepted.
    func engine(receivedCertificateSHA256 sha256: String?, trustedBySystem: Bool?, trustedByUser: Bool)
    /// The certificate was refused before any credential was sent; the user decides.
    func engine(refusedCertificate issue: CertificateIssue)
    /// The server activated the session; `credentialsVerified` when it checked the password
    /// first (NLA), so the password is worth saving.
    func engineActivated(credentialsVerified: Bool)
    /// The desktop showed (`firstFrame`) or changed size.
    func engine(showedDesktopOfSize size: CGSize, firstFrame: Bool)
    func engine(updatedStatistics statistics: SessionStatistics?, tlsProtocol: String?, connectAttempt: Int?)
    /// The attempt ended without being stopped by the session.
    func engine(ended end: EngineEnd, showedDesktop: Bool)
}

/// One RDP implementation. A session owns one engine and calls `start` for every attempt; the
/// engine reports back through its delegate on the main actor, in order, and reports nothing
/// after `stop` returns.
@MainActor
protocol SessionEngine: AnyObject {
    var kind: RDPEngineKind { get }
    /// The view that shows the remote desktop and takes its input.
    var surface: NSView { get }
    var hasInputFocus: Bool { get }
    var delegate: SessionEngineDelegate? { get set }

    func start(_ request: EngineConnectRequest)
    func stop()
    func focusInput()
    /// Presses `keys` in order and releases them in reverse.
    func sendKeyChord(_ keys: [RemoteScancode])
    /// Types `text` as Unicode key events.
    func sendText(_ text: String)
    func setClipboardEnabled(_ enabled: Bool)
    /// Waits for the engine thread to tell the server goodbye, as the app does at quit.
    func waitUntilEnded(timeout: TimeInterval) async
}
