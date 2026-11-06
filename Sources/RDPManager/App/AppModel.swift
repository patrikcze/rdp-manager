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
    /// Connections waiting for the user to confirm their deletion. Deleting also removes their
    /// saved passwords and can't be undone, so the Delete key alone never does it.
    var pendingConnectionDeletion: [UUID] = []
    var alert: AppAlert?
    /// Terminal appearance and behaviour, from Settings › Terminal.
    var terminalPreferences: TerminalPreferences {
        didSet {
            terminalPreferences.save(to: .standard)
            workspace.terminalPreferences = terminalPreferences
        }
    }

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
        // Sample mode keeps certificate trust in memory too, like everything else it touches.
        trustStore = CertificateTrustStore(
            fileURL: isInMemorySampleMode ? nil : supportURL.deletingLastPathComponent().appending(path: "trusted-certificates.json")
        )
        let preferences = TerminalPreferences.load(from: .standard)
        terminalPreferences = preferences
        workspace = Workspace(inventory: inventory, credentials: credentials, trustStore: trustStore, terminalPreferences: preferences)
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

    func newConnection(in folderID: UUID? = nil, protocol connectionProtocol: ConnectionProtocol = .rdp) {
        editingConnection = ConnectionEditorRequest(
            connection: Connection(name: "", protocol: connectionProtocol, host: "", folderID: folderID ?? targetFolderID),
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

    /// Opens the editor for a Quick Connect session. Nothing typed into the session, a
    /// password above all, is saved by this; the editor asks for what to keep.
    func saveQuickConnect(_ session: WorkspaceSession) {
        let connection: Connection
        switch session {
        case let .rdp(rdp):
            connection = Connection(name: rdp.address.host, host: rdp.address.host, port: rdp.address.port, folderID: targetFolderID)
        case let .ssh(ssh):
            var saved = Connection(name: ssh.target.host, protocol: .ssh, host: ssh.target.host, port: ssh.target.port, folderID: targetFolderID)
            saved.ssh.username = ssh.target.username.isEmpty ? nil : ssh.target.username
            connection = saved
        }
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
                try? await credentials.deletePassword(for: .sshPassword(connection.id))
            }
        }
    }

    func requestDelete(_ item: TreeItem) {
        switch item {
        case let .connection(id):
            requestDeleteConnections([id])
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

    func requestDeleteConnections(_ ids: [UUID]) {
        pendingConnectionDeletion = ids.filter { inventory.connection($0) != nil }
    }

    func connect(_ connectionID: UUID) {
        workspace.open(connectionID)
    }

    /// `host` or `host:port` connects over RDP; `ssh://[user@]host[:port]`, `ssh user@host` or
    /// the SSH choice connects over SSH. Returns why the text was refused, or nil.
    func quickConnect(_ text: String, preferring connectionProtocol: ConnectionProtocol = .rdp, settings: ResolvedSettings = .builtIn) -> String? {
        do {
            switch try QuickConnectTarget.parse(text, preferring: connectionProtocol) {
            case let .rdp(address):
                workspace.quickConnect(address, settings: settings)
            case let .ssh(username, address):
                workspace.quickConnectSSH(username: username, address: address)
            }
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
            message: (notes + [Self.rdpImportScope]).joined(separator: "\n\n")
        )
    }

    /// What an .rdp import never brings along, said after every import.
    static let rdpImportScope = "Only the address, user name, display, clipboard, sound and reconnect settings are read from .rdp files. Security and device redirection settings are never imported; set them in Edit…."

    /// Adds the concrete hosts of an OpenSSH config file (normally `~/.ssh/config`) as SSH
    /// connections in the selected group. Only parsed: nothing in the file runs, and commands
    /// or security overrides in it are left out and listed.
    func importSSHConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let panel = NSOpenPanel()
        panel.directoryURL = home.appending(path: ".ssh", directoryHint: .isDirectory)
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose an OpenSSH config file, usually ~/.ssh/config. Its hosts are added to the selected group; nothing in it is run."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = SSHConfigImporter.parse(text, folderID: targetFolderID) { pattern in
                SSHConfigImporter.includedFiles(pattern, home: home.path)
            }
            for connection in result.connections {
                inventory.addConnection(connection)
            }
            var message = "\(result.connections.count) SSH host\(result.connections.count == 1 ? " was" : "s were") added. Wildcard patterns are not imported; OpenSSH still applies them when you connect."
            if result.notes.isEmpty == false {
                message += "\n\n" + result.notes.prefix(20).map { "• \($0)" }.joined(separator: "\n")
            }
            alert = AppAlert(title: "Imported from \(url.lastPathComponent)", message: message)
        } catch {
            alert = AppAlert(title: "Import failed", message: error.localizedDescription)
        }
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
            let result = archive.inventoryForImport(under: targetFolderID)
            let imported = result.inventory
            inventory.merge(imported)
            var message = "\(imported.connections.count) connections, \(imported.folders.count) groups and \(imported.credentials.count) credentials were added. Passwords are not part of exports; you'll be asked for them."
            if result.removedSettings.isEmpty == false {
                message += "\n\nFor your safety these settings were not imported. Turn them on in Edit… if you trust them:\n"
                    + result.removedSettings.map { "• \($0)" }.joined(separator: "\n")
            }
            alert = AppAlert(title: "Library imported", message: message)
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
        let hasSSH = workspace.sessions.contains { $0.connectionProtocol == .ssh && ($0.status.isActive || $0.status.isInProgress) }
        alert.informativeText = hasSSH
            ? "Windows sessions keep running on their servers. SSH sessions end: programs started in them get a hangup signal unless they run in tmux or screen."
            : "The Windows sessions keep running on their servers; you can reconnect to them later."
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
