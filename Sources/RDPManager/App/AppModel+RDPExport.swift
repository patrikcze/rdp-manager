import AppKit
import RDPManagerCore
import UniformTypeIdentifiers

extension AppModel {
    /// Saves one connection as a Microsoft `.rdp` file with its effective settings. No
    /// password is written.
    func exportRDPFile(_ connectionID: UUID) {
        guard let connection = inventory.connection(connectionID) else { return }
        let result = RDPFileExporter.export(
            connection,
            settings: inventory.resolvedSettings(for: connection),
            profiles: inventory.credentials
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = RDPFileExporter.fileName(for: connection)
        panel.allowedContentTypes = [UTType(filenameExtension: "rdp") ?? .data]
        panel.message = "Passwords are not exported. They stay in this Mac's Keychain."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.data.write(to: url, options: .atomic)
            if result.notes.isEmpty == false {
                alert = AppAlert(title: "Exported “\(connection.name)”", message: result.notes.joined(separator: "\n"))
            }
        } catch {
            alert = AppAlert(title: "Export failed", message: error.localizedDescription)
        }
    }
}
