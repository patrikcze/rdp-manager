import AppKit
import RDPManagerCore
import SwiftUI

@main
struct RDPManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("RDP Manager", id: "main") {
            MainWindow()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: model) }

        // A session moved out of the main window.
        WindowGroup("Session", id: "session", for: UUID.self) { $sessionID in
            if let sessionID, let session = model.workspace.session(sessionID) {
                DetachedSessionWindow(session: session)
                    .environment(model)
            }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationDidFinishLaunching(_: Notification) {
        // Run as a regular app even when launched as a bare executable during development.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Window restoration may bring back no main window (it was closed before quitting),
        // which would leave the app running with nothing on screen.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            Self.showMainWindowIfNeeded()
        }
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        MainActor.assumeIsolated { Self.showMainWindowIfNeeded() }
        return true
    }

    /// SwiftUI lists the single main `Window` scene in the Window menu under its title;
    /// choosing that item is the supported way to open it from AppKit.
    @MainActor
    static func showMainWindowIfNeeded() {
        let hasMainWindow = NSApp.windows.contains { window in
            window.isVisible && window.identifier?.rawValue.hasPrefix("main") == true
        }
        guard hasMainWindow == false,
              let item = NSApp.windowsMenu?.items.first(where: { $0.title == "RDP Manager" }),
              let action = item.action
        else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    @MainActor
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        model?.confirmQuit() ?? .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { model.newConnection() }
                .keyboardShortcut("n")
            Button("New Group") { model.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import .rdp Files…") { model.importRDPFiles() }
            Button("Import Library…") { model.importLibrary() }
            Button("Export Library…") { model.exportLibrary() }
        }
        CommandGroup(after: .sidebar) {
            Button(model.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                model.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button(model.workspace.isFocusMode ? "Exit Focus Mode" : "Focus Mode") {
                model.workspace.isFocusMode.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Show Overview") { model.workspace.selectedTab = .overview }
                .keyboardShortcut("0")
            ForEach(1 ..< 10) { number in
                Button("Show Session \(number)") { model.workspace.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Button("Next Tab") { model.workspace.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { model.workspace.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandMenu("Session") {
            SessionMenuItems(model: model, session: model.workspace.selectedSession)
        }
        CommandGroup(replacing: .help) {
            Button("Add Sample Library") { model.loadSampleLibrary() }
        }
    }
}

/// The Session menu, shared by the menu bar and the session toolbar's menu.
struct SessionMenuItems: View {
    let model: AppModel
    let session: RemoteSession?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Reconnect") { session?.connect() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(session == nil || session?.phase.isInProgress == true)
        Button("Disconnect") { session?.disconnect() }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(session.map { $0.phase.isActive || $0.phase.isInProgress } != true)
        Button("Close Session") {
            if let session { model.workspace.close(session) }
        }
        .keyboardShortcut("w", modifiers: [.command, .option])
        .disabled(session == nil)
        Divider()
        Menu("Send Keys") {
            Button("Ctrl+Alt+Del") { session?.sendCtrlAltDelete() }
            Button("Windows") { session?.sendWindowsKey(with: nil) }
            Button("Win+R (Run)") { session?.sendWindowsKey(with: 0x13) }
            Button("Win+E (Explorer)") { session?.sendWindowsKey(with: 0x12) }
            Button("Win+L (Lock)") { session?.sendWindowsKey(with: 0x26) }
            Button("Alt+Tab") { session?.sendAltTab() }
        }
        .disabled(session?.phase.isActive != true)
        Toggle("Share Clipboard", isOn: Binding(
            get: { session?.clipboardEnabled ?? false },
            set: { session?.setClipboardEnabled($0) }
        ))
        .disabled(session == nil)
        Divider()
        Button("Move to New Window") {
            if let session {
                model.workspace.markDetached(session.id)
                openWindow(id: "session", value: session.id)
            }
        }
        .disabled(session == nil)
        Button("Enter Full Screen") {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
        if let session, session.connectionID == nil {
            Divider()
            Button("Save as Connection…") { model.saveQuickConnect(session) }
        }
    }
}
