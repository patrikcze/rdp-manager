import Foundation

/// Everything the connection inventory persists. Passwords are never part of it: they live in
/// the Keychain, keyed by `CredentialProfile.id` or `Connection.id` (see `SecretAccount`).
public struct Inventory: Codable, Equatable, Sendable {
    /// Bumped whenever the on-disk shape changes; `InventoryMigrator` upgrades older files.
    /// 1: RDP only. 2: connections have a protocol and SSH settings, folders SSH defaults,
    /// credential profiles a kind.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var folders: [Folder]
    public var connections: [Connection]
    public var credentials: [CredentialProfile]
    /// Folders the sidebar shows expanded.
    public var expandedFolderIDs: Set<UUID>

    public init(
        folders: [Folder] = [],
        connections: [Connection] = [],
        credentials: [CredentialProfile] = [],
        expandedFolderIDs: Set<UUID> = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.folders = folders
        self.connections = connections
        self.credentials = credentials
        self.expandedFolderIDs = expandedFolderIDs
    }
}

/// A group in the connection tree. Groups nest without limit through `parentID`.
public struct Folder: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// nil for a top-level folder.
    public var parentID: UUID?
    public var sortIndex: Int
    /// Settings every RDP connection below inherits unless it overrides them.
    public var defaults: ConnectionSettings
    /// Settings every SSH connection below inherits unless it overrides them.
    public var sshDefaults: SSHConnectionSettings
    public var color: TagColor?
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        sortIndex: Int = 0,
        defaults: ConnectionSettings = ConnectionSettings(),
        sshDefaults: SSHConnectionSettings = SSHConnectionSettings(),
        color: TagColor? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
        self.defaults = defaults
        self.sshDefaults = sshDefaults
        self.color = color
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentID, sortIndex, defaults, sshDefaults, color, notes
    }

    /// Schema 1 folders have no SSH defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        sortIndex = try container.decode(Int.self, forKey: .sortIndex)
        defaults = try container.decode(ConnectionSettings.self, forKey: .defaults)
        sshDefaults = try container.decodeIfPresent(SSHConnectionSettings.self, forKey: .sshDefaults) ?? SSHConnectionSettings()
        color = try container.decodeIfPresent(TagColor.self, forKey: .color)
        notes = try container.decode(String.self, forKey: .notes)
    }
}

/// A saved host: a Windows computer over RDP or any computer over SSH.
public struct Connection: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// RDP for every connection saved before SSH existed.
    public var connectionProtocol: ConnectionProtocol
    public var host: String
    public var port: UInt16
    /// nil for a connection at the root of the tree.
    public var folderID: UUID?
    public var sortIndex: Int
    public var tags: [String]
    public var isFavorite: Bool
    public var notes: String
    public var color: TagColor?
    /// A free-text label the administrator sets, such as "Windows Server 2025". Never detected.
    public var operatingSystemLabel: String
    /// RDP overrides on top of the folder chain's defaults. Ignored by SSH connections.
    public var settings: ConnectionSettings
    /// SSH overrides on top of the folder chain's SSH defaults. Ignored by RDP connections.
    public var ssh: SSHConnectionSettings
    public var createdAt: Date
    /// Set only when a session actually showed the remote desktop or terminal.
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        protocol connectionProtocol: ConnectionProtocol = .rdp,
        host: String,
        port: UInt16? = nil,
        folderID: UUID? = nil,
        sortIndex: Int = 0,
        tags: [String] = [],
        isFavorite: Bool = false,
        notes: String = "",
        color: TagColor? = nil,
        operatingSystemLabel: String = "",
        settings: ConnectionSettings = ConnectionSettings(),
        ssh: SSHConnectionSettings = SSHConnectionSettings(),
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.connectionProtocol = connectionProtocol
        self.host = host
        self.port = port ?? connectionProtocol.defaultPort
        self.folderID = folderID
        self.sortIndex = sortIndex
        self.tags = tags
        self.isFavorite = isFavorite
        self.notes = notes
        self.color = color
        self.operatingSystemLabel = operatingSystemLabel
        self.settings = settings
        self.ssh = ssh
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, connectionProtocol = "protocol", host, port, folderID, sortIndex, tags, isFavorite, notes
        case color, operatingSystemLabel, settings, ssh, createdAt, lastConnectedAt
    }

    /// Schema 1 connections have no protocol (they are RDP) and no SSH settings.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        connectionProtocol = try container.decodeIfPresent(ConnectionProtocol.self, forKey: .connectionProtocol) ?? .rdp
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        sortIndex = try container.decode(Int.self, forKey: .sortIndex)
        tags = try container.decode([String].self, forKey: .tags)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        notes = try container.decode(String.self, forKey: .notes)
        color = try container.decodeIfPresent(TagColor.self, forKey: .color)
        operatingSystemLabel = try container.decode(String.self, forKey: .operatingSystemLabel)
        settings = try container.decode(ConnectionSettings.self, forKey: .settings)
        ssh = try container.decodeIfPresent(SSHConnectionSettings.self, forKey: .ssh) ?? SSHConnectionSettings()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    public var isSSH: Bool { connectionProtocol == .ssh }

    /// "host" or "host:port" when the port is not the protocol's default.
    public var addressLabel: String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return port == connectionProtocol.defaultPort ? shownHost : "\(shownHost):\(port)"
    }
}

/// What a credential profile holds.
/// Stored as short names that never spell out "password", so a library export can still be
/// checked for that word.
public enum CredentialKind: String, Codable, CaseIterable, Sendable {
    /// A Windows sign-in for RDP: user, domain, password. Every profile saved before SSH.
    case rdpPassword = "rdp"
    /// An SSH user and password.
    case sshPassword = "ssh"
    /// An SSH user and a private key file in `~/.ssh`, with an optional passphrase.
    case sshKey

    public var label: String {
        switch self {
        case .rdpPassword: "RDP password"
        case .sshPassword: "SSH password"
        case .sshKey: "SSH key"
        }
    }

    public var isSSH: Bool { self != .rdpPassword }
}

/// A named identity several connections can share, such as a regional admin account.
/// A password is stored in the Keychain under `SecretAccount.credential(id)`; a key's
/// passphrase under `SecretAccount.sshKeyPassphrase(id)`. The key itself stays in its file.
public struct CredentialProfile: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: CredentialKind
    public var username: String
    public var domain: String
    public var notes: String
    /// For `sshKey`: the private key's path, as the user chose it (may start with `~`).
    public var keyPath: String?
    /// For `sshKey`: "ED25519", "RSA 3072"… as `ssh-keygen -l` reported when chosen.
    public var keyType: String?
    /// For `sshKey`: the SHA-256 fingerprint `ssh-keygen -l` reported when chosen.
    public var keyFingerprint: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: CredentialKind = .rdpPassword,
        username: String,
        domain: String = "",
        notes: String = "",
        keyPath: String? = nil,
        keyType: String? = nil,
        keyFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.username = username
        self.domain = domain
        self.notes = notes
        self.keyPath = keyPath
        self.keyType = keyType
        self.keyFingerprint = keyFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, username, domain, notes, keyPath, keyType, keyFingerprint
    }

    /// Schema 1 profiles are RDP passwords.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(CredentialKind.self, forKey: .kind) ?? .rdpPassword
        username = try container.decode(String.self, forKey: .username)
        domain = try container.decode(String.self, forKey: .domain)
        notes = try container.decode(String.self, forKey: .notes)
        keyPath = try container.decodeIfPresent(String.self, forKey: .keyPath)
        keyType = try container.decodeIfPresent(String.self, forKey: .keyType)
        keyFingerprint = try container.decodeIfPresent(String.self, forKey: .keyFingerprint)
    }

    /// `DOMAIN\user`, or the user name alone (always for SSH).
    public var identityLabel: String {
        domain.isEmpty || kind.isSSH ? username : "\(domain)\\\(username)"
    }
}

public enum TagColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
}
