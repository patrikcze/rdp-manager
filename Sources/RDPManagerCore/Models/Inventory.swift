import Foundation

/// Everything the connection inventory persists. Passwords are never part of it: they live in
/// the Keychain, keyed by `CredentialProfile.id` or `Connection.id` (see `SecretAccount`).
public struct Inventory: Codable, Equatable, Sendable {
    /// Bumped whenever the on-disk shape changes; `InventoryMigrator` upgrades older files.
    public static let currentSchemaVersion = 1

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
    /// Settings every connection below inherits unless it overrides them.
    public var defaults: ConnectionSettings
    public var color: TagColor?
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        sortIndex: Int = 0,
        defaults: ConnectionSettings = ConnectionSettings(),
        color: TagColor? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
        self.defaults = defaults
        self.color = color
        self.notes = notes
    }
}

/// A saved RDP host.
public struct Connection: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
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
    /// Overrides on top of the folder chain's defaults.
    public var settings: ConnectionSettings
    public var createdAt: Date
    /// Set only when a session actually showed the remote desktop.
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 3389,
        folderID: UUID? = nil,
        sortIndex: Int = 0,
        tags: [String] = [],
        isFavorite: Bool = false,
        notes: String = "",
        color: TagColor? = nil,
        operatingSystemLabel: String = "",
        settings: ConnectionSettings = ConnectionSettings(),
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.folderID = folderID
        self.sortIndex = sortIndex
        self.tags = tags
        self.isFavorite = isFavorite
        self.notes = notes
        self.color = color
        self.operatingSystemLabel = operatingSystemLabel
        self.settings = settings
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// "host" or "host:port" when the port is not the default.
    public var addressLabel: String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return port == 3389 ? shownHost : "\(shownHost):\(port)"
    }
}

/// A named identity several connections can share, such as a regional admin account.
/// Its password is stored in the Keychain under `SecretAccount.credential(id)`.
public struct CredentialProfile: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var username: String
    public var domain: String
    public var notes: String

    public init(id: UUID = UUID(), name: String, username: String, domain: String = "", notes: String = "") {
        self.id = id
        self.name = name
        self.username = username
        self.domain = domain
        self.notes = notes
    }

    /// `DOMAIN\user`, or the user name alone.
    public var identityLabel: String {
        domain.isEmpty ? username : "\(domain)\\\(username)"
    }
}

public enum TagColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
}
