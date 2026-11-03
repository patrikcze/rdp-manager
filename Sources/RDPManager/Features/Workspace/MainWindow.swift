import RDPManagerCore
import SwiftUI

/// Sidebar, tabbed workspace (Overview plus sessions), and an optional inspector.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
        } detail: {
            WorkspaceView()
                .inspector(isPresented: $model.isInspectorPresented) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search connections")
        .toolbar { MainToolbar() }
        .onChange(of: model.sidebarSelection) { _, selection in
            showContent(for: selection)
        }
        .onChange(of: model.workspace.isFocusMode) { _, focus in
            withAnimation(.snappy) {
                columnVisibility = focus ? .detailOnly : .all
            }
            if focus { model.isInspectorPresented = false }
        }
        .sheet(item: $model.editingConnection) { request in
            ConnectionEditor(request: request)
        }
        .sheet(item: $model.editingFolder) { folder in
            FolderEditor(folder: folder)
        }
        .confirmationDialog(
            "Delete “\(model.pendingFolderDeletion?.name ?? "")”?",
            isPresented: Binding(get: { model.pendingFolderDeletion != nil }, set: { if !$0 { model.pendingFolderDeletion = nil } }),
            presenting: model.pendingFolderDeletion
        ) { folder in
            Button("Delete Group, Keep Contents") {
                model.delete([.folder(folder.id)], folderDeletion: .keepContents)
            }
            Button("Delete Group and \(model.inventory.allConnections(under: folder.id).count) Connections", role: .destructive) {
                model.delete([.folder(folder.id)], folderDeletion: .deleteContents)
            }
        } message: { _ in
            Text("Keeping contents moves its connections and subgroups up one level. Saved passwords of deleted connections are removed from the Keychain.")
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .frame(minWidth: 900, minHeight: 560)
        .task {
            // `RDPManager -QuickConnect host[:port]` opens a session at launch.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-QuickConnect"), index + 1 < arguments.count {
                if let error = model.quickConnect(arguments[index + 1]) {
                    model.alert = AppAlert(title: "Quick Connect", message: error)
                }
            }
        }
    }

    /// What the sidebar selects is shown: a host with an open session shows that session;
    /// anything else (a group, a smart list, Credentials, a host without a session) shows
    /// the Overview, even while a session tab is in front.
    private func showContent(for selection: SidebarSelection?) {
        let workspace = model.workspace
        if case let .connection(id) = selection,
           let session = workspace.sessions(for: id).first(where: { workspace.detachedSessionIDs.contains($0.id) == false }) {
            workspace.selectedTab = .session(session.id)
        } else if selection != nil {
            workspace.selectedTab = .overview
        }
    }
}

/// The window toolbar: Quick Connect, add, session actions, inspector.
struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            QuickConnectField()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("New Connection…") { model.newConnection() }
                Button("New Group") { model.newFolder() }
                Divider()
                Button("Import .rdp Files…") { model.importRDPFiles() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("New connection or group")

            if let session = model.workspace.selectedSession {
                Menu {
                    SessionMenuItems(model: model, session: session)
                } label: {
                    Label("Session", systemImage: "display")
                }
                .help("Session actions")
            }

            Button {
                model.workspace.isFocusMode.toggle()
            } label: {
                Label("Focus Mode", systemImage: model.workspace.isFocusMode
                    ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help("Hide everything but the remote desktop (⇧⌘F)")

            Button {
                model.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

/// The tab strip over the Overview and the open sessions. Session views stay alive while
/// another tab shows, so switching never reconnects or loses state.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let workspace = model.workspace
        VStack(spacing: 0) {
            if model.isInMemorySampleMode {
                SampleModeBanner()
            }
            if workspace.isFocusMode == false || workspace.selectedSession == nil {
                TabStrip()
                Divider()
            }
            ZStack {
                OverviewView()
                    .opacity(workspace.selectedTab == .overview ? 1 : 0)
                    .allowsHitTesting(workspace.selectedTab == .overview)
                ForEach(workspace.tabbedSessions) { session in
                    let isSelected = workspace.selectedTab == .session(session.id)
                    SessionView(session: session, isVisible: isSelected)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(isSelected == false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(title)
    }

    private var title: String {
        model.workspace.selectedSession?.title ?? "RDP Manager"
    }
}

/// Shown while the app runs on the in-memory sample library, so nobody mistakes it for their
/// own: nothing added here survives quitting, passwords included.
private struct SampleModeBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Sample library in memory — nothing you add or save here is kept after you quit, and passwords are not stored in the Keychain.")
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.yellow)
    }
}
