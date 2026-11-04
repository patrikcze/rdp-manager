import AppKit
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
                if let error = model.quickConnect(arguments[index + 1], settings: Self.launchSettings(arguments)) {
                    model.alert = AppAlert(title: "Quick Connect", message: error)
                }
                #if DEBUG
                autoSignInForTesting()
                #endif
            }
            #if DEBUG
            if let index = arguments.firstIndex(of: "-Show"), index + 1 < arguments.count {
                showForScreenshot(arguments[index + 1])
            }
            #endif
        }
    }

    /// Quick Connect settings from launch arguments: `-Engine rdpKit|freeRDP|automatic`,
    /// `-Security automatic|nla|tls|standardRDP`, `-Authentication ntlm|kerberos|kerberosOnly`,
    /// `-Printers`, `-SmartCards`.
    private static func launchSettings(_ arguments: [String]) -> ResolvedSettings {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        var settings = ResolvedSettings.builtIn
        if let engine = value("-Engine").flatMap(EnginePreference.init(rawValue:)) { settings.enginePreference = engine }
        if let security = value("-Security").flatMap(SecurityMode.init(rawValue:)) { settings.security = security }
        if let auth = value("-Authentication").flatMap(AuthenticationMode.init(rawValue:)) { settings.authentication = auth }
        settings.printersEnabled = arguments.contains("-Printers")
        settings.smartCardsEnabled = arguments.contains("-SmartCards")
        return settings
    }

    #if DEBUG
    /// Debug builds only: answers the Quick Connect sign-in prompt from RDPM_LIVE_USER and
    /// RDPM_LIVE_PASSWORD, for end-to-end tests against a test host. Nothing is saved.
    private func autoSignInForTesting() {
        let environment = ProcessInfo.processInfo.environment
        guard let user = environment["RDPM_LIVE_USER"], let password = environment["RDPM_LIVE_PASSWORD"],
              let session = model.workspace.sessions.last
        else { return }
        Task { @MainActor in
            for _ in 0 ..< 50 {
                try? await Task.sleep(for: .milliseconds(100))
                if case .awaitingCredentials = session.phase {
                    session.submitCredentials(username: user, domain: "", password: password, save: false)
                    break
                }
            }
            // `-RunInSession <command>`: once the desktop shows, run it through Win+R.
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-RunInSession"), index + 1 < arguments.count else { return }
            for _ in 0 ..< 100 where session.phase.isActive == false {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(8)) // a fresh sign-in starts Explorer first
            await session.runCommand(arguments[index + 1])
            // `-SimulateKeys "h i ctrl+a ctrl+c"`: then press keys as real macOS key events
            // through the window, so the app's own input path is tested.
            if let keys = arguments.firstIndex(of: "-SimulateKeys"), keys + 1 < arguments.count {
                try? await Task.sleep(for: .seconds(3))
                await KeySimulator.press(arguments[keys + 1])
            }
        }
    }

    /// `-Show inspector|editor|group|credentials` puts the window in a state for README
    /// screenshots (with `-SampleLibraryInMemory`). Debug builds only.
    private func showForScreenshot(_ scene: String) {
        let inventory = model.inventory
        let host = inventory.connections.first { $0.name == "DC01" } ?? inventory.connections.first
        switch scene {
        case "inspector":
            if let host { model.sidebarSelection = .connection(host.id) }
            model.isInspectorPresented = true
        case "editor":
            if let host { model.edit(host.id) }
        case "group":
            model.editingFolder = inventory.subfolders(of: nil).first
        case "credentials":
            model.sidebarSelection = .credentials
        default:
            break
        }
    }
    #endif

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
            if model.isInMemorySampleMode && Self.isScreenshotMode == false {
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

    /// Debug builds launched with `-Show …` (README screenshots) leave the banner out.
    private static var isScreenshotMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-Show")
        #else
        false
        #endif
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

#if DEBUG
/// Debug builds only: posts key events to the app as the keyboard would.
@MainActor
enum KeySimulator {
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    private static let modifiers: [String: (UInt16, NSEvent.ModifierFlags, UInt)] = [
        "ctrl": (59, .control, 0x0001), "cmd": (55, .command, 0x0008),
        "shift": (56, .shift, 0x0002), "opt": (58, .option, 0x0020),
    ]

    static func press(_ spec: String) async {
        for token in spec.split(separator: " ") {
            var parts = token.lowercased().split(separator: "+").map(String.init)
            guard let key = parts.popLast()?.first, let code = keyCodes[key] else { continue }
            var flags: NSEvent.ModifierFlags = []
            var raw: UInt = 0
            for name in parts {
                guard let (modCode, flag, bit) = modifiers[name] else { continue }
                flags.insert(flag)
                raw |= bit
                post(.flagsChanged, code: modCode, flags: NSEvent.ModifierFlags(rawValue: flags.rawValue | raw))
            }
            let control = flags.contains(.control) ? String(UnicodeScalar(UInt8(key.asciiValue! - 96))) : String(key)
            post(.keyDown, code: code, flags: NSEvent.ModifierFlags(rawValue: flags.rawValue | raw), characters: control, ignoring: String(key))
            post(.keyUp, code: code, flags: NSEvent.ModifierFlags(rawValue: flags.rawValue | raw), characters: control, ignoring: String(key))
            for name in parts.reversed() {
                guard let (modCode, flag, bit) = modifiers[name] else { continue }
                flags.remove(flag)
                raw &= ~bit
                post(.flagsChanged, code: modCode, flags: NSEvent.ModifierFlags(rawValue: flags.rawValue | raw))
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func post(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags,
                             characters: String = "", ignoring: String = "") {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let event = NSEvent.keyEvent(
                  with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber, context: nil, characters: characters,
                  charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code
              )
        else { return }
        NSApp.sendEvent(event)
    }
}
#endif
