import Foundation

/// The protocol a saved connection speaks.
public enum ConnectionProtocol: String, Codable, CaseIterable, Sendable {
    case rdp
    case ssh

    public var defaultPort: UInt16 {
        switch self {
        case .rdp: 3389
        case .ssh: 22
        }
    }

    public var label: String {
        switch self {
        case .rdp: "RDP"
        case .ssh: "SSH"
        }
    }

    /// The port to keep when the protocol changes from `self` to `new`: a port equal to the
    /// old protocol's default becomes the new default; any other port was set on purpose and
    /// stays.
    public func port(_ port: UInt16, whenSwitchingTo new: ConnectionProtocol) -> UInt16 {
        port == defaultPort ? new.defaultPort : port
    }
}

/// How an SSH connection proves who the user is. OpenSSH does the authentication; this sets
/// the methods it may use (`PreferredAuthentications`).
public enum SSHAuthMethod: String, Codable, CaseIterable, Sendable {
    /// Whatever OpenSSH and `~/.ssh/config` decide: agent and default keys first, then
    /// keyboard-interactive and password, prompted in the app.
    case automatic
    /// Keys held by the SSH agent (`SSH_AUTH_SOCK` or the connection's IdentityAgent).
    case agent
    /// A specific private key file.
    case publicKey
    /// A password, typed or from the Keychain.
    case password
    /// Server-driven prompts (one-time codes, PAM).
    case keyboardInteractive
    /// Kerberos through GSSAPI. Needs a ticket (`kinit`) and the host's FQDN.
    case gssapi

    public var label: String {
        switch self {
        case .automatic: "Automatic (OpenSSH config)"
        case .agent: "SSH agent"
        case .publicKey: "Key file"
        case .password: "Password"
        case .keyboardInteractive: "Keyboard-interactive"
        case .gssapi: "Kerberos (GSSAPI)"
        }
    }

    /// The value of `PreferredAuthentications`, or nil to leave OpenSSH's default order.
    public var preferredAuthentications: String? {
        switch self {
        case .automatic: nil
        case .agent, .publicKey: "publickey"
        case .password: "password,keyboard-interactive"
        case .keyboardInteractive: "keyboard-interactive"
        case .gssapi: "gssapi-with-mic"
        }
    }
}

/// Where an SSH connection's saved secret comes from.
public enum SSHSecretSource: Codable, Equatable, Hashable, Sendable {
    /// Nothing saved: prompts go to the user.
    case none
    /// A shared SSH credential profile: a password or a key file with an optional passphrase.
    case profile(UUID)
    /// The connection's own password, under `SecretAccount.sshPassword(connection id)`.
    case connectionSecret
}

/// SSH settings a folder sets as defaults and a connection may override. As with
/// `ConnectionSettings`, every field is optional and nil means inherit. Kept apart from the
/// RDP settings so nothing an RDP connection or group sets, a credential above all, ever
/// becomes part of an SSH identity.
public struct SSHConnectionSettings: Codable, Equatable, Hashable, Sendable {
    /// The remote user. Empty: OpenSSH decides (`User` in `~/.ssh/config`, else the Mac user).
    public var username: String?
    public var authentication: SSHAuthMethod?
    public var secret: SSHSecretSource?
    /// A private key file (`IdentityFile`), used with `IdentitiesOnly`.
    public var identityFile: String?
    public var identitiesOnly: Bool?
    /// An OpenSSH certificate for the key (`CertificateFile`).
    public var certificateFile: String?
    /// An agent socket (`IdentityAgent`), e.g. 1Password's or Secretive's.
    public var identityAgent: String?
    /// A `Host` alias of `~/.ssh/config` to connect to instead of the address, so the user's
    /// own configuration for it applies.
    public var hostAlias: String?
    /// `ProxyJump`: comma-separated `[user@]host[:port]` jump hosts.
    public var proxyJump: String?
    public var connectTimeoutSeconds: Int?
    public var serverAliveIntervalSeconds: Int?
    public var serverAliveCountMax: Int?
    public var compression: Bool?
    /// Forwards the local SSH agent to the server. Off unless set: anyone with root on the
    /// server can use the agent's keys while the session lasts.
    public var forwardAgent: Bool?
    /// Delegates the Kerberos ticket to the server. Off unless set.
    public var gssapiDelegateCredentials: Bool?
    /// The `TERM` the remote side gets.
    public var terminalType: String?
    /// Names of local environment variables to send (`SendEnv`), if the server accepts them.
    public var sendEnvironment: [String]?
    /// A directory to change to after signing in.
    public var startupDirectory: String?
    /// A command to run instead of the login shell. Never imported.
    public var startupCommand: String?
    public var autoReconnect: Bool?

    public init(
        username: String? = nil,
        authentication: SSHAuthMethod? = nil,
        secret: SSHSecretSource? = nil,
        identityFile: String? = nil,
        identitiesOnly: Bool? = nil,
        certificateFile: String? = nil,
        identityAgent: String? = nil,
        hostAlias: String? = nil,
        proxyJump: String? = nil,
        connectTimeoutSeconds: Int? = nil,
        serverAliveIntervalSeconds: Int? = nil,
        serverAliveCountMax: Int? = nil,
        compression: Bool? = nil,
        forwardAgent: Bool? = nil,
        gssapiDelegateCredentials: Bool? = nil,
        terminalType: String? = nil,
        sendEnvironment: [String]? = nil,
        startupDirectory: String? = nil,
        startupCommand: String? = nil,
        autoReconnect: Bool? = nil
    ) {
        self.username = username
        self.authentication = authentication
        self.secret = secret
        self.identityFile = identityFile
        self.identitiesOnly = identitiesOnly
        self.certificateFile = certificateFile
        self.identityAgent = identityAgent
        self.hostAlias = hostAlias
        self.proxyJump = proxyJump
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.serverAliveIntervalSeconds = serverAliveIntervalSeconds
        self.serverAliveCountMax = serverAliveCountMax
        self.compression = compression
        self.forwardAgent = forwardAgent
        self.gssapiDelegateCredentials = gssapiDelegateCredentials
        self.terminalType = terminalType
        self.sendEnvironment = sendEnvironment
        self.startupDirectory = startupDirectory
        self.startupCommand = startupCommand
        self.autoReconnect = autoReconnect
    }

    public func overlaying(_ parent: SSHConnectionSettings) -> SSHConnectionSettings {
        SSHConnectionSettings(
            username: username ?? parent.username,
            authentication: authentication ?? parent.authentication,
            secret: secret ?? parent.secret,
            identityFile: identityFile ?? parent.identityFile,
            identitiesOnly: identitiesOnly ?? parent.identitiesOnly,
            certificateFile: certificateFile ?? parent.certificateFile,
            identityAgent: identityAgent ?? parent.identityAgent,
            hostAlias: hostAlias ?? parent.hostAlias,
            proxyJump: proxyJump ?? parent.proxyJump,
            connectTimeoutSeconds: connectTimeoutSeconds ?? parent.connectTimeoutSeconds,
            serverAliveIntervalSeconds: serverAliveIntervalSeconds ?? parent.serverAliveIntervalSeconds,
            serverAliveCountMax: serverAliveCountMax ?? parent.serverAliveCountMax,
            compression: compression ?? parent.compression,
            forwardAgent: forwardAgent ?? parent.forwardAgent,
            gssapiDelegateCredentials: gssapiDelegateCredentials ?? parent.gssapiDelegateCredentials,
            terminalType: terminalType ?? parent.terminalType,
            sendEnvironment: sendEnvironment ?? parent.sendEnvironment,
            startupDirectory: startupDirectory ?? parent.startupDirectory,
            startupCommand: startupCommand ?? parent.startupCommand,
            autoReconnect: autoReconnect ?? parent.autoReconnect
        )
    }

    public var isEmpty: Bool {
        self == SSHConnectionSettings()
    }

    public func has(_ key: SSHSettingKey) -> Bool {
        switch key {
        case .username: username != nil
        case .authentication: authentication != nil
        case .secret: secret != nil
        case .identityFile: identityFile != nil
        case .proxyJump: proxyJump != nil
        case .timeout: connectTimeoutSeconds != nil
        case .keepAlive: serverAliveIntervalSeconds != nil
        case .compression: compression != nil
        case .forwardAgent: forwardAgent != nil
        case .gssapiDelegation: gssapiDelegateCredentials != nil
        case .terminalType: terminalType != nil
        case .autoReconnect: autoReconnect != nil
        }
    }

    /// These settings without what lets someone else's file run commands, reach this Mac's
    /// agent or Kerberos ticket, or read its environment: startup command and directory,
    /// agent forwarding, credential delegation and SendEnv. Settings that are off are kept.
    public func removingRiskyImports() -> (settings: SSHConnectionSettings, removed: [String]) {
        var settings = self
        var removed: [String] = []
        if let command = settings.startupCommand, command.isEmpty == false {
            removed.append("startup command “\(command)”")
        }
        settings.startupCommand = nil
        if let directory = settings.startupDirectory, directory.isEmpty == false {
            removed.append("startup directory “\(directory)”")
        }
        settings.startupDirectory = nil
        if settings.forwardAgent == true {
            settings.forwardAgent = nil
            removed.append("agent forwarding")
        }
        if settings.gssapiDelegateCredentials == true {
            settings.gssapiDelegateCredentials = nil
            removed.append("Kerberos credential delegation")
        }
        if let names = settings.sendEnvironment, names.isEmpty == false {
            settings.sendEnvironment = nil
            removed.append("sent environment variables \(names.joined(separator: ", "))")
        }
        return (settings, removed)
    }
}

public enum SSHSettingKey: CaseIterable, Sendable {
    case username, authentication, secret, identityFile, proxyJump, timeout, keepAlive
    case compression, forwardAgent, gssapiDelegation, terminalType, autoReconnect
}

/// SSH settings with every inherited value filled in.
public struct ResolvedSSHSettings: Equatable, Sendable {
    public var username: String
    public var authentication: SSHAuthMethod
    public var secret: SSHSecretSource
    public var identityFile: String?
    public var identitiesOnly: Bool
    public var certificateFile: String?
    public var identityAgent: String?
    public var hostAlias: String?
    public var proxyJump: String?
    public var connectTimeoutSeconds: Int
    public var serverAliveIntervalSeconds: Int
    public var serverAliveCountMax: Int
    public var compression: Bool
    public var forwardAgent: Bool
    public var gssapiDelegateCredentials: Bool
    public var terminalType: String
    public var sendEnvironment: [String]
    public var startupDirectory: String?
    public var startupCommand: String?
    public var autoReconnect: Bool

    /// Keepalives every 30 s so a dead network is noticed (OpenSSH's default is never).
    /// Automatic reconnect is off: a new SSH connection is a new shell, not the old one.
    public static let builtIn = ResolvedSSHSettings(SSHConnectionSettings(), defaults: nil)

    public init(_ settings: SSHConnectionSettings, defaults: ResolvedSSHSettings? = .builtIn) {
        func text(_ value: String?, _ fallback: String?) -> String? {
            (value ?? fallback).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        }
        username = (settings.username ?? defaults?.username ?? "").trimmingCharacters(in: .whitespaces)
        authentication = settings.authentication ?? defaults?.authentication ?? .automatic
        secret = settings.secret ?? defaults?.secret ?? .none
        identityFile = text(settings.identityFile, defaults?.identityFile)
        identitiesOnly = settings.identitiesOnly ?? defaults?.identitiesOnly ?? false
        certificateFile = text(settings.certificateFile, defaults?.certificateFile)
        identityAgent = text(settings.identityAgent, defaults?.identityAgent)
        hostAlias = text(settings.hostAlias, defaults?.hostAlias)
        proxyJump = text(settings.proxyJump, defaults?.proxyJump)
        connectTimeoutSeconds = min(max(settings.connectTimeoutSeconds ?? defaults?.connectTimeoutSeconds ?? 20, 3), 300)
        serverAliveIntervalSeconds = min(max(settings.serverAliveIntervalSeconds ?? defaults?.serverAliveIntervalSeconds ?? 30, 0), 3600)
        serverAliveCountMax = min(max(settings.serverAliveCountMax ?? defaults?.serverAliveCountMax ?? 3, 1), 100)
        compression = settings.compression ?? defaults?.compression ?? false
        forwardAgent = settings.forwardAgent ?? defaults?.forwardAgent ?? false
        gssapiDelegateCredentials = settings.gssapiDelegateCredentials ?? defaults?.gssapiDelegateCredentials ?? false
        terminalType = text(settings.terminalType, defaults?.terminalType) ?? "xterm-256color"
        sendEnvironment = settings.sendEnvironment ?? defaults?.sendEnvironment ?? []
        startupDirectory = text(settings.startupDirectory, defaults?.startupDirectory)
        startupCommand = text(settings.startupCommand, defaults?.startupCommand)
        autoReconnect = settings.autoReconnect ?? defaults?.autoReconnect ?? false
    }
}
