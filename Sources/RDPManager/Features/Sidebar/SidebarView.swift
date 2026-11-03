import RDPManagerCore
import SwiftUI
import UniformTypeIdentifiers

/// The connection library: smart lists, the nested group tree, and credentials.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: TreeItem?
    @State private var renameText = ""

    private var inventory: InventoryStore { model.inventory }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            if model.searchText.isEmpty == false {
                searchResults
            } else {
                Section("Library") {
                    smartRow(.allConnections, "All Connections", "square.stack.3d.up", count: inventory.connections.count)
                    smartRow(.favorites, "Favorites", "star", count: inventory.favorites.count)
                    smartRow(.recent, "Recent", "clock", count: inventory.recent().count)
                }
                Section {
                    tree(parentID: nil)
                } header: {
                    Text("Connections")
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, into: nil, at: nil)
                        }
                }
                Section("Security") {
                    Label("Credentials", systemImage: "key")
                        .badge(inventory.credentials.count)
                        .tag(SidebarSelection.credentials)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarSelection.self) { selection in
            if let item = selection.first {
                menu(for: item)
            } else {
                Button("New Connection…") { model.newConnection(in: nil) }
                Button("New Group") { model.newFolder(in: nil) }
            }
        } primaryAction: { selection in
            if case let .connection(id) = selection.first {
                model.connect(id)
            }
        }
        .onKeyPress(.return) {
            if case let .connection(id) = model.sidebarSelection, renaming == nil {
                model.connect(id)
                return .handled
            }
            return .ignored
        }
        .onDeleteCommand {
            switch model.sidebarSelection {
            case let .connection(id): model.requestDelete(.connection(id))
            case let .folder(id): model.requestDelete(.folder(id))
            default: break
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .frame(minWidth: 220)
    }

    // MARK: - Rows

    private func smartRow(_ selection: SidebarSelection, _ title: String, _ symbol: String, count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(selection)
    }

    private func tree(parentID: UUID?) -> AnyView {
        // Recursive, so type-erased. Reordering goes through the rows' drop destinations.
        AnyView(Group {
            ForEach(inventory.subfolders(of: parentID)) { folder in
                DisclosureGroup(isExpanded: Binding(
                    get: { inventory.isExpanded(folder.id) },
                    set: { inventory.setExpanded(folder.id, $0) }
                )) {
                    tree(parentID: folder.id)
                } label: {
                    folderRow(folder)
                }
            }
            ForEach(inventory.connections(in: parentID)) { connection in
                connectionRow(connection)
            }
        })
    }

    private func folderRow(_ folder: Folder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(folder.color?.color ?? .secondary)
                .symbolRenderingMode(.hierarchical)
            if renaming == .folder(folder.id) {
                renameField(for: .folder(folder.id))
            } else {
                Text(folder.name)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            let active = inventory.allConnections(under: folder.id).reduce(0) { $0 + model.workspace.sessions(for: $1.id).count { $0.phase.isActive } }
            if active > 0 {
                Text("\(active)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.green)
                    .help("\(active) connected session\(active == 1 ? "" : "s")")
            }
        }
        .tag(SidebarSelection.folder(folder.id))
        .draggable("folder:\(folder.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: folder.id, at: nil)
        }
    }

    private func connectionRow(_ connection: Connection) -> some View {
        let sessions = model.workspace.sessions(for: connection.id)
        return HStack(spacing: 7) {
            HostIcon(color: connection.color, size: 13)
            if renaming == .connection(connection.id) {
                renameField(for: .connection(connection.id))
            } else {
                Text(connection.name)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if connection.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
            if let session = sessions.first {
                StatusDot(phase: session.phase)
            }
        }
        .tag(SidebarSelection.connection(connection.id))
        .help(connection.addressLabel)
        .draggable("connection:\(connection.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
            // Dropping on a host places the items before it in its group.
            let siblings = inventory.connections(in: connection.folderID)
            let index = siblings.firstIndex { $0.id == connection.id }
            return drop(items, into: connection.folderID, at: index)
        }
    }

    private func renameField(for item: TreeItem) -> some View {
        TextField("Name", text: $renameText)
            .textFieldStyle(.plain)
            .onSubmit {
                inventory.rename(item, to: renameText)
                renaming = nil
            }
            .onExitCommand { renaming = nil }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = inventory.search(model.searchText)
        Section("\(results.count) Result\(results.count == 1 ? "" : "s")") {
            ForEach(results) { connection in
                VStack(alignment: .leading, spacing: 1) {
                    connectionRow(connection)
                    Text(([connection.addressLabel] + inventory.path(of: connection.folderID).map(\.name)).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 20)
                }
                .tag(SidebarSelection.connection(connection.id))
            }
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func menu(for item: SidebarSelection) -> some View {
        switch item {
        case let .connection(id):
            if let connection = inventory.connection(id) {
                Button("Connect") { model.connect(id) }
                Button("Connect in New Session") { model.workspace.open(id, newSession: true) }
                Divider()
                Button("Edit…") { model.edit(id) }
                Button("Rename") { startRename(.connection(id), connection.name) }
                Button("Duplicate") { inventory.duplicate(id) }
                Button(connection.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    inventory.toggleFavorite(id)
                }
                Menu("Color") { colorMenu(current: connection.color) { color in
                    var updated = connection
                    updated.color = color
                    inventory.update(updated)
                } }
                Divider()
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connection.addressLabel, forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) { model.requestDelete(.connection(id)) }
            }
        case let .folder(id):
            if let folder = inventory.folder(id) {
                Button("Connect to All (\(inventory.connections(in: id).count))") {
                    for connection in inventory.connections(in: id) { model.connect(connection.id) }
                }
                .disabled(inventory.connections(in: id).isEmpty)
                Divider()
                Button("New Connection…") { model.newConnection(in: id) }
                Button("New Subgroup") { model.newFolder(in: id) }
                Divider()
                Button("Group Settings…") { model.editingFolder = folder }
                Button("Rename") { startRename(.folder(id), folder.name) }
                Menu("Color") { colorMenu(current: folder.color) { color in
                    var updated = folder
                    updated.color = color
                    inventory.update(updated)
                } }
                Divider()
                Button("Delete Group…", role: .destructive) { model.requestDelete(.folder(id)) }
            }
        case .credentials:
            Button("Manage Credentials…") { model.sidebarSelection = .credentials }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func colorMenu(current: TagColor?, apply: @escaping (TagColor?) -> Void) -> some View {
        Button("None") { apply(nil) }
        Divider()
        ForEach(TagColor.allCases, id: \.self) { color in
            Button {
                apply(color)
            } label: {
                Label(color.name, systemImage: current == color ? "checkmark.circle.fill" : "circle.fill")
            }
            .tint(color.color)
        }
    }

    private func startRename(_ item: TreeItem, _ current: String) {
        renameText = current
        renaming = item
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 2) {
            Menu {
                Button("New Connection…") { model.newConnection() }
                Button("New Group") { model.newFolder() }
                Divider()
                Button("Import .rdp Files…") { model.importRDPFiles() }
                Button("Import Library…") { model.importLibrary() }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a connection or group")
            Spacer()
            if let error = inventory.persistenceError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Drag and drop

    private func drop(_ payloads: [String], into folderID: UUID?, at index: Int?) -> Bool {
        let items: [TreeItem] = payloads.compactMap { payload in
            let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            return parts[0] == "folder" ? .folder(id) : parts[0] == "connection" ? .connection(id) : nil
        }
        guard items.isEmpty == false else { return false }
        withAnimation(.snappy) {
            inventory.move(items, to: folderID, at: index)
        }
        return true
    }
}
