import RDPManagerCore
import SwiftUI

/// Creates or edits a saved connection.
struct ConnectionEditor: View {
    let request: ConnectionEditorRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var connection: Connection
    @State private var addressText: String
    @State private var tagsText: String
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var error: String?

    init(request: ConnectionEditorRequest) {
        self.request = request
        _connection = State(initialValue: request.connection)
        _addressText = State(initialValue: request.connection.host.isEmpty ? "" : request.connection.addressLabel)
        _tagsText = State(initialValue: request.connection.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    Picker("Protocol", selection: protocolBinding) {
                        ForEach(ConnectionProtocol.allCases, id: \.self) { item in
                            Label(item.label, systemImage: item.symbol).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Address", text: $addressText, prompt: Text(connection.isSSH
                        ? "server.example.com, 10.0.0.5:2222 or [fe80::1]"
                        : "server01.example.com or 10.0.0.5:3390"))
                    TextField("Name", text: $connection.name, prompt: Text(addressPreview ?? "Display name"))
                    Picker("Group", selection: $connection.folderID) {
                        Text("None (top level)").tag(UUID?.none)
                        Divider()
                        ForEach(folderChoices, id: \.id) { choice in
                            Text(choice.label).tag(UUID?.some(choice.id))
                        }
                    }
                    Toggle("Favorite", isOn: $connection.isFavorite)
                }
                if connection.isSSH {
                    SSHSettingsSections(
                        settings: $connection.ssh,
                        inherited: ResolvedSSHSettings(model.inventory.inheritedSSHSettings(forFolder: connection.folderID)),
                        profiles: model.inventory.credentials.filter(\.kind.isSSH),
                        connectionPassword: $password,
                        hasSavedConnectionPassword: hasSavedPassword
                    )
                } else {
                    SettingsOverridesSections(
                        settings: $connection.settings,
                        inherited: ResolvedSettings(model.inventory.inheritedSettings(forFolder: connection.folderID)),
                        profiles: model.inventory.credentials.filter { $0.kind == .rdpPassword },
                        directPassword: $password,
                        hasSavedDirectPassword: hasSavedPassword
                    )
                    Section("RD Gateway") {
                        Label("RD Gateway isn't supported by the current RDP engine yet. Connections go to the host directly — use a VPN to reach hosts behind a gateway.", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Details") {
                    TextField("Operating system", text: $connection.operatingSystemLabel, prompt: Text("e.g. Windows Server 2025 (label only)"))
                    TextField("Tags", text: $tagsText, prompt: Text("Comma-separated"))
                    Picker("Color", selection: $connection.color) {
                        Text("Default").tag(TagColor?.none)
                        ForEach(TagColor.allCases, id: \.self) { color in
                            Label { Text(color.name) } icon: { color.swatch }
                                .tag(TagColor?.some(color))
                        }
                    }
                    TextField("Notes", text: $connection.notes, axis: .vertical)
                        .lineLimit(3 ... 8)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if request.isNew {
                    Button("Save and Connect") { save(connect: true) }
                }
                Button(request.isNew ? "Add" : "Save") { save(connect: false) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 560, height: 680)
        .task(id: connection.connectionProtocol) {
            if request.isNew == false {
                hasSavedPassword = await model.credentials.hasPassword(for: passwordAccount)
            }
        }
    }

    /// Where this connection's own password lives: a separate namespace per protocol.
    private var passwordAccount: SecretAccount {
        connection.isSSH ? .sshPassword(connection.id) : .connection(connection.id)
    }

    /// Switching the protocol keeps a port that was set on purpose; a default port follows.
    private var protocolBinding: Binding<ConnectionProtocol> {
        Binding {
            connection.connectionProtocol
        } set: { new in
            let old = connection.connectionProtocol
            guard new != old else { return }
            if let address = try? HostAddress.parse(addressText, defaultPort: old.defaultPort) {
                let port = old.port(address.port, whenSwitchingTo: new)
                let host = address.host.contains(":") ? "[\(address.host)]" : address.host
                addressText = port == new.defaultPort ? host : "\(host):\(port)"
            }
            connection.connectionProtocol = new
            password = ""
        }
    }

    private var addressPreview: String? {
        (try? HostAddress.parse(addressText, defaultPort: connection.connectionProtocol.defaultPort))?.host
    }

    private var folderChoices: [(id: UUID, label: String)] {
        var result: [(UUID, String)] = []
        func walk(_ parent: UUID?, depth: Int) {
            for folder in model.inventory.subfolders(of: parent) {
                result.append((folder.id, String(repeating: "    ", count: depth) + folder.name))
                walk(folder.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return result
    }

    private func save(connect: Bool) {
        let address: HostAddress
        do {
            address = try HostAddress.parse(addressText, defaultPort: connection.connectionProtocol.defaultPort)
        } catch {
            self.error = error.localizedDescription
            return
        }
        if connection.isSSH, let problem = connection.ssh.validationError(host: address.host) {
            self.error = problem
            return
        }
        var connection = connection
        connection.host = address.host
        connection.port = address.port
        connection.name = connection.name.trimmingCharacters(in: .whitespaces).nonEmpty ?? address.host
        connection.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if connection.isSSH == false, case let .direct(username, _) = connection.settings.credential, username.isEmpty {
            self.error = "Enter a user name, or choose another sign-in option."
            return
        }

        if request.isNew {
            connection = model.inventory.addConnection(connection)
        } else {
            model.inventory.update(connection)
        }
        // A password typed here goes straight to the Keychain; one no longer used is removed.
        // Only the namespace of the connection's protocol is touched.
        let account = passwordAccount
        let credentials = model.credentials
        let usesDirect = if connection.isSSH {
            connection.ssh.secret == .connectionSecret
        } else if case .direct = connection.settings.credential { true } else { false }
        let password = password
        let savedID = connection.id
        Task {
            do {
                if usesDirect, password.isEmpty == false {
                    try await credentials.setPassword(password, for: account)
                } else if usesDirect == false {
                    try await credentials.deletePassword(for: account)
                }
            } catch {
                model.alert = AppAlert(title: "Password not saved", message: error.localizedDescription)
            }
            if connect {
                model.connect(savedID)
            }
        }
        model.sidebarSelection = .connection(connection.id)
        dismiss()
    }
}

/// Edits a group's name, color, notes and the defaults its connections inherit.
struct FolderEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folder: Folder
    @State private var showsSSH = false
    @State private var sshError: String?

    init(folder: Folder) {
        _folder = State(initialValue: folder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Group") {
                    TextField("Name", text: $folder.name)
                    Picker("Color", selection: $folder.color) {
                        Text("Default").tag(TagColor?.none)
                        ForEach(TagColor.allCases, id: \.self) { color in
                            Label { Text(color.name) } icon: { color.swatch }
                                .tag(TagColor?.some(color))
                        }
                    }
                    TextField("Notes", text: $folder.notes, axis: .vertical)
                        .lineLimit(2 ... 6)
                }
                Section {
                    Text("Connections in this group and its subgroups use these settings unless they set their own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Picker("Settings for", selection: $showsSSH) {
                    Text("RDP connections").tag(false)
                    Text("SSH connections").tag(true)
                }
                .pickerStyle(.segmented)
                if showsSSH {
                    SSHSettingsSections(
                        settings: $folder.sshDefaults,
                        inherited: ResolvedSSHSettings(model.inventory.inheritedSSHSettings(forFolder: folder.parentID)),
                        profiles: model.inventory.credentials.filter(\.kind.isSSH)
                    )
                } else {
                    SettingsOverridesSections(
                        settings: $folder.defaults,
                        inherited: ResolvedSettings(model.inventory.inheritedSettings(forFolder: folder.parentID)),
                        profiles: model.inventory.credentials.filter { $0.kind == .rdpPassword }
                    )
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let sshError {
                    Label(sshError, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                } else if case .direct = folder.defaults.credential {
                    Text("A group's specific user is asked for a password on each host. Use a shared credential to share one password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    folder.name = folder.name.trimmingCharacters(in: .whitespaces).nonEmpty ?? "Untitled Group"
                    if let problem = folder.sshDefaults.validationError(host: "group.invalid") {
                        showsSSH = true
                        sshError = problem
                        return
                    }
                    model.inventory.update(folder)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 540, height: 600)
    }
}
