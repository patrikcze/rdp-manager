import RDPManagerCore
import SwiftUI

/// App settings: certificate trust, Keychain housekeeping and terminal appearance. Connection
/// defaults live on groups, where they apply to the connections inside.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var trustedCount = 0
    @State private var cleanupResult: String?

    var body: some View {
        Form {
            Section("Certificates") {
                LabeledContent("Trusted server certificates", value: "\(trustedCount)")
                Button("Forget All Trusted Certificates…", role: .destructive) {
                    model.trustStore.removeAll()
                    trustedCount = model.trustStore.count
                }
                .disabled(trustedCount == 0)
                Text("Certificates you trusted are remembered per host and port. A changed certificate is always shown for review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Keychain") {
                Button("Remove Unused Passwords") {
                    let inventory = model.inventory
                    // An unreadable library looks empty: every password would seem unused.
                    guard inventory.loadFailed == false else {
                        cleanupResult = "Unavailable while the connection library can't be read."
                        return
                    }
                    // RDP and SSH references alike: passwords, SSH passwords, key passphrases.
                    let isReferenced = InventoryStore.referencedSecretAccounts(in: inventory.inventory)
                    Task {
                        do {
                            let removed = try await model.credentials.removeOrphans(keeping: isReferenced)
                            cleanupResult = removed == 0 ? "Nothing to remove." : "Removed \(removed) unused password\(removed == 1 ? "" : "s")."
                        } catch {
                            cleanupResult = error.localizedDescription
                        }
                    }
                }
                .disabled(model.inventory.loadFailed)
                if let cleanupResult {
                    Text(cleanupResult).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("SSH host keys") {
                Text("SSH host keys are kept by OpenSSH in ~/.ssh/known_hosts, apart from the RDP certificates above. A changed host key always stops the connection; remove the old key with ssh-keygen -R host after checking it with the server's administrator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("RDP Manager sends no analytics or telemetry. It connects only to the hosts you connect to (SSH through your jump hosts, if any) and, when a connection uses Kerberos, to that domain's Kerberos servers (found through DNS) or the KDC proxy you set. Terminal sessions are never recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
        .onAppear { trustedCount = model.trustStore.count }
    }
}

/// How every SSH terminal looks and behaves. Changes apply to open terminals at once.
private struct TerminalSettingsView: View {
    @Environment(AppModel.self) private var model
    private static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { $0.hasPrefix(".") == false }.sorted()
    }()

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Appearance") {
                Picker("Font", selection: $model.terminalPreferences.fontName) {
                    Text("SF Mono (system)").tag("")
                    Divider()
                    ForEach(Self.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $model.terminalPreferences.fontSize, in: TerminalPreferences.fontSizeRange, step: 1) {
                    LabeledContent("Size", value: "\(Int(model.terminalPreferences.fontSize)) pt")
                }
                Picker("Colors", selection: $model.terminalPreferences.theme) {
                    ForEach(TerminalPreferences.Theme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Cursor", selection: $model.terminalPreferences.cursorShape) {
                    ForEach(TerminalPreferences.CursorShape.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Blinking cursor", isOn: $model.terminalPreferences.cursorBlinks)
                Picker("Bell", selection: $model.terminalPreferences.bell) {
                    ForEach(TerminalPreferences.Bell.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section {
                Picker("Scrollback", selection: $model.terminalPreferences.scrollbackLines) {
                    ForEach([1000, 5000, 10_000, 50_000, 100_000], id: \.self) { Text("\($0.formatted()) lines").tag($0) }
                }
                Toggle("Use Option as Meta key", isOn: $model.terminalPreferences.optionAsMeta)
                Toggle("Confirm pasting several lines", isOn: $model.terminalPreferences.confirmMultilinePaste)
            } header: {
                Text("Behavior")
            } footer: {
                Text("With Option as Meta off, Option types your keyboard layout's characters (such as @ or { on a Czech keyboard) and dead keys work. Paste confirmation applies when the remote program hasn't turned on bracketed paste.")
            }
            Section {
                Toggle("Allow remote programs to set the clipboard", isOn: $model.terminalPreferences.allowRemoteClipboardWrite)
            } header: {
                Text("Security")
            } footer: {
                Text("Programs on a server can ask to write the Mac clipboard (OSC 52), for example tmux or vim copying over SSH. Off by default: a hostile server could replace what you copied. Reading the clipboard is never allowed. Links open only when you click them, and only web links.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}
