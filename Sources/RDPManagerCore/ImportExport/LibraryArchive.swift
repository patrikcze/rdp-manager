import Foundation

/// RDP Manager's own export format: folders, connections and credential profiles as JSON.
/// Passwords are never part of it; an imported library asks for them on first connect.
public struct LibraryArchive: Codable, Equatable, Sendable {
    public static let formatIdentifier = "com.rdpmanager.library"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var exportedAt: Date
    public var folders: [Folder]
    public var connections: [Connection]
    public var credentials: [CredentialProfile]

    public init(inventory: Inventory, exportedAt: Date = Date()) {
        format = Self.formatIdentifier
        formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        folders = inventory.folders
        // History stays on this Mac.
        connections = inventory.connections.map { connection in
            var connection = connection
            connection.lastConnectedAt = nil
            return connection
        }
        credentials = inventory.credentials
    }

    public enum ArchiveError: Error, Equatable, LocalizedError {
        case notAnArchive
        case newerVersion(Int)
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .notAnArchive: "The file is not an RDP Manager library export."
            case let .newerVersion(version): "The file was exported by a newer RDP Manager (format \(version))."
            case let .invalid(reason): "The library export is invalid: \(reason)"
            }
        }
    }

    public func encoded() throws -> Data {
        try InventoryMigrator.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LibraryArchive {
        let archive: LibraryArchive
        do {
            archive = try InventoryMigrator.decoder.decode(LibraryArchive.self, from: data)
        } catch {
            throw ArchiveError.notAnArchive
        }
        guard archive.format == formatIdentifier else {
            throw ArchiveError.notAnArchive
        }
        guard archive.formatVersion <= currentFormatVersion else {
            throw ArchiveError.newerVersion(archive.formatVersion)
        }
        try archive.validate()
        return archive
    }

    private func validate() throws {
        let folderIDs = Set(folders.map(\.id))
        guard folderIDs.count == folders.count, Set(connections.map(\.id)).count == connections.count else {
            throw ArchiveError.invalid("duplicate identifiers")
        }
        for connection in connections {
            guard HostAddress.isValidHost(connection.host), connection.port > 0 else {
                throw ArchiveError.invalid("“\(connection.name)” has an invalid host")
            }
        }
    }

    /// The archive's contents with fresh identifiers, placed under `parentID`, so importing
    /// the same file twice never collides with what is already there. References between the
    /// imported items (folder parents, shared credentials) follow the new identifiers; dangling
    /// ones are dropped.
    public func inventoryForImport(under parentID: UUID?) -> Inventory {
        var folderMap: [UUID: UUID] = [:]
        var credentialMap: [UUID: UUID] = [:]
        for folder in folders { folderMap[folder.id] = UUID() }
        for credential in credentials { credentialMap[credential.id] = UUID() }

        func remap(_ settings: ConnectionSettings) -> ConnectionSettings {
            var settings = settings
            if case let .shared(id) = settings.credential {
                settings.credential = credentialMap[id].map(CredentialAssignment.shared)
            }
            return settings
        }

        let newFolders = folders.map { folder in
            var copy = folder
            copy.id = folderMap[folder.id]!
            copy.parentID = folder.parentID.flatMap { folderMap[$0] } ?? parentID
            copy.defaults = remap(folder.defaults)
            return copy
        }
        let newConnections = connections.map { connection in
            var copy = connection
            copy.id = UUID()
            copy.folderID = connection.folderID.flatMap { folderMap[$0] } ?? parentID
            copy.settings = remap(connection.settings)
            copy.lastConnectedAt = nil
            return copy
        }
        let newCredentials = credentials.map { credential in
            var copy = credential
            copy.id = credentialMap[credential.id]!
            return copy
        }
        return Inventory(folders: newFolders, connections: newConnections, credentials: newCredentials)
    }
}
