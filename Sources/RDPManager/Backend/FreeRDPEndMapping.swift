import FreeRDPBridge
import Foundation
import RDPManagerCore

/// Reads how a FreeRDP connection ended: its last error (by FreeRDP's stable error name) and
/// the server's Set Error Info code. Credential, certificate and network problems stay apart,
/// as in `SessionEndMapping` for RDPKit.
enum FreeRDPEndMapping {
    /// Set Error Info codes ([MS-RDPBCGR] 2.2.5.1.1) that mean the session ended on purpose.
    enum ErrorInfo {
        static let rpcInitiatedDisconnect: UInt32 = 0x01
        static let rpcInitiatedLogoff: UInt32 = 0x02
        static let idleTimeout: UInt32 = 0x03
        static let logonTimeout: UInt32 = 0x04
        static let disconnectedByOtherConnection: UInt32 = 0x05
        static let insufficientPrivileges: UInt32 = 0x09
        static let freshCredentialsRequired: UInt32 = 0x0A
        static let disconnectedByUser: UInt32 = 0x0B
        static let logoffByUser: UInt32 = 0x0C
    }

    /// The server chose a desktop or graphics surface larger than the bridge allows.
    static func desktopTooLarge(host: String) -> EngineEnd {
        .end(SessionEnd(
            kind: .failed, category: .server, title: "Desktop too large",
            message: "\(host) asked for a desktop larger than \(RDPDesktopLimits.maxSide) pixels a side or \(RDPDesktopLimits.maxPixels / 1_000_000) million pixels, so the connection was closed."
        ))
    }

    static func outcome(
        errorName: String,
        errorInfo: UInt32,
        errorInfoText: String,
        showedDesktop: Bool,
        host: String,
        security: SecurityMode = .automatic
    ) -> EngineEnd {
        func failed(_ category: FailureCategory, _ title: String, _ message: String) -> EngineEnd {
            .end(SessionEnd(kind: .failed, category: category, title: title, message: message))
        }
        func ended(_ title: String, _ message: String) -> EngineEnd {
            .end(SessionEnd(kind: .remoteEnded, category: .none, title: title, message: message))
        }

        switch errorInfo {
        case ErrorInfo.logoffByUser, ErrorInfo.rpcInitiatedLogoff:
            return ended("Signed out", "The Windows session was signed out.")
        case ErrorInfo.disconnectedByUser:
            return ended("Disconnected", "The session was disconnected from inside Windows. It keeps running on the server.")
        case ErrorInfo.rpcInitiatedDisconnect:
            return .end(SessionEnd(kind: .remoteEnded, category: .server, title: "Ended by an administrator", message: errorInfoText))
        case ErrorInfo.idleTimeout, ErrorInfo.logonTimeout:
            return .end(SessionEnd(kind: .remoteEnded, category: .server, title: "Session time limit reached", message: errorInfoText))
        case ErrorInfo.disconnectedByOtherConnection:
            return ended("Session taken over", "Another connection took over this Windows session.")
        case ErrorInfo.insufficientPrivileges:
            return failed(.authentication, "Access denied", "This account may not sign in with Remote Desktop.")
        case ErrorInfo.freshCredentialsRequired:
            return showedDesktop
                ? failed(.authentication, "Credentials required", errorInfoText)
                : .promptForCredentials(message: "The server requires you to enter your credentials.")
        default:
            break
        }

        let name = errorName.uppercased()
        func has(_ fragments: String...) -> Bool { fragments.contains { name.contains($0) } }

        if has("NONE", "SUCCESS") || name.isEmpty {
            // Nothing reported: the connection closed under the session.
            return failed(.network, "Connection closed", "The connection to \(host) closed without a reason.")
        }
        if has("CANCELLED") {
            return .end(.userDisconnected)
        }
        if has("PASSWORD_EXPIRED", "PASSWORD_MUST_CHANGE", "PASSWORD_CERT_EXPIRED") {
            return failed(.authentication, "Password expired", "The password has expired and must be changed.")
        }
        if has("ACCOUNT_LOCKED_OUT") {
            return failed(.authentication, "Account locked out", "This account is locked out.")
        }
        if has("ACCOUNT_DISABLED", "ACCOUNT_EXPIRED", "ACCOUNT_RESTRICTION", "LOGON_TYPE_NOT_GRANTED", "INVALID_LOGON_HOURS", "INVALID_WORKSTATION") {
            return failed(.authentication, "Sign-in not allowed", "The server refused this account (\(errorName)).")
        }
        if has("AUTHENTICATION_FAILED", "LOGON_FAILURE", "WRONG_PASSWORD", "NO_OR_MISSING_CREDENTIALS", "ACCESS_DENIED", "INSUFFICIENT_PRIVILEGES") {
            return showedDesktop
                ? failed(.authentication, "Sign-in refused", "The server refused the sign-in.")
                : .promptForCredentials(message: SessionEndMapping.wrongCredentialsMessage)
        }
        if has("DNS") {
            return failed(.network, "Host not found", "“\(host)” could not be resolved. Check the name and your DNS or VPN connection.")
        }
        // A server that requires TLS or NLA (Windows' default) drops a connection offering only
        // Standard RDP Security, which looks like a network failure.
        if security == .standardRDP, showedDesktop == false, has("SECURITY_NEGO", "TRANSPORT", "CONNECT_FAILED", "TLS") {
            return failed(.server, "Standard RDP Security refused",
                          "\(host) closed the connection when offered only Standard RDP Security. Windows requires TLS or NLA by default; choose Automatic under Security, or allow the RDP Security Layer on the server.")
        }
        if has("SECURITY_NEGO") {
            return failed(.server, "Security negotiation failed",
                          "The server does not accept this connection's security setting. Choose another one under Security in the connection's settings.")
        }
        if has("TLS") {
            return failed(.network, "Secure connection failed", "The TLS handshake failed.")
        }
        if has("TRANSPORT", "CONNECT_FAILED", "TIMEOUT", "TIMED_OUT") {
            return failed(.network, showedDesktop ? "Connection lost" : "Can’t reach \(host)",
                          showedDesktop ? "The network connection to \(host) was interrupted." : "\(host) did not answer on the Remote Desktop port.")
        }
        if has("KERBEROS", "KDC") {
            return failed(.authentication, "Kerberos sign-in failed", "No Kerberos ticket could be obtained (\(errorName)). Check the realm, the KDC or the KDC proxy.")
        }
        if has("LICENSE", "LICENSING") {
            return failed(.server, "Licensing failed", "Remote Desktop licensing failed (\(errorName)).")
        }
        if has("SERVER_DENIED", "SERVER_REFUSED") {
            return failed(.server, "Connection refused", "The server refused the connection.")
        }
        return failed(.client, "Connection failed", errorInfo != 0 ? errorInfoText : errorName)
    }
}

/// The bridge's limits on server-chosen desktop and surface sizes.
enum RDPDesktopLimits {
    static let maxSide = Int(RM_MAX_DESKTOP_SIDE)
    static let maxPixels = Int(RM_MAX_DESKTOP_PIXELS)
}
