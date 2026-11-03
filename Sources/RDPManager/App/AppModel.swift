import AppKit
import Observation
import RDPManagerCore
import SwiftUI

/// The app's long-lived state: the inventory, the Keychain, certificate trust and the open
/// sessions. One instance, created by the app and passed down through the environment.
@MainActor
@Observable
final class AppModel {
    static let keychainService = "com.rdpmanager.RDPManager"

    let inventory: InventoryStore
    let workspace: Workspace
    let credentials: CredentialService
    let trustStore: CertificateTrustStore

    var sidebarSelection: SidebarSelection? = .allConnections
    var searchText = ""
    var isInspectorPresented = false
    /// Launched with `-SampleLibraryInMemory`: nothing is saved, passwords included.
    let isInMemorySampleMode = ProcessInfo.processInfo.arguments.contains("-SampleLibraryInMemory")

    /// Sheets the main window presents.
    var editingConnection: ConnectionEditorRequest?
    var editingFolder: Folder?
    var isCredentialManagerPresented = false
    var pendingFolderDeletion: Folder?
    var alert: AppAlert?

    init() {
        let supportURL = (try? JSONFileInventoryPersistence.defaultFileURL())
            ?? FileManager.default.temporaryDirectory.appending(path: "inventory.json")
        if ProcessInfo.processInfo.arguments.contains("-SampleLibraryInMemory") {
            // For UI checks and screenshots: the sample library, nothing read from or written
            // to the user's library or Keychain.
            inventory = InventoryStore(persistence: InMemoryInventoryPersistence(SampleLibrary.make()))
            credentials = CredentialService(store: InMemorySecretStore())
        } else {
            inventory = InventoryStore(persistence: JSONFileInventoryPersistence(fileURL: supportURL))
            credentials = CredentialService(store: KeychainSecretStore(service: Self.keychainService))
        }
        trustStore = CertificateTrustStore(
            fileURL: supportURL.deletingLastPathComponent().appending(path: "trusted-certificates.json")
        )
        workspace = Workspace(inventory: inventory, credentials: credentials, trustStore: trustStore)
    }

    /// The folder new items go into, from the sidebar selection.
    var targetFolderID: UUID? {
        switch sidebarSelection {
        case let .folder(id): id
        case let .connection(id): inventory.connection(id)?.folderID
        default: nil
        }
    }

    // MARK: - Actions

    func newConnection(in folderID: UUID? = nil) {
        editingConnection = ConnectionEditorRequest(
            connection: Connection(name: "", host: "", folderID: folderID ?? targetFolderID),
            isNew: true
        )
    }

    func edit(_ connectionID: UUID) {
        guard let connection = inventory.connection(connectionID) else { return }
        editingConnection = ConnectionEditorRequest(connection: connection, isNew: false)
    }

    func newFolder(in parentID: UUID? = nil) {
        let folder = inventory.addFolder(named: "New Group", in: parentID ?? targetFolderID)
        sidebarSelection = .folder(folder.id)
        editingFolder = folder
    }

    func saveQuickConnect(_ session: RemoteSession) {
        let connection = Connection(
            name: session.address.host,
            host: session.address.host,
            port: session.address.port,
            folderID: targetFolderID
        )
        editingConnection = ConnectionEditorRequest(connection: connection, isNew: true)
    }

    func delete(_ items: Set<TreeItem>, folderDeletion: FolderDeletion = .keepContents) {
        let removed = inventory.delete(items, folderDeletion: folderDeletion)
        if let selection = sidebarSelection, case let .connection(id) = selection, removed.contains(where: { $0.id == id }) {
            sidebarSelection = .allConnections
        }
        if let selection = sidebarSelection, case let .folder(id) = selection, inventory.folder(id) == nil {
            sidebarSelection = .allConnections
        }
        let credentials = credentials
        Task {
            for connection in removed {
                try? await credentials.deletePassword(for: .connection(connection.id))
            }
        }
    }

    func requestDelete(_ item: TreeItem) {
        switch item {
        case let .connection(id):
            delete([.connection(id)])
        case let .folder(id):
            guard let folder = inventory.folder(id) else { return }
            let isEmpty = inventory.allConnections(under: id).isEmpty && inventory.subfolders(of: id).isEmpty
            if isEmpty {
                delete([.folder(id)])
            } else {
                pendingFolderDeletion = folder
            }
        }
    }

    func connect(_ connectionID: UUID) {
        workspace.open(connectionID)
    }

    func quickConnect(_ text: String) -> String? {
        do {
            let address = try HostAddress.parse(text)
            workspace.quickConnect(address)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Import / export

    func importRDPFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "rdp") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose .rdp files to add to the selected group."
        guard panel.runModal() == .OK else { return }
        var imported = 0
        var notes: [String] = []
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                var result = try RDPFileImporter.parse(data: data, fileName: url.lastPathComponent)
                result.connection.folderID = targetFolderID
                inventory.addConnection(result.connection)
                imported += 1
                notes += result.warnings.map { "\(result.connection.name): \($0)" }
            } catch {
                notes.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        alert = AppAlert(
            title: "Imported \(imported) of \(panel.urls.count) connection\(panel.urls.count == 1 ? "" : "s")",
            message: notes.isEmpty ? "Every setting was imported." : notes.joined(separator: "\n")
        )
    }

    func exportLibrary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RDP Manager Library.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Passwords are not exported. They stay in this Mac's Keychain."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryArchive(inventory: inventory.inventory).encoded().write(to: url, options: .atomic)
        } catch {
            alert = AppAlert(title: "Export failed", message: error.localizedDescription)
        }
    }

    func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose an RDP Manager library export. Its groups are added to the selected group."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try LibraryArchive.decode(Data(contentsOf: url))
            let imported = archive.inventoryForImport(under: targetFolderID)
            inventory.merge(imported)
            alert = AppAlert(
                title: "Library imported",
                message: "\(imported.connections.count) connections, \(imported.folders.count) groups and \(imported.credentials.count) credentials were added. Passwords are not part of exports; you'll be asked for them."
            )
        } catch {
            alert = AppAlert(title: "Import failed", message: error.localizedDescription)
        }
    }

    func loadSampleLibrary() {
        inventory.merge(SampleLibrary.make())
    }

    // MARK: - Quit

    func confirmQuit() -> NSApplication.TerminateReply {
        let active = workspace.activeSessionCount
        inventory.flush()
        guard active > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Disconnect \(active) remote session\(active == 1 ? "" : "s")?"
        alert.informativeText = "The Windows sessions keep running on their servers; you can reconnect to them later."
        alert.addButton(withTitle: "Disconnect and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await workspace.closeAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ConnectionEditorRequest: Identifiable {
    var id: UUID { connection.id }
    var connection: Connection
    var isNew: Bool
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
