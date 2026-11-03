import Foundation
import RDPManagerCore

/// Example groups and hosts for trying the app out. Added only when the user asks; the
/// hosts are placeholders under example.com and connect nowhere real.
enum SampleLibrary {
    static func make() -> Inventory {
        var folders: [Folder] = []
        var connections: [Connection] = []

        func folder(_ name: String, in parent: Folder? = nil, color: TagColor? = nil) -> Folder {
            let folder = Folder(name: name, parentID: parent?.id, sortIndex: folders.count(where: { $0.parentID == parent?.id }), color: color)
            folders.append(folder)
            return folder
        }

        func host(_ name: String, _ address: String, in parent: Folder, os: String, tags: [String] = [], favorite: Bool = false, color: TagColor? = nil) {
            connections.append(Connection(
                name: name, host: address, folderID: parent.id,
                sortIndex: connections.count(where: { $0.folderID == parent.id }),
                tags: tags, isFavorite: favorite, color: color, operatingSystemLabel: os
            ))
        }

        let emea = folder("EMEA", color: .blue)
        let emeaDC = folder("Datacenter", in: emea)
        let ws2025 = folder("Windows Server 2025", in: emeaDC)
        host("DC01", "dc01.emea.example.com", in: ws2025, os: "Windows Server 2025", tags: ["domain-controller"], favorite: true, color: .red)
        host("APP01", "app01.emea.example.com", in: ws2025, os: "Windows Server 2025", tags: ["app"])
        host("SQL01", "sql01.emea.example.com", in: ws2025, os: "Windows Server 2025", tags: ["sql"], color: .orange)
        let ws2022 = folder("Windows Server 2022", in: emeaDC)
        host("FS01", "fs01.emea.example.com", in: ws2022, os: "Windows Server 2022", tags: ["file"])
        let emeaAzure = folder("Azure", in: emea)
        host("AVD-JUMP", "jump-weu.example.com", in: emeaAzure, os: "Windows 11 Enterprise", tags: ["jump"])
        let sites = folder("Remote Sites", in: emea)
        host("PRG-WS01", "10.10.20.30", in: sites, os: "Windows 11 Pro")

        let nam = folder("NAM", color: .green)
        let namDC = folder("Datacenter", in: nam)
        host("NYC-APP01", "nyc-app01.example.com", in: namDC, os: "Windows Server 2022")
        let namAzure = folder("Azure", in: nam)
        host("EUS-RDS01", "rds01.eastus.example.com:3390", in: namAzure, os: "Windows Server 2025")

        let apac = folder("APAC", color: .orange)
        let sg = folder("Singapore", in: apac)
        host("SIN-DC01", "sin-dc01.example.com", in: sg, os: "Windows Server 2022")
        _ = folder("Azure", in: apac)

        // "host:port" in the sample is split here, as Quick Connect would.
        connections = connections.map { connection in
            var connection = connection
            if let address = try? HostAddress.parse(connection.host) {
                connection.host = address.host
                connection.port = address.port
            }
            return connection
        }
        return Inventory(folders: folders, connections: connections, expandedFolderIDs: [emea.id, emeaDC.id, ws2025.id])
    }
}
