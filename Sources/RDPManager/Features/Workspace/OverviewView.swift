import RDPManagerCore
import SwiftUI

/// A sortable table of the connections the sidebar selection contains.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\OverviewRow.name, comparator: .localizedStandard)]
    @State private var filter = ""

    var body: some View {
        if model.sidebarSelection == .credentials {
            CredentialsView()
        } else if model.inventory.connections.isEmpty {
            emptyLibrary
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                table
            }
        }
    }

    // MARK: - Content

    private var scope: (title: String, symbol: String, connections: [Connection]) {
        let inventory = model.inventory
        if model.searchText.isEmpty == false {
            return ("Search Results", "magnifyingglass", inventory.search(model.searchText))
        }
        switch model.sidebarSelection {
        case .favorites: return ("Favorites", "star", inventory.favorites)
        case .recent: return ("Recent", "clock", inventory.recent(limit: 50))
        case let .folder(id): return (inventory.folder(id)?.name ?? "Group", "folder", inventory.allConnections(under: id))
        case let .connection(id):
            let folderID = inventory.connection(id)?.folderID
            return (inventory.folder(folderID)?.name ?? "All Connections", "folder",
                    folderID.map { inventory.allConnections(under: $0) } ?? inventory.connections)
        default: return ("All Connections", "square.stack.3d.up", inventory.connections)
        }
    }

    private var rows: [OverviewRow] {
        let inventory = model.inventory
        let words = filter.split(whereSeparator: \.isWhitespace)
        return scope.connections.compactMap { connection in
            let row = OverviewRow(
                connection: connection,
                path: inventory.path(of: connection.folderID).map(\.name).joined(separator: " › "),
                identity: identityLabel(for: connection),
                phase: model.workspace.sessions(for: connection.id).first?.phase
            )
            let haystack = "\(row.name) \(row.address) \(row.path) \(row.os) \(connection.tags.joined(separator: " "))"
            return words.allSatisfy({ haystack.localizedCaseInsensitiveContains($0) }) ? row : nil
        }
        .sorted(using: sortOrder)
    }

    private func identityLabel(for connection: Connection) -> String {
        switch model.inventory.resolvedSettings(for: connection).credential {
        case let .shared(id): model.inventory.credential(id).map { "\($0.name) (\($0.identityLabel))" } ?? "Missing credential"
        case let .direct(username, domain): domain.isEmpty ? username : "\(domain)\\\(username)"
        case .prompt: "Ask"
        }
    }

    private var header: some View {
        let scope = scope
        let count = rows.count
        return HStack(spacing: 10) {
            Image(systemName: scope.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(scope.title)
                    .font(.headline)
                Text(selection.isEmpty ? "\(count) connection\(count == 1 ? "" : "s")" : "\(selection.count) of \(count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button {
                for id in selection { model.connect(id) }
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
            .keyboardShortcut(.defaultAction)
            .help("Connect to the selected hosts (Return)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                HStack(spacing: 8) {
                    HostIcon(color: row.connection.color)
                    Text(row.name)
                        .fontWeight(.medium)
                    if row.connection.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Status", value: \.statusSortKey) { row in
                if let phase = row.phase {
                    HStack(spacing: 5) {
                        StatusDot(phase: phase)
                        Text(phase.shortLabel)
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("Address", value: \.address) { row in
                Text(row.address)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Group", value: \.path) { row in
                Text(row.path.isEmpty ? "—" : row.path)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 220)
            TableColumn("Sign in as", value: \.identity) { row in
                Text(row.identity)
                    .foregroundStyle(row.identity == "Ask" ? .tertiary : .secondary)
            }
            .width(min: 90, ideal: 160)
            TableColumn("OS", value: \.os) { row in
                Text(row.os.isEmpty ? "—" : row.os)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 150)
            TableColumn("Last Connected", value: \.lastConnectedSortKey) { row in
                if let date = row.connection.lastConnectedAt {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never").foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.isEmpty == false {
                Button(ids.count == 1 ? "Connect" : "Connect to \(ids.count) Hosts") {
                    for id in ids { model.connect(id) }
                }
                if ids.count == 1, let id = ids.first {
                    ConnectionSessionsMenuItems(connectionID: id)
                    Divider()
                    Button("Edit…") { model.edit(id) }
                    Button("Duplicate") { model.inventory.duplicate(id) }
                    Button(model.inventory.connection(id)?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                        model.inventory.toggleFavorite(id)
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    model.delete(Set(ids.map(TreeItem.connection)))
                }
            }
        } primaryAction: { ids in
            for id in ids { model.connect(id) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(filter.isEmpty ? "No Connections Here" : "No Matches", systemImage: "desktopcomputer")
                } description: {
                    Text(filter.isEmpty ? "Add a connection to this group, or drag hosts here in the sidebar." : "No connection matches “\(filter)”.")
                } actions: {
                    if filter.isEmpty {
                        Button("New Connection…") { model.newConnection() }
                    }
                }
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Your Connection Library Is Empty", systemImage: "rectangle.connected.to.line.below")
        } description: {
            Text("Add the Windows computers you manage, organize them into groups, or connect right away with Quick Connect in the toolbar.")
        } actions: {
            HStack {
                Button("New Connection…") { model.newConnection() }
                    .buttonStyle(.borderedProminent)
                Button("Import .rdp Files…") { model.importRDPFiles() }
                Button("Add Sample Library") { model.loadSampleLibrary() }
            }
            .fixedSize()
        }
    }
}

struct OverviewRow: Identifiable {
    let connection: Connection
    let path: String
    let identity: String
    let phase: SessionPhase?

    var id: UUID { connection.id }
    var name: String { connection.name }
    var address: String { connection.addressLabel }
    var os: String { connection.operatingSystemLabel }
    var lastConnectedSortKey: Date { connection.lastConnectedAt ?? .distantPast }
    var statusSortKey: Int {
        switch phase {
        case .connected?: 0
        case let phase? where phase.isInProgress: 1
        case .some: 2
        case nil: 3
        }
    }
}
