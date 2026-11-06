import Foundation

/// One fact read from OpenSSH's own log (`ssh -v -E`). Only stable OpenSSH messages are
/// recognized; anything else is ignored, so a format change degrades to "Connecting…" and
/// the exit status rather than to a wrong state.
public enum SSHLogEvent: Equatable, Sendable {
    /// The TCP connection to the server (or the first jump host) is open.
    case connectionEstablished
    case remoteSoftware(String)
    case keyExchange(String)
    /// server→client cipher, as negotiated.
    case cipher(String)
    /// The key the server presented, before it is checked against `known_hosts`.
    case serverHostKey(type: String, fingerprint: String)
    /// The key matched `known_hosts` (or a CA).
    case hostKeyVerified
    /// The key differs from the one in `known_hosts`: OpenSSH stops before authenticating.
    case hostKeyChanged
    /// Where `known_hosts` holds the old key, e.g. `/Users/me/.ssh/known_hosts:12`.
    case offendingKnownHostsEntry(String)
    case hostKeyVerificationFailed
    case authenticationMethodsLeft(String)
    /// Authentication succeeded with `method` ("publickey", "password", "keyboard-interactive",
    /// "gssapi-with-mic").
    case authenticated(method: String)
    /// The shell's channel is open: the session is live.
    case interactiveSession
    /// An error-level line OpenSSH printed, kept for the end message.
    case error(String)
}

public enum SSHLogParser {
    /// Lines longer than this are cut: the log carries server-chosen strings (versions,
    /// banners in errors) and is bounded like every other input.
    public static let maximumLineLength = 1024

    public static func parse(_ rawLine: String) -> SSHLogEvent? {
        var line = String(rawLine.prefix(maximumLineLength))
        while line.hasSuffix("\r") || line.hasSuffix("\n") { line.removeLast() }
        line = sanitized(line)
        guard line.isEmpty == false else { return nil }

        if line.hasPrefix("debug") {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let message = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if message == "Connection established." { return .connectionEstablished }
            if message.hasPrefix("Remote protocol version"), let range = message.range(of: "remote software version ") {
                return .remoteSoftware(String(message[range.upperBound...]))
            }
            if message.hasPrefix("kex: algorithm: ") {
                return .keyExchange(String(message.dropFirst("kex: algorithm: ".count)))
            }
            if message.hasPrefix("kex: server->client cipher: ") {
                let rest = message.dropFirst("kex: server->client cipher: ".count)
                return .cipher(String(rest.split(separator: " ").first ?? ""))
            }
            if message.hasPrefix("Server host key: ") {
                let parts = message.dropFirst("Server host key: ".count).split(separator: " ")
                if parts.count >= 2 { return .serverHostKey(type: String(parts[0]), fingerprint: String(parts[1])) }
            }
            if message.hasPrefix("Host '"), message.contains("is known and matches") { return .hostKeyVerified }
            if message.hasPrefix("Authentications that can continue: ") {
                return .authenticationMethodsLeft(String(message.dropFirst("Authentications that can continue: ".count)))
            }
            if message == "Entering interactive session." { return .interactiveSession }
            if message.hasPrefix("Authenticated to "), let method = quotedMethod(message) {
                return .authenticated(method: method)
            }
            return nil
        }
        // Verbose and error level lines have no prefix.
        if line.hasPrefix("Authenticated to "), let method = quotedMethod(line) {
            return .authenticated(method: method)
        }
        if line.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyChanged }
        if line.hasPrefix("Offending "), let range = line.range(of: " key in ") {
            return .offendingKnownHostsEntry(String(line[range.upperBound...]))
        }
        if line.hasPrefix("Host key verification failed") { return .hostKeyVerificationFailed }
        if line.hasPrefix("@@@") || line.hasPrefix("IT IS POSSIBLE") || line.hasPrefix("Someone could be")
            || line.hasPrefix("It is also possible") || line.hasPrefix("The fingerprint for")
            || line.hasPrefix("Please contact") || line.hasPrefix("Add correct host key")
            || line.hasPrefix("Pseudo-terminal will not") || line.hasPrefix("Transferred:")
            || line.hasPrefix("Bytes per second") {
            return nil
        }
        return .error(line)
    }

    private static func quotedMethod(_ message: String) -> String? {
        guard let start = message.range(of: "using \""), let end = message[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(message[start.upperBound ..< end])
    }

    /// Printable characters only: the log may quote server-chosen text.
    public static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\t" || (CharacterSet.controlCharacters.contains(scalar) == false && scalar.properties.generalCategory != .format)
        }))
    }
}

/// How far an SSH connection got, from the log, for the end message and reconnect decision.
public struct SSHConnectionProgress: Equatable, Sendable {
    public var established = false
    public var hostKeyChanged = false
    public var hostKeyVerificationFailed = false
    public var offendingEntry: String?
    public var authenticatedMethod: String?
    public var interactive = false
    /// Error lines in order, at most `maximumErrors`.
    public var errors: [String] = []
    public static let maximumErrors = 20

    public init() {}

    public mutating func record(_ event: SSHLogEvent) {
        switch event {
        case .connectionEstablished: established = true
        case .hostKeyChanged: hostKeyChanged = true
        case .hostKeyVerificationFailed: hostKeyVerificationFailed = true
        case let .offendingKnownHostsEntry(entry): offendingEntry = offendingEntry ?? entry
        case let .authenticated(method): authenticatedMethod = method
        case .interactiveSession: interactive = true
        case let .error(line):
            if errors.count < Self.maximumErrors { errors.append(line) }
        default: break
        }
    }
}

/// Why an SSH session ended, from the exit status and what the log said. The only place SSH
/// failures are interpreted (as `SessionEndMapping` and `FreeRDPEndMapping` are for RDP).
public enum SSHEndMapping {
    /// - Parameters:
    ///   - exitStatus: `ssh`'s exit status, or nil when a signal ended it.
    ///   - stoppedByUser: the app stopped the process because the user disconnected.
    public static func end(exitStatus: Int32?, stoppedByUser: Bool, progress: SSHConnectionProgress) -> SessionEnd {
        if stoppedByUser {
            return SessionEnd(kind: .userDisconnected, category: .none, title: "Disconnected",
                              message: "You disconnected. Programs started in this shell were sent a hangup signal.")
        }
        if progress.hostKeyChanged {
            let entry = progress.offendingEntry.map { " The old key is in \($0)." } ?? ""
            return SessionEnd(
                kind: .failed, category: .certificate, title: "The Host Key Has Changed",
                message: "The server presented a different host key from the one in known_hosts, so the connection was stopped before signing in. The server may have been reinstalled — or someone may be intercepting the connection. Confirm the new fingerprint with the server's administrator, then remove the old key (ssh-keygen -R host) and connect again.\(entry)"
            )
        }
        if progress.hostKeyVerificationFailed {
            return SessionEnd(kind: .failed, category: .certificate, title: "Host Key Not Verified",
                              message: "The server's host key was not accepted, so no credentials were sent.")
        }
        // The remote shell or command ended by itself.
        if let status = exitStatus, status != 255, progress.interactive {
            return SessionEnd(kind: .remoteEnded, category: .none, title: "Session Ended",
                              message: status == 0 ? "The remote shell exited." : "The remote shell exited with status \(status).")
        }
        let errors = progress.errors
        func has(_ fragment: String) -> Bool {
            errors.contains { $0.localizedCaseInsensitiveContains(fragment) }
        }
        let detail = errors.last.map { " (\($0))" } ?? ""
        if has("Permission denied") || has("Too many authentication failures") || has("No more authentication methods") {
            return SessionEnd(kind: .failed, category: .authentication, title: "Sign-In Failed",
                              message: "The server refused the sign-in\(detail). Check the user, key or password.")
        }
        if has("Could not resolve hostname") || has("nodename nor servname") {
            return SessionEnd(kind: .failed, category: .network, title: "Host Not Found", message: "The host name could not be resolved\(detail).")
        }
        if has("Connection refused") {
            return SessionEnd(kind: .failed, category: .network, title: "Connection Refused", message: "Nothing accepted the connection on that port\(detail).")
        }
        if has("timed out") || has("Network is unreachable") || has("No route to host") || has("Host is down") {
            return SessionEnd(kind: .failed, category: .network, title: "Host Unreachable", message: "The host could not be reached\(detail).")
        }
        if has("Unable to negotiate") || has("no matching") {
            return SessionEnd(kind: .failed, category: .unsupported, title: "No Common Algorithm",
                              message: "The server and this Mac's OpenSSH share no algorithm\(detail).")
        }
        if has("Bad configuration option") || has("Bad owner or permissions") || has("Can't open user config file")
            || has("Terminating") || has("command-line") || has("Unsupported option") {
            return SessionEnd(kind: .failed, category: .client, title: "OpenSSH Configuration Error", message: "OpenSSH could not start\(detail).")
        }
        if progress.interactive || progress.authenticatedMethod != nil {
            // Dropped after the session was live: the network, a keepalive timeout or the server.
            return SessionEnd(kind: .failed, category: .network, title: "Connection Lost", message: "The connection to the server was lost\(detail).")
        }
        if has("Connection closed") || has("Connection reset") || has("kex_exchange_identification") || has("Broken pipe") {
            return SessionEnd(kind: .failed, category: progress.established ? .server : .network, title: "Connection Closed",
                              message: "The server closed the connection before the session started\(detail).")
        }
        return SessionEnd(kind: .failed, category: .client, title: "SSH Failed",
                          message: "ssh ended with status \(exitStatus.map(String.init) ?? "signal")\(detail).")
    }
}
