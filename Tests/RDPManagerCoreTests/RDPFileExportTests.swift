import Foundation
import Testing
@testable import RDPManagerCore

@Suite(".rdp export")
struct RDPFileExportTests {
    private let profile = CredentialProfile(name: "Admin", username: "admin", domain: "CONTOSO")

    @Test func exportsEffectiveSettingsWithoutAPassword() throws {
        let connection = Connection(name: "DC01", host: "dc01.contoso.com", port: 3390)
        var settings = ResolvedSettings.builtIn
        settings.credential = .shared(profile.id)
        settings.display = .fixed(width: 1920, height: 1080)
        settings.clipboardEnabled = false
        settings.printersEnabled = true
        let result = RDPFileExporter.export(connection, settings: settings, profiles: [profile])

        #expect(result.data.starts(with: [0xFF, 0xFE]))
        #expect(result.lines.contains("full address:s:dc01.contoso.com:3390"))
        #expect(result.lines.contains("username:s:CONTOSO\\admin"))
        #expect(result.lines.contains("desktopwidth:i:1920"))
        #expect(result.lines.contains("dynamic resolution:i:0"))
        #expect(result.lines.contains("redirectclipboard:i:0"))
        #expect(result.lines.contains("redirectprinters:i:1"))
        #expect(result.lines.contains("enablecredsspsupport:i:1"))
        let text = try #require(String(data: result.data, encoding: .utf16))
        #expect(text.lowercased().contains("password") == false)
    }

    @Test func roundTripsThroughTheImporter() throws {
        let connection = Connection(name: "APP01", host: "fe80::1", port: 3389)
        var settings = ResolvedSettings.builtIn
        settings.credential = .direct(username: "jane@contoso.com", domain: "")
        settings.audioPlaybackEnabled = true
        settings.autoReconnect = false
        let exported = RDPFileExporter.export(connection, settings: settings, profiles: [])
        let imported = try RDPFileImporter.parse(data: exported.data, fileName: RDPFileExporter.fileName(for: connection)).connection

        #expect(imported.name == "APP01")
        #expect(imported.host == "fe80::1")
        #expect(imported.port == 3389)
        #expect(imported.settings.credential == .direct(username: "jane@contoso.com", domain: ""))
        #expect(imported.settings.audioPlaybackEnabled == true)
        #expect(imported.settings.autoReconnect == false)
        #expect(imported.settings.clipboardEnabled == true)
    }

    @Test func promptingConnectionsHaveNoUserNameAndLocalPathsStayOut() {
        var settings = ResolvedSettings.builtIn
        settings.sharedFolderPath = "/Users/someone/Shared"
        settings.usbDevices = ["1050:0407"]
        let result = RDPFileExporter.export(Connection(name: "x", host: "x"), settings: settings, profiles: [])
        #expect(result.lines.contains { $0.hasPrefix("username:") } == false)
        #expect(result.lines.contains { $0.contains("/Users/") } == false)
        #expect(result.notes.count == 2)
    }

    @Test func valuesCannotInjectExtraSettings() {
        var settings = ResolvedSettings.builtIn
        settings.credential = .direct(username: "a\r\ndrivestoredirect:s:*", domain: "")
        let result = RDPFileExporter.export(Connection(name: "x", host: "x"), settings: settings, profiles: [])
        #expect(result.lines.contains { $0.hasPrefix("drivestoredirect") } == false)
    }

    @Test func fileNamesAreSafe() {
        #expect(RDPFileExporter.fileName(for: Connection(name: "EMEA/DC01: prod", host: "h")) == "EMEA-DC01- prod.rdp")
        #expect(RDPFileExporter.fileName(for: Connection(name: "..", host: "dc01")) == "dc01.rdp")
    }
}
