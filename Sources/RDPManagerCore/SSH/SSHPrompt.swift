import Foundation

/// An unknown host key, as OpenSSH asks about it.
public struct SSHHostKeyPrompt: Equatable, Sendable {
    /// As OpenSSH names the host: `server` or `[server]:2222`, with the address in brackets.
    public var host: String
    public var keyType: String?
    /// `SHA256:…`
    public var fingerprint: String?
    /// The prompt text, cleaned, for anything the parser did not pick out.
    public var text: String

    public init(host: String, keyType: String?, fingerprint: String?, text: String) {
        self.host = host
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.text = text
    }
}

/// What OpenSSH asks through askpass. Only `password` and `passphrase` may ever be answered
/// from the Keychain, and only when they match the session's own target; everything else
/// goes to the user.
public enum SSHPromptKind: Equatable, Sendable {
    /// "The authenticity of host … can't be established … continue connecting?"
    case unknownHostKey(SSHHostKeyPrompt)
    /// Any other yes/no question (a host key that differs from the one for its IP address,
    /// updated host keys). Answered "no" unless the user says otherwise.
    case confirmation(String)
    /// `user@host's password:`
    case password(user: String, host: String)
    /// `Enter passphrase for key '/path':`
    case passphrase(keyPath: String)
    /// A keyboard-interactive prompt, `(user@host) Password:` or a one-time code. Password-like
    /// ones may be answered with the saved password; others always ask.
    case keyboardInteractive(user: String?, host: String?, prompt: String, isPasswordLike: Bool)
    /// A security key PIN. Never saved.
    case pin(String)
    /// Information only, such as "Confirm user presence for key…": touch the security key.
    case notice(String)
    /// Anything else: shown verbatim, answered only by the user.
    case other(String)

    /// Whether the user's answer should be hidden while typing.
    public var isSecret: Bool {
        switch self {
        // Keyboard-interactive prompts don't say whether they echo; hide them all.
        case .password, .passphrase, .pin, .keyboardInteractive: true
        default: false
        }
    }
}

public enum SSHPromptClassifier {
    /// Longest prompt accepted from the helper; anything longer is cut.
    public static let maximumPromptLength = 4096

    /// - Parameters:
    ///   - prompt: the text OpenSSH passed to askpass.
    ///   - hint: `SSH_ASKPASS_PROMPT`: "confirm", "none" or nil.
    public static func classify(_ prompt: String, hint: String?) -> SSHPromptKind {
        let text = clean(prompt)
        if hint == "none" {
            return .notice(text)
        }
        if text.contains("The authenticity of host"), text.contains("continue connecting") {
            return .unknownHostKey(hostKeyPrompt(text))
        }
        if hint == "confirm" || text.hasSuffix("(yes/no)?") || text.hasSuffix("(yes/no/[fingerprint])?")
            || text.hasSuffix("(yes/no):") || text.contains("Please type 'yes'") {
            return .confirmation(text)
        }
        let singleLine = text.trimmingCharacters(in: .whitespaces)
        if let match = singleLine.wholeMatch(of: /Enter passphrase for (?:key '(.+)'|.+ key '(.+)')(?: \(.*\))?:/) {
            return .passphrase(keyPath: String(match.1 ?? match.2 ?? ""))
        }
        if singleLine.hasPrefix("Enter PIN for") {
            return .pin(singleLine)
        }
        if let match = singleLine.wholeMatch(of: /(.+)@([^@\s]+)'s password:/) {
            return .password(user: String(match.1), host: String(match.2))
        }
        if let match = singleLine.wholeMatch(of: /\((.+)@([^@\s)]+)\) (.*)/) {
            let inner = String(match.3)
            return .keyboardInteractive(user: String(match.1), host: String(match.2), prompt: inner,
                                        isPasswordLike: isPasswordWord(inner))
        }
        if isPasswordWord(singleLine) {
            return .keyboardInteractive(user: nil, host: nil, prompt: singleLine, isPasswordLike: true)
        }
        return .other(text)
    }

    /// "Password:" alone, as PAM asks for the account password. A new, retyped or one-time
    /// password is not the saved one.
    static func isPasswordWord(_ prompt: String) -> Bool {
        let lower = prompt.trimmingCharacters(in: .whitespaces).lowercased()
        return lower == "password:"
    }

    static func hostKeyPrompt(_ text: String) -> SSHHostKeyPrompt {
        var host = ""
        if let match = text.firstMatch(of: /authenticity of host '([^']+)'/) {
            host = String(match.1)
        }
        var type: String?
        var fingerprint: String?
        if let match = text.firstMatch(of: /(\S+) key fingerprint is:? (SHA256:[A-Za-z0-9+\/=]+)/) {
            type = String(match.1)
            fingerprint = String(match.2)
        }
        return SSHHostKeyPrompt(host: host, keyType: type, fingerprint: fingerprint, text: text)
    }

    /// Printable text with line breaks kept, bounded.
    public static func clean(_ prompt: String) -> String {
        let bounded = String(prompt.prefix(maximumPromptLength))
        let scalars = bounded.unicodeScalars.filter { scalar in
            scalar == "\n" || (CharacterSet.controlCharacters.contains(scalar) == false && scalar.properties.generalCategory != .format)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decides which askpass prompts the saved secret may answer. A prompt must name the
/// session's own user and host (or key file), and the secret is offered once per attempt;
/// a second request means it was refused, and the user is asked instead.
public struct SSHSecretPolicy: Equatable, Sendable {
    public enum Secret: Equatable, Sendable {
        case password
        case passphrase
    }

    public var host: String
    /// Empty when OpenSSH chooses the user; then any user in the prompt is accepted.
    public var username: String
    /// The key file whose passphrase is saved, expanded (no `~`).
    public var keyPath: String?
    public var hasPassword: Bool
    public var hasPassphrase: Bool
    private var offered: Set<String> = []

    public init(host: String, username: String, keyPath: String?, hasPassword: Bool, hasPassphrase: Bool) {
        self.host = host
        self.username = username
        self.keyPath = keyPath
        self.hasPassword = hasPassword
        self.hasPassphrase = hasPassphrase
    }

    /// The saved secret this prompt may be answered with, or nil to ask the user. Records the
    /// offer, so the same secret is never offered twice in one attempt.
    public mutating func secret(for prompt: SSHPromptKind) -> Secret? {
        switch prompt {
        case let .password(user, promptHost):
            guard hasPassword, matches(user: user, host: promptHost) else { return nil }
            return offer(.password)
        case let .keyboardInteractive(user, promptHost, _, isPasswordLike):
            guard hasPassword, isPasswordLike, let user, let promptHost, matches(user: user, host: promptHost) else { return nil }
            return offer(.password)
        case let .passphrase(path):
            guard hasPassphrase, let keyPath, Self.samePath(path, keyPath) else { return nil }
            return offer(.passphrase)
        default:
            return nil
        }
    }

    private mutating func offer(_ secret: Secret) -> Secret? {
        let key = "\(secret)"
        guard offered.insert(key).inserted else { return nil }
        return secret
    }

    private func matches(user: String, host promptHost: String) -> Bool {
        let hostMatches = promptHost.caseInsensitiveCompare(host) == .orderedSame
            || promptHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).caseInsensitiveCompare(host) == .orderedSame
        return hostMatches && (username.isEmpty || user == username)
    }

    /// OpenSSH shows at most 100 characters of the path (`%.100s`).
    static func samePath(_ prompted: String, _ expected: String) -> Bool {
        prompted == expected || (prompted.count == 100 && expected.hasPrefix(prompted))
    }

    /// `~/x` → `/Users/me/x`.
    public static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}
