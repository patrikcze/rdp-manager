import Foundation
import Testing
@testable import RDPManagerCore

@MainActor
@Suite("Inventory editing, inheritance and persistence")
struct InventoryStoreTests {
    private func makeStore(_ inventory: Inventory = Inventory()) -> (InventoryStore, InMemoryInventoryPersistence) {
        let persistence = InMemoryInventoryPersistence(inventory)
        return (InventoryStore(persistence: persistence, saveDelay: .zero), persistence)
    }

    @Test func nestedGroupsAndOrdering() {
        let (store, _) = makeStore()
        let emea = store.addFolder(named: "EMEA", in: nil)
        let dc = store.addFolder(named: "Datacenter", in: emea.id)
        let ws = store.addFolder(named: "Windows Server 2025", in: dc.id)
        let a = store.addConnection(Connection(name: "DC01", host: "dc01", folderID: ws.id))
        let b = store.addConnection(Connection(name: "APP01", host: "app01", folderID: ws.id))

        #expect(store.path(of: ws.id).map(\.name) == ["EMEA", "Datacenter", "Windows Server 2025"])
        #expect(store.connections(in: ws.id).map(\.id) == [a.id, b.id])
        #expect(Set(store.allConnections(under: emea.id).map(\.id)) == [a.id, b.id])

        // Reorder: APP01 before DC01.
        store.move([.connection(b.id)], to: ws.id, at: 0)
        #expect(store.connections(in: ws.id).map(\.name) == ["APP01", "DC01"])
    }

    @Test func folderNeverMovesIntoItsOwnSubtree() {
        let (store, _) = makeStore()
        let parent = store.addFolder(named: "Parent", in: nil)
        let child = store.addFolder(named: "Child", in: parent.id)
        store.move([.folder(parent.id)], to: child.id)
        #expect(store.folder(parent.id)?.parentID == nil)

        var cyclic = parent
        cyclic.parentID = child.id
        store.update(cyclic)
        #expect(store.folder(parent.id)?.parentID == nil)
    }

    @Test func deletingGroupKeepsOrDeletesContents() {
        let (store, _) = makeStore()
        let top = store.addFolder(named: "Top", in: nil)
        let doomed = store.addFolder(named: "Doomed", in: top.id)
        let sub = store.addFolder(named: "Sub", in: doomed.id)
        let host = store.addConnection(Connection(name: "h", host: "h", folderID: doomed.id))
        let deep = store.addConnection(Connection(name: "d", host: "d", folderID: sub.id))

        store.delete([.folder(doomed.id)], folderDeletion: .keepContents)
        #expect(store.folder(doomed.id) == nil)
        #expect(store.connection(host.id)?.folderID == top.id)
        #expect(store.folder(sub.id)?.parentID == top.id)

        let removed = store.delete([.folder(top.id)], folderDeletion: .deleteContents)
        #expect(Set(removed.map(\.id)) == [host.id, deep.id])
        #expect(store.connections.isEmpty)
        #expect(store.folders.isEmpty)
    }

    @Test func settingsInheritNearestFolderFirst() {
        let (store, _) = makeStore()
        let profile = store.addCredential(CredentialProfile(name: "EMEA Admin", username: "admin", domain: "EMEA"))
        var region = store.addFolder(named: "EMEA", in: nil)
        region.defaults = ConnectionSettings(credential: .shared(profile.id), clipboardEnabled: false, timeoutSeconds: 30)
        store.update(region)
        var site = store.addFolder(named: "Site", in: region.id)
        site.defaults = ConnectionSettings(clipboardEnabled: true)
        store.update(site)

        var host = store.addConnection(Connection(name: "h", host: "h", folderID: site.id))
        var resolved = store.resolvedSettings(for: host)
        #expect(resolved.credential == .shared(profile.id))
        #expect(resolved.clipboardEnabled == true) // site overrides region
        #expect(resolved.timeoutSeconds == 30)
        #expect(resolved.audioPlaybackEnabled == ResolvedSettings.builtIn.audioPlaybackEnabled)
        #expect(store.source(of: .clipboard, for: host) == .folder(site.id))
        #expect(store.source(of: .credential, for: host) == .folder(region.id))
        #expect(store.source(of: .audio, for: host) == .builtIn)

        // A host-level override wins over every folder.
        host.settings.credential = .direct(username: "local", domain: "")
        store.update(host)
        resolved = store.resolvedSettings(for: host)
        #expect(resolved.credential == .direct(username: "local", domain: ""))
        #expect(store.source(of: .credential, for: host) == .connection)
    }

    @Test func deletingCredentialClearsReferences() {
        let (store, _) = makeStore()
        let profile = store.addCredential(CredentialProfile(name: "Shared", username: "u"))
        var folder = store.addFolder(named: "F", in: nil)
        folder.defaults.credential = .shared(profile.id)
        store.update(folder)
        var host = store.addConnection(Connection(name: "h", host: "h", folderID: folder.id))
        host.settings.credential = .shared(profile.id)
        store.update(host)
        #expect(store.usages(ofCredential: profile.id).connections.count == 1)

        store.deleteCredential(profile.id)
        #expect(store.credentials.isEmpty)
        #expect(store.folder(folder.id)?.defaults.credential == nil)
        #expect(store.connection(host.id)?.settings.credential == nil)
        #expect(store.resolvedSettings(for: store.connection(host.id)!).credential == .prompt)
    }

    @Test func orphanedSecretsAreFound() {
        let (store, _) = makeStore()
        let profile = store.addCredential(CredentialProfile(name: "P", username: "u"))
        let host = store.addConnection(Connection(name: "h", host: "h"))
        let stale = UUID()
        let accounts: [SecretAccount] = [.credential(profile.id), .connection(host.id), .connection(stale), .credential(stale)]
        #expect(Set(store.orphanedSecretAccounts(in: accounts)) == [.connection(stale), .credential(stale)])
    }

    @Test func searchMatchesEveryWordAcrossFields() {
        let (store, _) = makeStore()
        let emea = store.addFolder(named: "EMEA", in: nil)
        store.addConnection(Connection(name: "SQL01", host: "sql01.example.com", folderID: emea.id, tags: ["database"]))
        store.addConnection(Connection(name: "APP01", host: "app01.example.com", folderID: emea.id))
        store.addConnection(Connection(name: "SQL02", host: "sql02.example.com", operatingSystemLabel: "Windows Server 2022"))

        #expect(store.search("emea sql").map(\.name) == ["SQL01"])
        #expect(store.search("DATABASE").map(\.name) == ["SQL01"])
        #expect(store.search("2022").map(\.name) == ["SQL02"])
        #expect(store.search("").isEmpty)
    }

    @Test func favoritesRecentAndExpansionPersist() throws {
        let (store, persistence) = makeStore()
        let folder = store.addFolder(named: "F", in: nil)
        let host = store.addConnection(Connection(name: "h", host: "h", folderID: folder.id))
        store.toggleFavorite(host.id)
        store.recordConnected(host.id, at: Date(timeIntervalSince1970: 1000))
        store.setExpanded(folder.id, false)
        store.flush()

        let reloaded = InventoryStore(persistence: persistence)
        #expect(reloaded.favorites.map(\.id) == [host.id])
        #expect(reloaded.recent().first?.lastConnectedAt == Date(timeIntervalSince1970: 1000))
        #expect(reloaded.isExpanded(folder.id) == false)
    }

    @Test func jsonFileRoundTripWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "rdpm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "inventory.json")
        let persistence = JSONFileInventoryPersistence(fileURL: url)
        let store = InventoryStore(persistence: persistence, saveDelay: .zero)
        let folder = store.addFolder(named: "Ä Unicode ✓", in: nil)
        store.addConnection(Connection(name: "h", host: "h", port: 3390, folderID: folder.id, settings: ConnectionSettings(display: .fixed(width: 1920, height: 1080))))
        store.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("password") == false)

        // Dates are stored as ISO 8601 with milliseconds; everything else exactly.
        let reloaded = InventoryStore(persistence: persistence)
        let original = try #require(store.connections.first)
        let restored = try #require(reloaded.connections.first)
        #expect(abs(restored.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
        var normalized = reloaded.inventory
        normalized.connections[0].createdAt = original.createdAt
        #expect(normalized == store.inventory)
    }

    @Test func newerSchemaIsRefusedNotOverwritten() throws {
        let json = #"{"schemaVersion": 99, "folders": [], "connections": [], "credentials": [], "expandedFolderIDs": []}"#
        #expect(throws: InventoryMigrationError.self) { try InventoryMigrator.decode(Data(json.utf8)) }
    }

    @Test func duplicateGetsFreshIdentityAndNoHistory() {
        let (store, _) = makeStore()
        let host = store.addConnection(Connection(name: "h", host: "h", lastConnectedAt: Date()))
        let copy = store.duplicate(host.id)
        #expect(copy?.id != host.id)
        #expect(copy?.name == "h Copy")
        #expect(copy?.lastConnectedAt == nil)
    }
}

@Suite("Unreadable library")
@MainActor
struct UnreadableLibraryTests {
    @Test func anUnreadableLibraryIsNeverOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rdpm-inv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "inventory.json")
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: file)

        let store = InventoryStore(persistence: JSONFileInventoryPersistence(fileURL: file), saveDelay: .zero)
        #expect(store.loadFailed)
        #expect(store.persistenceError != nil)
        #expect(store.connections.isEmpty)

        store.addConnection(Connection(name: "new", host: "new"))
        store.flush()
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test func aMissingLibraryStartsEmptyAndSaves() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rdpm-inv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "inventory.json")
        let store = InventoryStore(persistence: JSONFileInventoryPersistence(fileURL: file), saveDelay: .zero)
        #expect(store.loadFailed == false)
        store.addConnection(Connection(name: "new", host: "new"))
        store.flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
