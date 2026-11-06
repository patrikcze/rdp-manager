import RDPManagerCore
import SwiftUI

/// Details of the selected session, or of the connection selected in the sidebar. Every
/// number shown here is measured by the engine; anything not measured says so.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.workspace.selectedSession {
        case let .rdp(session)?:
            SessionInspector(session: session)
        case let .ssh(session)?:
            SSHSessionInspector(session: session)
        case nil:
            if case let .connection(id) = model.sidebarSelection, let connection = model.inventory.connection(id) {
                if connection.isSSH {
                    SSHConnectionInspector(connection: connection)
                } else {
                    ConnectionInspector(connection: connection)
                }
            } else {
                noSelection
            }
        }
    }

    private var noSelection: some View {
        Group {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing", description: Text("Select a connection or a session."))
        }
    }
}

/// An SSH session: only what OpenSSH reported (host key, method, KEX and cipher from its own
/// log), nothing estimated.
private struct SSHSessionInspector: View {
    let session: SSHSession
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 5) {
                        StatusDot(status: session.status)
                        Text(session.status.label)
                    }
                }
                LabeledContent("Host", value: session.hostLabel)
                LabeledContent("User", value: session.target.username.isEmpty ? "From OpenSSH config" : session.target.username)
                if let since = session.connectedAt {
                    LabeledContent("Connected") {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Duration.since(since, now: context.date))
                                .monospacedDigit()
                        }
                    }
                }
                LabeledContent("Reconnects", value: "\(session.reconnectCount)")
                if let title = session.remoteTitle {
                    LabeledContent("Terminal title", value: title)
                }
            } header: {
                Text(session.title)
            }
            Section("Security") {
                LabeledContent("Signed in with", value: session.authenticationMethod.map(Self.methodLabel) ?? "—")
                LabeledContent("Host key", value: session.hostKeyVerified ? "Verified (known_hosts)" : (session.serverHostKey == nil ? "—" : "Not verified yet"))
                if let key = session.serverHostKey {
                    LabeledContent("Key type", value: key.type)
                    Text(key.fingerprint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Key exchange", value: session.keyExchange ?? "—")
                LabeledContent("Cipher", value: session.cipher ?? "—")
                if let software = session.remoteSoftware {
                    LabeledContent("Server", value: software)
                }
            }
            Section("Effective Settings") {
                let settings = session.settings
                LabeledContent("Authentication", value: settings.authentication.label)
                if let key = session.target.identityFile {
                    LabeledContent("Key file", value: key)
                }
                if let jump = settings.proxyJump {
                    LabeledContent("Jump hosts", value: jump)
                }
                LabeledContent("Agent forwarding", value: settings.forwardAgent ? "On" : "Off")
                LabeledContent("Keepalive", value: settings.serverAliveIntervalSeconds == 0 ? "Off" : "Every \(settings.serverAliveIntervalSeconds) s")
                LabeledContent("TERM", value: settings.terminalType)
            }
            Section {
                HStack {
                    Button("Reconnect") { session.connect() }
                    Button("Disconnect") { session.disconnect() }
                }
            }
        }
        .formStyle(.grouped)
    }

    static func methodLabel(_ method: String) -> String {
        switch method {
        case "publickey": "Public key"
        case "password": "Password"
        case "keyboard-interactive": "Keyboard-interactive"
        case "gssapi-with-mic": "Kerberos (GSSAPI)"
        case "hostbased": "Host-based"
        default: method
        }
    }
}

/// A saved SSH host and its effective settings, with where each comes from.
private struct SSHConnectionInspector: View {
    let connection: Connection
    @Environment(AppModel.self) private var model

    var body: some View {
        let inventory = model.inventory
        let resolved = inventory.resolvedSSHSettings(for: connection)
        Form {
            Section {
                LabeledContent("Address", value: connection.addressLabel)
                LabeledContent("Protocol", value: "SSH")
                LabeledContent("Group", value: inventory.path(of: connection.folderID).map(\.name).joined(separator: " › ").nonEmpty ?? "—")
                if connection.operatingSystemLabel.isEmpty == false {
                    LabeledContent("OS", value: connection.operatingSystemLabel)
                }
                if connection.tags.isEmpty == false {
                    LabeledContent("Tags") {
                        HStack { ForEach(connection.tags, id: \.self) { TagChip(text: $0) } }
                    }
                }
                LabeledContent("Last connected") {
                    if let date = connection.lastConnectedAt {
                        Text(date, format: .dateTime)
                    } else {
                        Text("Never")
                    }
                }
            } header: {
                Text(connection.name)
            }
            Section("Effective Settings") {
                setting("User", inventory.sshUsername(for: connection).nonEmpty ?? "From OpenSSH config", .username)
                setting("Authentication", resolved.authentication.label, .authentication)
                setting("Saved secret", secretLabel(resolved.secret), .secret)
                if let key = resolved.identityFile {
                    setting("Key file", key, .identityFile)
                }
                if let jump = resolved.proxyJump {
                    setting("Jump hosts", jump, .proxyJump)
                }
                setting("Agent forwarding", resolved.forwardAgent ? "On" : "Off", .forwardAgent)
                if resolved.forwardAgent {
                    Label("The server can use your SSH agent's keys while connected.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                setting("Auto-reconnect", resolved.autoReconnect ? "On" : "Off", .autoReconnect)
            }
            if connection.notes.isEmpty == false {
                Section("Notes") {
                    Text(connection.notes)
                        .textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Button("Connect") { model.connect(connection.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Edit…") { model.edit(connection.id) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func secretLabel(_ secret: SSHSecretSource) -> String {
        switch secret {
        case .none: "None (asked when needed)"
        case .connectionSecret: "This connection's password"
        case let .profile(id): model.inventory.credential(id)?.name ?? "Missing credential"
        }
    }

    private func setting(_ title: String, _ value: String, _ key: SSHSettingKey) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                Text(sourceLabel(model.inventory.source(of: key, for: connection)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sourceLabel(_ source: SettingSource) -> String {
        switch source {
        case .connection: "This connection"
        case let .folder(id): "From \(model.inventory.folder(id)?.name ?? "group")"
        case .builtIn: "Default"
        }
    }
}

private struct SessionInspector: View {
    let session: RemoteSession
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 5) {
                        StatusDot(phase: session.phase)
                        Text(session.phase.shortLabel)
                    }
                }
                LabeledContent("Host", value: session.hostLabel)
                if let user = session.signedInAs {
                    LabeledContent("Signed in as", value: user)
                }
                if let since = session.connectedAt {
                    LabeledContent("Connected") {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Duration.since(since, now: context.date))
                                .monospacedDigit()
                        }
                    }
                }
                LabeledContent("Reconnects", value: "\(session.reconnectCount)")
                LabeledContent("Engine", value: session.engineKind.label)
            } header: {
                Text(session.title)
            }

            Section("Display") {
                if let size = session.desktopPixelSize {
                    LabeledContent("Remote desktop", value: "\(Int(size.width)) × \(Int(size.height)) px")
                } else {
                    LabeledContent("Remote desktop", value: "—")
                }
                LabeledContent("Mode", value: session.settings.display.label)
            }

            Section("Performance") {
                let stats = session.statistics
                measured("Frame rate", stats?.framesPerSecond) { String(format: "%.0f fps", $0) }
                measured("Throughput", stats?.wireMegabitsPerSecond) { String(format: "%.2f Mbit/s", $0) }
                measured("Avg. decode", stats?.averageDecodeMilliseconds) { String(format: "%.1f ms", $0) }
                measured("First frame", stats?.firstFrameMilliseconds) { String(format: "%.0f ms", $0) }
                LabeledContent("Codec", value: stats?.codec ?? "—")
                LabeledContent("Hardware decode", value: stats?.hardwareDecoding.map { $0 ? "Yes" : "No" } ?? "—")
                if let stats, stats.failedDecodes > 0 {
                    LabeledContent("Failed decodes", value: "\(stats.failedDecodes)")
                }
            }

            Section("Security") {
                if session.isUnverifiedServer {
                    Label("Standard RDP Security: server not verified", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
                LabeledContent("Security layer", value: session.settings.security.label)
                if session.settings.authentication != .ntlm {
                    LabeledContent("Authentication", value: session.settings.authentication.label)
                }
                LabeledContent("TLS", value: session.tlsProtocol ?? "—")
                LabeledContent("Certificate") {
                    Text(certificateLabel)
                }
                if let sha = session.certificateSHA256 {
                    Text(sha)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Redirection") {
                Toggle("Clipboard", isOn: Binding(get: { session.clipboardEnabled }, set: { session.setClipboardEnabled($0) }))
                LabeledContent("Audio playback", value: session.settings.audioPlaybackEnabled ? "On" : "Off")
                if session.engineKind == .freeRDP {
                    LabeledContent("Microphone", value: session.settings.microphoneEnabled ? "On" : "Off")
                    LabeledContent("Printers", value: session.settings.printersEnabled ? "All Mac printers" : "Off")
                    LabeledContent("Smart cards", value: session.settings.smartCardsEnabled ? "All readers" : "Off")
                    if session.settings.usbDevices.isEmpty == false {
                        LabeledContent("USB", value: session.settings.usbDevices.joined(separator: ", "))
                    }
                }
                if let folder = session.settings.sharedFolderPath {
                    LabeledContent("Shared folder", value: (folder as NSString).lastPathComponent)
                }
                LabeledContent("⌘ shortcuts", value: session.settings.sendsCommandShortcutsToRemote ? "To remote" : "To Mac")
            }

            Section {
                HStack {
                    Button("Reconnect") { session.connect() }
                    Button("Disconnect") { session.disconnect() }
                        .disabled(session.phase.isActive == false && session.phase.isInProgress == false)
                }
                if session.phase.isActive {
                    Button("Send Ctrl+Alt+Del") { session.sendCtrlAltDelete() }
                    Button("Sign Out of Windows…", role: .destructive) {
                        if confirmSignOut(session) { session.signOut() }
                    }
                    .disabled(session.isSigningOut)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var certificateLabel: String {
        if session.certificateTrustedBySystem == true { return "Trusted by macOS" }
        if session.certificateTrustedByUser { return "Trusted by you" }
        if session.certificateSHA256 != nil { return "Not trusted" }
        return "—"
    }

    private func measured(_ title: String, _ value: Double?, format: (Double) -> String) -> some View {
        LabeledContent(title, value: value.map(format) ?? "—")
    }
}

private struct ConnectionInspector: View {
    let connection: Connection
    @Environment(AppModel.self) private var model

    var body: some View {
        let inventory = model.inventory
        let resolved = inventory.resolvedSettings(for: connection)
        Form {
            Section {
                LabeledContent("Address", value: connection.addressLabel)
                LabeledContent("Group", value: inventory.path(of: connection.folderID).map(\.name).joined(separator: " › ").nonEmpty ?? "—")
                if connection.operatingSystemLabel.isEmpty == false {
                    LabeledContent("OS", value: connection.operatingSystemLabel)
                }
                if connection.tags.isEmpty == false {
                    LabeledContent("Tags") {
                        HStack { ForEach(connection.tags, id: \.self) { TagChip(text: $0) } }
                    }
                }
                LabeledContent("Last connected") {
                    if let date = connection.lastConnectedAt {
                        Text(date, format: .dateTime)
                    } else {
                        Text("Never")
                    }
                }
            } header: {
                Text(connection.name)
            }
            Section("Effective Settings") {
                setting("Sign in", credentialLabel(resolved.credential), .credential)
                setting("Display", resolved.display.label, .display)
                setting("Clipboard", resolved.clipboardEnabled ? "On" : "Off", .clipboard)
                setting("Audio", resolved.audioPlaybackEnabled ? "On" : "Off", .audio)
                setting("Auto-reconnect", resolved.autoReconnect ? "On" : "Off", .autoReconnect)
                setting("Security", resolved.security.label, .security)
                if resolved.security == .standardRDP {
                    Label("The server's identity is not verified; you'll be asked before connecting.", systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            let shared = Self.sharedResources(resolved)
            if shared.isEmpty == false {
                Section("Shared with the Server") {
                    ForEach(shared, id: \.self) { item in
                        Label(item, systemImage: "arrow.up.forward.app")
                    }
                }
            }
            if connection.notes.isEmpty == false {
                Section("Notes") {
                    Text(connection.notes)
                        .textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Button("Connect") { model.connect(connection.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Edit…") { model.edit(connection.id) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// What of this Mac the server gets access to, as the user should see it before connecting.
    static func sharedResources(_ settings: ResolvedSettings) -> [String] {
        var items: [String] = []
        if let path = settings.sharedFolderPath { items.append("Folder \(path)") }
        if settings.printersEnabled { items.append("Printers") }
        if settings.smartCardsEnabled { items.append("Smart cards") }
        if settings.microphoneEnabled { items.append("Microphone") }
        if settings.usbDevices.isEmpty == false { items.append("USB \(settings.usbDevices.joined(separator: ", "))") }
        return items
    }

    private func setting(_ title: String, _ value: String, _ key: SettingKey) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                Text(sourceLabel(model.inventory.source(of: key, for: connection)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sourceLabel(_ source: SettingSource) -> String {
        switch source {
        case .connection: "This connection"
        case let .folder(id): "From \(model.inventory.folder(id)?.name ?? "group")"
        case .builtIn: "Default"
        }
    }

    private func credentialLabel(_ assignment: CredentialAssignment) -> String {
        switch assignment {
        case let .shared(id): model.inventory.credential(id)?.name ?? "Missing credential"
        case let .direct(username, domain): domain.isEmpty ? username : "\(domain)\\\(username)"
        case .prompt: "Ask each time"
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
