import Foundation
import Testing
@testable import RDPManagerCore

@Suite(".rdp import and library export")
struct ImportExportTests {
    private func utf16LE(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        return data
    }

    @Test func importsMicrosoftRDPFile() throws {
        let file = """
        screen mode id:i:2
        use multimon:i:0
        desktopwidth:i:1920
        desktopheight:i:1080
        session bpp:i:32
        full address:s:app01.example.com:3390
        audiomode:i:2
        redirectclipboard:i:0
        username:s:CONTOSO\\admin
        dynamic resolution:i:0
        gatewayhostname:s:gw.example.com
        gatewayusagemethod:i:1
        drivestoredirect:s:*
        someunknownsetting:s:x
        """
        let result = try RDPFileImporter.parse(data: utf16LE(file), fileName: "APP01.rdp")
        let connection = result.connection
        #expect(connection.name == "APP01")
        #expect(connection.host == "app01.example.com")
        #expect(connection.port == 3390)
        #expect(connection.settings.credential == .direct(username: "admin", domain: "CONTOSO"))
        #expect(connection.settings.clipboardEnabled == false)
        #expect(connection.settings.audioPlaybackEnabled == false)
        #expect(connection.settings.display == .fixed(width: 1920, height: 1080))
        #expect(result.warnings.contains { $0.contains("RD Gateway") })
        #expect(result.warnings.contains { $0.contains("Drive redirection") })
        #expect(result.warnings.contains { $0.contains("someunknownsetting") })
    }

    @Test func importsPlainUTF8WithServerPort() throws {
        let file = "full address:s:10.0.0.5\r\nserver port:i:3391\r\nusername:s:admin@contoso.com\r\n"
        let result = try RDPFileImporter.parse(data: Data(file.utf8), fileName: "x.rdp")
        #expect(result.connection.host == "10.0.0.5")
        #expect(result.connection.port == 3391)
        #expect(result.connection.settings.credential == .direct(username: "admin@contoso.com", domain: ""))
        // Never a password, whatever the file holds.
        #expect(result.warnings.isEmpty)
    }

    @Test func rejectsFileWithoutAddress() {
        #expect(throws: RDPFileImporter.ImportError.missingAddress) {
            try RDPFileImporter.parse(data: Data("username:s:a\n".utf8), fileName: "a.rdp")
        }
    }

    @Test func libraryRoundTripsWithFreshIdentifiers() throws {
        let profile = CredentialProfile(name: "Admin", username: "admin", domain: "EMEA")
        let parent = Folder(name: "EMEA")
        let child = Folder(name: "DC", parentID: parent.id, defaults: ConnectionSettings(credential: .shared(profile.id)))
        let host = Connection(name: "DC01", host: "dc01", folderID: child.id,
                              settings: ConnectionSettings(credential: .shared(profile.id)),
                              lastConnectedAt: Date())
        let inventory = Inventory(folders: [parent, child], connections: [host], credentials: [profile])

        let data = try LibraryArchive(inventory: inventory).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.lowercased().contains("password") == false)
        #expect(text.contains("lastConnectedAt") == false)

        let imported = try LibraryArchive.decode(data).inventoryForImport(under: nil).inventory
        #expect(imported.folders.count == 2)
        let newParent = try #require(imported.folders.first { $0.name == "EMEA" })
        let newChild = try #require(imported.folders.first { $0.name == "DC" })
        let newHost = try #require(imported.connections.first)
        let newProfile = try #require(imported.credentials.first)
        #expect(newParent.id != parent.id)
        #expect(newChild.parentID == newParent.id)
        #expect(newHost.folderID == newChild.id)
        #expect(newHost.settings.credential == .shared(newProfile.id))
        #expect(newChild.defaults.credential == .shared(newProfile.id))
        #expect(newHost.lastConnectedAt == nil)
    }

    @MainActor @Test func importRemovesWeakSecurityAndLocalResourceGrants() throws {
        let risky = ConnectionSettings(
            security: .standardRDP, kerberosKDCProxyURL: "https://kdc.example.com/KdcProxy",
            printersEnabled: true, smartCardsEnabled: true, microphoneEnabled: true,
            usbDevices: ["1050:0407"], sharedFolderPath: "/"
        )
        let folder = Folder(name: "Shady", defaults: risky)
        let host = Connection(name: "DC01", host: "dc01", folderID: folder.id, settings: risky)
        let safeHost = Connection(name: "APP01", host: "app01", settings: ConnectionSettings(
            security: .nla, printersEnabled: false, sharedFolderPath: nil
        ))
        let data = try LibraryArchive(inventory: Inventory(folders: [folder], connections: [host, safeHost])).encoded()

        let result = try LibraryArchive.decode(data).inventoryForImport(under: nil)
        for settings in result.inventory.folders.map(\.defaults) + result.inventory.connections.map(\.settings) {
            #expect(settings.security != .standardRDP)
            #expect(settings.sharedFolderPath == nil)
            #expect(settings.printersEnabled != true)
            #expect(settings.smartCardsEnabled != true)
            #expect(settings.microphoneEnabled != true)
            #expect(settings.usbDevices == nil)
            #expect(settings.kerberosKDCProxyURL == nil)
        }
        // Explicitly safer choices are kept.
        let app = try #require(result.inventory.connections.first { $0.name == "APP01" })
        #expect(app.settings.security == .nla)
        #expect(app.settings.printersEnabled == false)
        // The user is told what was left out, per item.
        #expect(result.removedSettings.count == 2)
        #expect(result.removedSettings.contains { $0.hasPrefix("DC01:") && $0.contains("shared folder “/”") && $0.contains("Standard RDP Security") })
        #expect(result.removedSettings.contains { $0.hasPrefix("Shady:") })

        // Resolved through the imported group too: nothing is granted.
        let store = InventoryStore(persistence: InMemoryInventoryPersistence(result.inventory))
        let resolved = store.resolvedSettings(for: try #require(result.inventory.connections.first { $0.name == "DC01" }))
        #expect(resolved.security != .standardRDP)
        #expect(resolved.sharedFolderPath == nil)
        #expect(resolved.printersEnabled == false)
        #expect(resolved.usbDevices.isEmpty)
    }

    @Test func rejectsForeignOrInvalidArchives() {
        #expect(throws: LibraryArchive.ArchiveError.notAnArchive) {
            try LibraryArchive.decode(Data(#"{"hello": 1}"#.utf8))
        }
        var archive = LibraryArchive(inventory: Inventory(connections: [Connection(name: "bad", host: "a b")]))
        archive.formatVersion = 1
        let data = try! archive.encoded()
        #expect(throws: LibraryArchive.ArchiveError.self) { try LibraryArchive.decode(data) }
    }
}
