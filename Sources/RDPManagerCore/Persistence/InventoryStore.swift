import Foundation
import Observation

/// A node of the connection tree, for selection, drag and drop and menus.
public enum TreeItem: Hashable, Codable, Sendable {
    case folder(UUID)
    case connection(UUID)
}

/// What deleting a folder does with what is inside it.
public enum FolderDeletion: Sendable {
    /// Its connections and subfolders move to the folder's parent.
    case keepContents
    /// Its connections and subfolders are deleted with it.
    case deleteContents
}

/// The connection inventory the app edits. Every change saves shortly after, coalesced.
@MainActor
@Observable
public final class InventoryStore {
    public private(set) var inventory: Inventory
    /// Why the last save or load failed, for the app to show; nil when fine.
    public private(set) var persistenceError: String?

    @ObservationIgnored private let persistence: any InventoryPersistence
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let saveDelay: Duration

    public init(persistence: any InventoryPersistence, saveDelay: Duration = .milliseconds(400)) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        do {
            inventory = try persistence.load() ?? Inventory()
        } catch {
            inventory = Inventory()
            persistenceError = "The connection library could not be read: \(error.localizedDescription)"
        }
    }

    // MARK: - Lookup

    public var folders: [Folder] { inventory.folders }
    public var connections: [Connection] { inventory.connections }
    public var credentials: [CredentialProfile] { inventory.credentials }

    public func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        return inventory.folders.first { $0.id == id }
    }

    public func connection(_ id: UUID) -> Connection? {
        inventory.connections.first { $0.id == id }
    }

    public func credential(_ id: UUID) -> CredentialProfile? {
        inventory.credentials.first { $0.id == id }
    }

    /// Subfolders of `parentID` (nil: the root), in their saved order.
    public func subfolders(of parentID: UUID?) -> [Folder] {
        inventory.folders.filter { $0.parentID == parentID }.sorted(by: Self.order)
    }

    /// Connections directly in `folderID` (nil: the root), in their saved order.
    public func connections(in folderID: UUID?) -> [Connection] {
        inventory.connections.filter { $0.folderID == folderID }.sorted(by: Self.order)
    }

    /// Every connection in `folderID` and its subfolders.
    public func allConnections(under folderID: UUID?) -> [Connection] {
        guard let folderID else {
            return inventory.connections
        }
        let ids = descendantFolderIDs(of: folderID).union([folderID])
        return inventory.connections.filter { $0.folderID.map(ids.contains) ?? false }
    }

    public var favorites: [Connection] {
        inventory.connections.filter(\.isFavorite)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Connections that showed a desktop, most recent first.
    public func recent(limit: Int = 10) -> [Connection] {
        inventory.connections.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(limit).map(\.self)
    }

    /// Folder names from the root down to `folderID`.
    public func path(of folderID: UUID?) -> [Folder] {
        var path: [Folder] = []
        var current = folder(folderID)
        var seen = Set<UUID>()
        while let node = current, seen.insert(node.id).inserted {
            path.insert(node, at: 0)
            current = folder(node.parentID)
        }
        return path
    }

    public func descendantFolderIDs(of folderID: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var queue = [folderID]
        while let next = queue.popLast() {
            for child in inventory.folders where child.parentID == next && result.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return result
    }

    // MARK: - Settings inheritance

    /// The settings `connection` connects with: its own overrides over its folders', nearest
    /// folder first, over the built-in defaults.
    public func resolvedSettings(for connection: Connection) -> ResolvedSettings {
        ResolvedSettings(effectiveSettings(for: connection))
    }

    /// The folder chain's defaults with nothing of the connection's own.
    public func inheritedSettings(forFolder folderID: UUID?) -> ConnectionSettings {
        path(of: folderID).reduce(ConnectionSettings()) { inherited, folder in
            folder.defaults.overlaying(inherited)
        }
    }

    public func effectiveSettings(for connection: Connection) -> ConnectionSettings {
        connection.settings.overlaying(inheritedSettings(forFolder: connection.folderID))
    }

    /// Where `connection`'s value for a setting comes from.
    public func source(of key: SettingKey, for connection: Connection) -> SettingSource {
        if connection.settings.has(key) {
            return .connection
        }
        return inheritedSource(of: key, forFolder: connection.folderID)
    }

    /// Where a folder's own value would come from if it set none: its ancestors or the default.
    public func inheritedSource(of key: SettingKey, forFolder folderID: UUID?) -> SettingSource {
        for folder in path(of: folderID).reversed() where folder.defaults.has(key) {
            return .folder(folder.id)
        }
        return .builtIn
    }

    // MARK: - Search

    /// Connections whose name, host, tags, notes, OS label or folder path match every word of
    /// `query`, case- and diacritic-insensitively.
    public func search(_ query: String) -> [Connection] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.isEmpty == false else {
            return []
        }
        return inventory.connections.filter { connection in
            let haystack = ([connection.name, connection.host, connection.operatingSystemLabel, connection.notes]
                + connection.tags + path(of: connection.folderID).map(\.name))
                .joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Editing

    @discardableResult
    public func addFolder(named name: String, in parentID: UUID?) -> Folder {
        let folder = Folder(name: name, parentID: parentID, sortIndex: nextFolderIndex(in: parentID))
        mutate { $0.folders.append(folder) }
        if let parentID {
            setExpanded(parentID, true)
        }
        return folder
    }

    @discardableResult
    public func addConnection(_ connection: Connection) -> Connection {
        var connection = connection
        connection.sortIndex = nextConnectionIndex(in: connection.folderID)
        let added = connection
        mutate { $0.connections.append(added) }
        if let folderID = connection.folderID {
            setExpanded(folderID, true)
        }
        return connection
    }

    public func update(_ connection: Connection) {
        mutate { inventory in
            guard let index = inventory.connections.firstIndex(where: { $0.id == connection.id }) else { return }
            inventory.connections[index] = connection
        }
    }

    public func update(_ folder: Folder) {
        mutate { inventory in
            guard let index = inventory.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            var folder = folder
            // A folder can never become its own ancestor.
            if let parent = folder.parentID,
               parent == folder.id || descendantFolderIDs(of: folder.id).contains(parent) {
                folder.parentID = inventory.folders[index].parentID
            }
            inventory.folders[index] = folder
        }
    }

    public func rename(_ item: TreeItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        mutate { inventory in
            switch item {
            case let .folder(id):
                if let index = inventory.folders.firstIndex(where: { $0.id == id }) {
                    inventory.folders[index].name = trimmed
                }
            case let .connection(id):
                if let index = inventory.connections.firstIndex(where: { $0.id == id }) {
                    inventory.connections[index].name = trimmed
                }
            }
        }
    }

    @discardableResult
    public func duplicate(_ connectionID: UUID) -> Connection? {
        guard var copy = connection(connectionID) else { return nil }
        copy.id = UUID()
        copy.name += " Copy"
        copy.createdAt = Date()
        copy.lastConnectedAt = nil
        // A direct identity's saved password belongs to the original; the copy asks.
        return addConnection(copy)
    }

    public func toggleFavorite(_ connectionID: UUID) {
        mutate { inventory in
            if let index = inventory.connections.firstIndex(where: { $0.id == connectionID }) {
                inventory.connections[index].isFavorite.toggle()
            }
        }
    }

    public func recordConnected(_ connectionID: UUID, at date: Date = Date()) {
        mutate { inventory in
            if let index = inventory.connections.firstIndex(where: { $0.id == connectionID }) {
                inventory.connections[index].lastConnectedAt = date
            }
        }
    }

    /// Deletes connections and folders. Returns the connections removed, so the caller can
    /// delete their Keychain items.
    @discardableResult
    public func delete(_ items: Set<TreeItem>, folderDeletion: FolderDeletion = .keepContents) -> [Connection] {
        var removed: [Connection] = []
        mutate { inventory in
            for item in items {
                switch item {
                case let .connection(id):
                    removed += inventory.connections.filter { $0.id == id }
                    inventory.connections.removeAll { $0.id == id }
                case let .folder(id):
                    guard let folder = inventory.folders.first(where: { $0.id == id }) else { continue }
                    switch folderDeletion {
                    case .keepContents:
                        for index in inventory.connections.indices where inventory.connections[index].folderID == id {
                            inventory.connections[index].folderID = folder.parentID
                        }
                        for index in inventory.folders.indices where inventory.folders[index].parentID == id {
                            inventory.folders[index].parentID = folder.parentID
                        }
                    case .deleteContents:
                        let doomed = descendantFolderIDs(of: id).union([id])
                        removed += inventory.connections.filter { $0.folderID.map(doomed.contains) ?? false }
                        inventory.connections.removeAll { $0.folderID.map(doomed.contains) ?? false }
                        inventory.folders.removeAll { doomed.contains($0.id) }
                        inventory.expandedFolderIDs.subtract(doomed)
                    }
                    inventory.folders.removeAll { $0.id == id }
                    inventory.expandedFolderIDs.remove(id)
                }
            }
        }
        return removed
    }

    /// Moves `items` into `folderID` (nil: the root), before the item at `index` among that
    /// folder's children of the same kind, or at the end. A folder is never moved into itself
    /// or one of its descendants.
    public func move(_ items: [TreeItem], to folderID: UUID?, at index: Int? = nil) {
        mutate { inventory in
            var movedConnections: [UUID] = []
            var movedFolders: [UUID] = []
            for item in items {
                switch item {
                case let .connection(id):
                    movedConnections.append(id)
                case let .folder(id):
                    if let folderID, folderID == id || descendantFolderIDs(of: id).contains(folderID) {
                        continue
                    }
                    movedFolders.append(id)
                }
            }

            // Connections: rebuild the target's order with the moved ones inserted.
            if movedConnections.isEmpty == false {
                var siblings = inventory.connections
                    .filter { $0.folderID == folderID && movedConnections.contains($0.id) == false }
                    .sorted(by: Self.order).map(\.id)
                let position = min(max(index ?? siblings.count, 0), siblings.count)
                siblings.insert(contentsOf: movedConnections, at: position)
                for (order, id) in siblings.enumerated() {
                    if let i = inventory.connections.firstIndex(where: { $0.id == id }) {
                        inventory.connections[i].folderID = folderID
                        inventory.connections[i].sortIndex = order
                    }
                }
            }
            if movedFolders.isEmpty == false {
                var siblings = inventory.folders
                    .filter { $0.parentID == folderID && movedFolders.contains($0.id) == false }
                    .sorted(by: Self.order).map(\.id)
                let position = min(max(index ?? siblings.count, 0), siblings.count)
                siblings.insert(contentsOf: movedFolders, at: position)
                for (order, id) in siblings.enumerated() {
                    if let i = inventory.folders.firstIndex(where: { $0.id == id }) {
                        inventory.folders[i].parentID = folderID
                        inventory.folders[i].sortIndex = order
                    }
                }
            }
            if let folderID {
                inventory.expandedFolderIDs.insert(folderID)
            }
        }
    }

    // MARK: - Expansion

    public func isExpanded(_ folderID: UUID) -> Bool {
        inventory.expandedFolderIDs.contains(folderID)
    }

    public func setExpanded(_ folderID: UUID, _ expanded: Bool) {
        guard isExpanded(folderID) != expanded else { return }
        mutate { inventory in
            if expanded {
                inventory.expandedFolderIDs.insert(folderID)
            } else {
                inventory.expandedFolderIDs.remove(folderID)
            }
        }
    }

    // MARK: - Credentials

    @discardableResult
    public func addCredential(_ profile: CredentialProfile) -> CredentialProfile {
        mutate { $0.credentials.append(profile) }
        return profile
    }

    public func update(_ profile: CredentialProfile) {
        mutate { inventory in
            if let index = inventory.credentials.firstIndex(where: { $0.id == profile.id }) {
                inventory.credentials[index] = profile
            }
        }
    }

    /// Removes the profile and every reference to it: those folders and connections fall back
    /// to what they inherit. The caller deletes the Keychain item.
    public func deleteCredential(_ id: UUID) {
        mutate { inventory in
            inventory.credentials.removeAll { $0.id == id }
            for index in inventory.connections.indices where inventory.connections[index].settings.credential == .shared(id) {
                inventory.connections[index].settings.credential = nil
            }
            for index in inventory.folders.indices where inventory.folders[index].defaults.credential == .shared(id) {
                inventory.folders[index].defaults.credential = nil
            }
        }
    }

    /// Folders and connections that name the profile directly.
    public func usages(ofCredential id: UUID) -> (folders: [Folder], connections: [Connection]) {
        (
            inventory.folders.filter { $0.defaults.credential == .shared(id) },
            inventory.connections.filter { $0.settings.credential == .shared(id) }
        )
    }

    /// Keychain accounts nothing in the inventory refers to any more.
    public func orphanedSecretAccounts(in accounts: [SecretAccount]) -> [SecretAccount] {
        let credentialIDs = Set(inventory.credentials.map(\.id))
        let connectionIDs = Set(inventory.connections.map(\.id))
        return accounts.filter { account in
            switch account {
            case let .credential(id): credentialIDs.contains(id) == false
            case let .connection(id): connectionIDs.contains(id) == false
            }
        }
    }

    // MARK: - Bulk

    /// Replaces the whole inventory, as a restore does.
    public func replaceAll(with inventory: Inventory) {
        mutate { $0 = inventory }
    }

    /// Adds imported folders, connections and credential profiles.
    public func merge(_ imported: Inventory) {
        mutate { inventory in
            inventory.folders += imported.folders
            inventory.connections += imported.connections
            inventory.credentials += imported.credentials
            inventory.expandedFolderIDs.formUnion(imported.expandedFolderIDs)
        }
    }

    // MARK: - Saving

    /// Writes pending changes now, as the app does when it quits.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    /// Edits a copy, so a change may still read the store (paths, descendants) as it was.
    private func mutate(_ change: (inout Inventory) -> Void) {
        var edited = inventory
        change(&edited)
        inventory = edited
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        do {
            try persistence.save(inventory)
            persistenceError = nil
        } catch {
            persistenceError = "Changes could not be saved: \(error.localizedDescription)"
        }
    }

    private func nextFolderIndex(in parentID: UUID?) -> Int {
        (inventory.folders.filter { $0.parentID == parentID }.map(\.sortIndex).max() ?? -1) + 1
    }

    private func nextConnectionIndex(in folderID: UUID?) -> Int {
        (inventory.connections.filter { $0.folderID == folderID }.map(\.sortIndex).max() ?? -1) + 1
    }

    private static func order(_ lhs: Folder, _ rhs: Folder) -> Bool {
        lhs.sortIndex != rhs.sortIndex
            ? lhs.sortIndex < rhs.sortIndex
            : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func order(_ lhs: Connection, _ rhs: Connection) -> Bool {
        lhs.sortIndex != rhs.sortIndex
            ? lhs.sortIndex < rhs.sortIndex
            : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
