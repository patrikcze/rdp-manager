import Foundation
import RDPKit
import RDPManagerCore

/// Turns RDPKit's typed failures into what the user reads, and into the category the
/// reconnect policy goes by. Credential, certificate and network problems are kept apart.
enum SessionEndMapping {
    static let wrongCredentialsMessage = "The user name or password is incorrect."

    static func isWrongCredentials(_ status: RDPLogonStatus) -> Bool {
        [.logonFailure, .wrongPassword, .noSuchUser].contains(status)
    }

    /// What follows a report: ask for credentials again (with why), or end.
    enum Outcome {
        case promptForCredentials(message: String)
        case end(SessionEnd)
    }

    static func outcome(for report: RDPConnectionReport, host: String, showedDesktop: Bool) -> Outcome {
        guard let failure = report.failure else {
            return .end(SessionEnd(
                kind: .remoteEnded,
                category: .none,
                title: "Session ended",
                message: "The remote computer ended the session."
            ))
        }
        // Sign-in problems before the desktop showed ask again rather than end; nothing is
        // retried with the same password.
        if showedDesktop == false {
            switch failure {
            case let .credSSP(status) where isWrongCredentials(status):
                return .promptForCredentials(message: wrongCredentialsMessage)
            case .credentialsRequired, .negotiation(code: .hybridRequiredByServer):
                return .promptForCredentials(message: "This computer requires Network Level Authentication. Enter a user name and password.")
            case .credSSPClosedAfterCredentials:
                return .promptForCredentials(message: "The remote computer closed the connection after the sign-in. The user name or password may be incorrect.")
            default:
                break
            }
        }
        return .end(end(for: failure, report: report, host: host))
    }

    static func end(for failure: RDPConnectionFailure, report: RDPConnectionReport, host: String) -> SessionEnd {
        func failed(_ category: FailureCategory, _ title: String, _ message: String) -> SessionEnd {
            SessionEnd(kind: .failed, category: category, title: title, message: message)
        }
        switch failure {
        case .addressResolution:
            return failed(.network, "Host not found", "“\(host)” could not be resolved. Check the name and your DNS or VPN connection.")
        case let .connect(error):
            return failed(.network, "Can’t reach \(host)", socketMessage(error))
        case let .negotiation(code):
            return failed(.server, "Security negotiation refused", "The remote computer refused the security settings (\(code)).")
        case .noConnectionConfirm:
            return failed(.network, "No Remote Desktop service", "Something answered on this port, but it is not a Remote Desktop server, or a firewall or connection limit blocked it.")
        case .unsupportedSecurityProtocol:
            return failed(.unsupported, "Unsupported security", "The server only offers Standard RDP Security. Choose “Standard RDP Security” under Security in this connection's settings, or enable TLS or NLA on the server.")
        case .tls:
            return failed(.network, "Secure connection failed", "The TLS handshake failed or the server's certificate could not be read.")
        case .tlsKeyUsageIncorrect:
            return failed(.server, "Certificate key usage", "The server's certificate does not allow the key exchange in use.")
        case let .legacyCredSSPVersion(version):
            return failed(.unsupported, "Outdated server security", "The server uses CredSSP version \(version), which is vulnerable to CVE-2018-0886. Update the server; RDP Manager will not send credentials to it.")
        case .credentialsRequired:
            return failed(.authentication, "Sign-in required", "The server requires Network Level Authentication.")
        case let .credSSP(status):
            return failed(.authentication, "Sign-in refused", logonMessage(status))
        case .credSSPClosedAfterCredentials:
            return failed(.authentication, "Sign-in refused", "The server closed the connection after the sign-in.")
        case .earlyUserAuthorizationDenied:
            return failed(.authentication, "Access denied", "The server denied this account access.")
        case .rdSTLS:
            return failed(.authentication, "Redirected sign-in refused", "The redirected server refused the sign-in.")
        case let .licensing(code):
            return failed(.server, "Licensing failed", String(format: "Remote Desktop licensing failed (0x%08X). Contact the server's administrator.", code))
        case let .serverTermination(termination):
            return SessionEnd(
                kind: termination.isNormalEnd ? .remoteEnded : .failed,
                category: termination.category == .accessDenied || termination.category == .freshCredentialsRequired ? .authentication : .server,
                title: terminationTitle(termination.category),
                message: termination.description
            )
        case .connectionLost:
            return failed(.network, "Connection lost", "The network connection to \(host) was interrupted.")
        case .connectionClosed:
            return failed(.network, "Connection closed", "The remote computer closed the connection without giving a reason.")
        case .timedOut:
            return failed(.network, "Timed out", "\(host) did not respond in time.")
        case .cancelled:
            return .userDisconnected
        case .protocolViolation:
            return failed(.unsupported, "Protocol error", report.error ?? "The server sent something RDP Manager does not support.")
        case .invalidConfiguration:
            return failed(.client, "Invalid settings", report.error ?? "The connection settings cannot be sent.")
        case .clientFailure, .graphicsFrameHandler:
            return failed(.client, "Client error", report.error ?? "RDP Manager failed on this Mac.")
        case .noFramePresented:
            return failed(.network, "No desktop received", "The session started, but the server sent no picture in time.")
        @unknown default:
            return failed(.client, "Connection failed", report.error ?? "The connection failed.")
        }
    }

    private static func socketMessage(_ error: RDPSocketError) -> String {
        switch error.category {
        case .refused:
            "Nothing accepted the connection on this port. Check that Remote Desktop is enabled and the firewall allows it."
        case .hostUnreachable:
            "The host is unreachable. If it is on your local network, allow RDP Manager under System Settings › Privacy & Security › Local Network."
        case .networkUnreachable:
            "This Mac has no route to that network. Check your VPN or network connection."
        case .timedOut:
            "The host did not answer."
        default:
            "The TCP connection failed (\(error))."
        }
    }

    private static func logonMessage(_ status: RDPLogonStatus) -> String {
        if isWrongCredentials(status) { return wrongCredentialsMessage }
        return switch status {
        case .accessDenied: "The remote computer denied this account access."
        case .accountRestriction: "An account restriction, such as a blank password, prevents this sign-in."
        case .invalidLogonHours: "This account may not sign in at this time."
        case .invalidWorkstation: "This account may not sign in from this Mac."
        case .passwordExpired, .passwordMustChange: "The password has expired and must be changed."
        case .accountDisabled: "This account is disabled."
        case .logonTypeNotGranted: "This account is not allowed to sign in with Remote Desktop."
        case .accountExpired: "This account has expired."
        case .accountLockedOut: "This account is locked out."
        default: "The server refused the sign-in (\(status))."
        }
    }

    private static func terminationTitle(_ category: RDPRemoteTermination.Category) -> String {
        switch category {
        case .user: "Signed out"
        case .admin: "Ended by an administrator"
        case .timeLimit: "Session time limit reached"
        case .replaced: "Session taken over"
        case .accessDenied: "Access denied"
        case .freshCredentialsRequired: "Credentials required"
        case .licensing: "Licensing failed"
        case .serverError: "Server error"
        case .protocolError: "Protocol error"
        case .unspecified, .unknown: "Session ended"
        }
    }
}
