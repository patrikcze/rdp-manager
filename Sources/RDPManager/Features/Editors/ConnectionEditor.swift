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
                    TextField("Address", text: $addressText, prompt: Text("server01.example.com or 10.0.0.5:3390"))
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
                SettingsOverridesSections(
                    settings: $connection.settings,
                    inherited: ResolvedSettings(model.inventory.inheritedSettings(forFolder: connection.folderID)),
                    profiles: model.inventory.credentials,
                    directPassword: $password,
                    hasSavedDirectPassword: hasSavedPassword
                )
                Section("RD Gateway") {
                    Label("RD Gateway isn't supported by the current RDP engine yet. Connections go to the host directly — use a VPN to reach hosts behind a gateway.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Details") {
                    TextField("Operating system", text: $connection.operatingSystemLabel, prompt: Text("e.g. Windows Server 2025 (label only)"))
                    TextField("Tags", text: $tagsText, prompt: Text("Comma-separated"))
                    Picker("Color", selection: $connection.color) {
                        Text("Default").tag(TagColor?.none)
                        ForEach(TagColor.allCases, id: \.self) { color in
                            Text(color.name).tag(TagColor?.some(color))
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
        .task {
            if request.isNew == false {
                hasSavedPassword = await model.credentials.hasPassword(for: .connection(connection.id))
            }
        }
    }

    private var addressPreview: String? {
        (try? HostAddress.parse(addressText))?.host
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
            address = try HostAddress.parse(addressText)
        } catch {
            self.error = error.localizedDescription
            return
        }
        var connection = connection
        connection.host = address.host
        connection.port = address.port
        connection.name = connection.name.trimmingCharacters(in: .whitespaces).nonEmpty ?? address.host
        connection.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if case let .direct(username, _) = connection.settings.credential, username.isEmpty {
            self.error = "Enter a user name, or choose another sign-in option."
            return
        }

        if request.isNew {
            connection = model.inventory.addConnection(connection)
        } else {
            model.inventory.update(connection)
        }
        // A password typed here goes straight to the Keychain; one no longer used is removed.
        let account = SecretAccount.connection(connection.id)
        let credentials = model.credentials
        let usesDirect = if case .direct = connection.settings.credential { true } else { false }
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
                        ForEach(TagColor.allCases, id: \.self) { Text($0.name).tag(TagColor?.some($0)) }
                    }
                    TextField("Notes", text: $folder.notes, axis: .vertical)
                        .lineLimit(2 ... 6)
                }
                Section {
                    Text("Connections in this group and its subgroups use these settings unless they set their own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                SettingsOverridesSections(
                    settings: $folder.defaults,
                    inherited: ResolvedSettings(model.inventory.inheritedSettings(forFolder: folder.parentID)),
                    profiles: model.inventory.credentials
                )
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if case .direct = folder.defaults.credential {
                    Text("A group's specific user is asked for a password on each host. Use a shared credential to share one password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    folder.name = folder.name.trimmingCharacters(in: .whitespaces).nonEmpty ?? "Untitled Group"
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
