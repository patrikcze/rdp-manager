import Foundation

/// What an SSH session connects to and with, before it becomes `ssh` arguments.
public struct SSHTarget: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    /// Empty: OpenSSH decides (`User` in `~/.ssh/config`, else the Mac user).
    public var username: String
    public var settings: ResolvedSSHSettings
    /// A key file chosen through an SSH key credential profile; wins over the settings' own.
    public var profileKeyPath: String?
    /// An OpenSSH config file to use instead of `~/.ssh/config` (`-F`), and a known_hosts
    /// file instead of `~/.ssh/known_hosts`. The app leaves both nil; tests point them at
    /// temporary files so they never read or change the user's own.
    public var configFile: String?
    public var userKnownHostsFile: String?

    public init(host: String, port: UInt16 = 22, username: String = "", settings: ResolvedSSHSettings = .builtIn, profileKeyPath: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.settings = settings
        self.profileKeyPath = profileKeyPath
    }

    /// The key file the connection uses, if one is set.
    public var identityFile: String? {
        profileKeyPath ?? settings.identityFile
    }

    /// `user@host:port` as the user would recognize it.
    public var label: String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let address = port == 22 ? shownHost : "\(shownHost):\(port)"
        return username.isEmpty ? address : "\(username)@\(address)"
    }
}

public enum SSHArgumentError: Error, Equatable, LocalizedError {
    case invalid(field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(field, value):
            "The \(field) “\(value.prefix(80))” can't be used: it contains characters OpenSSH would read as more than one value."
        }
    }
}

/// Builds the argument array for `/usr/bin/ssh`. Arguments go straight to `posix_spawn`, never
/// through a shell, and every value is validated so it stays one OpenSSH option: no value
/// may add a second option, start with `-`, or hold quotes or control characters.
public enum SSHCommandBuilder {
    /// The macOS OpenSSH client, by exact path: nothing on `PATH` can stand in for it.
    public static let sshPath = "/usr/bin/ssh"
    public static let sshKeygenPath = "/usr/bin/ssh-keygen"

    /// `logPath` receives OpenSSH's own debug log (`-v -E`), which the session reads to know
    /// truthfully where the connection is. It never contains passwords or prompts.
    public static func arguments(for target: SSHTarget, logPath: String) throws(SSHArgumentError) -> [String] {
        let settings = target.settings
        var options: [(String, String)] = [
            // Unknown keys are shown to the user (through askpass); changed keys stop the
            // connection. Never "no", never accept-new.
            ("StrictHostKeyChecking", "ask"),
            // A shared master connection would skip host-key checks and authentication, so
            // nothing the session shows could be trusted.
            ("ControlMaster", "no"),
            ("ControlPath", "none"),
            ("PermitLocalCommand", "no"),
            ("ForwardX11", "no"),
            ("ForwardX11Trusted", "no"),
            ("ForwardAgent", settings.forwardAgent ? "yes" : "no"),
            ("GSSAPIDelegateCredentials", settings.gssapiDelegateCredentials ? "yes" : "no"),
            ("ConnectTimeout", "\(settings.connectTimeoutSeconds)"),
            ("ServerAliveInterval", "\(settings.serverAliveIntervalSeconds)"),
            ("ServerAliveCountMax", "\(settings.serverAliveCountMax)"),
            ("RequestTTY", "force"),
        ]
        if settings.compression {
            options.append(("Compression", "yes"))
        }
        if let preferred = settings.authentication.preferredAuthentications {
            options.append(("PreferredAuthentications", preferred))
        }
        if settings.authentication == .gssapi {
            options.append(("GSSAPIAuthentication", "yes"))
        }
        if let identity = target.identityFile {
            options.append(("IdentityFile", try quotedPath(identity, field: "key file")))
            options.append(("IdentitiesOnly", "yes"))
        } else if settings.identitiesOnly {
            options.append(("IdentitiesOnly", "yes"))
        }
        if let certificate = settings.certificateFile {
            options.append(("CertificateFile", try quotedPath(certificate, field: "certificate file")))
        }
        if let agent = settings.identityAgent {
            options.append(("IdentityAgent", try quotedPath(agent, field: "agent socket")))
        }
        if let jump = settings.proxyJump {
            guard isValidProxyJump(jump) else { throw .invalid(field: "jump host", value: jump) }
            options.append(("ProxyJump", jump))
        }
        for name in settings.sendEnvironment {
            guard isValidEnvironmentName(name) else { throw .invalid(field: "environment variable", value: name) }
            options.append(("SendEnv", name))
        }

        if let knownHosts = target.userKnownHostsFile {
            guard knownHosts != "/dev/null" else { throw .invalid(field: "known_hosts file", value: knownHosts) }
            options.append(("UserKnownHostsFile", try quotedPath(knownHosts, field: "known_hosts file")))
        }
        var arguments = ["-v", "-E", logPath]
        if let configFile = target.configFile {
            _ = try quotedPath(configFile, field: "config file")
            arguments += ["-F", configFile]
        }
        for (key, value) in options {
            arguments += ["-o", "\(key)=\(value)"]
        }
        let destination: String
        if let alias = settings.hostAlias {
            guard isValidAlias(alias) else { throw .invalid(field: "host alias", value: alias) }
            destination = alias
            // The alias's own Port and User apply unless the connection sets others.
            if target.port != 22 { arguments += ["-p", "\(target.port)"] }
        } else {
            guard HostAddress.isValidHost(target.host), target.host.hasPrefix("-") == false else {
                throw .invalid(field: "host", value: target.host)
            }
            destination = target.host
            arguments += ["-p", "\(target.port)"]
        }
        if target.username.isEmpty == false {
            guard isValidUsername(target.username) else { throw .invalid(field: "user name", value: target.username) }
            arguments += ["-l", target.username]
        }
        arguments += ["--", destination]
        if let command = remoteCommand(directory: settings.startupDirectory, command: settings.startupCommand) {
            arguments.append(command)
        }
        return arguments
    }

    /// The remote command for a startup directory and command, or nil for the login shell.
    /// The directory is quoted for the remote POSIX shell; the command is the user's own.
    public static func remoteCommand(directory: String?, command: String?) -> String? {
        guard directory != nil || command != nil else { return nil }
        let run = command ?? "exec \"$SHELL\" -l"
        guard let directory else { return run }
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd -- \(quoted) && \(run)"
    }

    /// A path as one quoted OpenSSH value. `~` and `%` tokens are expanded by OpenSSH.
    static func quotedPath(_ path: String, field: String) throws(SSHArgumentError) -> String {
        guard path.isEmpty == false, path.count <= 1024, path.contains("\"") == false,
              path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) == false
        else { throw .invalid(field: field, value: path) }
        return "\"\(path)\""
    }

    public static func isValidUsername(_ name: String) -> Bool {
        guard name.isEmpty == false, name.count <= 256, name.hasPrefix("-") == false else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\"'`$;|&<>(){}"))
        return name.unicodeScalars.contains(where: forbidden.contains) == false
    }

    public static func isValidAlias(_ alias: String) -> Bool {
        guard alias.isEmpty == false, alias.count <= 253, alias.hasPrefix("-") == false else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return alias.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `none`, or comma-separated `[user@]host[:port]` entries (IPv6 in brackets), each
    /// optionally as `ssh://`.
    public static func isValidProxyJump(_ value: String) -> Bool {
        if value == "none" { return true }
        let hops = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard hops.isEmpty == false, hops.count <= 10 else { return false }
        return hops.allSatisfy { hop in
            var hop = hop
            if hop.lowercased().hasPrefix("ssh://") { hop.removeFirst(6) }
            if let at = hop.lastIndex(of: "@") {
                guard isValidUsername(String(hop[..<at])) else { return false }
                hop = String(hop[hop.index(after: at)...])
            }
            guard let address = try? HostAddress.parse(hop, defaultPort: 22) else { return false }
            return address.host.hasPrefix("-") == false
        }
    }

    public static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 128,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    public static func isValidTerminalType(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        return name.isEmpty == false && name.count <= 64 && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The environment `ssh` runs with: rebuilt from a short allowlist rather than inherited,
    /// so nothing of the app's own environment reaches the server by accident. Holds no secret:
    /// the askpass variables name the helper and its socket, nothing more.
    public static func environment(
        from base: [String: String],
        terminalType: String,
        sendEnvironment: [String],
        askpassHelper: String,
        askpassSocket: String
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "KRB5CCNAME", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = base[key], value.isEmpty == false { environment[key] = value }
        }
        for key in sendEnvironment where isValidEnvironmentName(key) {
            if let value = base[key] { environment[key] = value }
        }
        // Apps started from the Finder get no locale; without one the remote side falls back to
        // ASCII and mangles UTF-8.
        if environment["LANG"] == nil, environment["LC_ALL"] == nil, environment["LC_CTYPE"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = isValidTerminalType(terminalType) ? terminalType : "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["SSH_ASKPASS"] = askpassHelper
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["RDPM_ASKPASS_SOCKET"] = askpassSocket
        return environment
    }
}

/// A key's type and fingerprint, as `ssh-keygen -l -E sha256` prints them:
/// `256 SHA256:abc… comment (ED25519)`.
public struct SSHKeyDescription: Equatable, Sendable {
    public var type: String
    public var bits: Int?
    public var fingerprint: String

    public init(type: String, bits: Int?, fingerprint: String) {
        self.type = type
        self.bits = bits
        self.fingerprint = fingerprint
    }

    public static func parse(_ output: String) -> SSHKeyDescription? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[1].hasPrefix("SHA256:"),
              let last = parts.last, last.hasPrefix("("), last.hasSuffix(")")
        else { return nil }
        return SSHKeyDescription(type: String(last.dropFirst().dropLast()), bits: Int(parts[0]), fingerprint: String(parts[1]))
    }

    /// "ED25519" or "RSA 3072".
    public var label: String {
        switch (type, bits) {
        case ("ED25519", _), ("ED25519-SK", _), (_, nil): type
        case let (_, bits?): "\(type) \(bits)"
        }
    }
}
