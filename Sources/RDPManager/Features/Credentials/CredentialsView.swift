import LocalAuthentication
import RDPManagerCore
import SwiftUI

/// Shared identities: RDP sign-ins (user, domain, password), SSH passwords and SSH key files
/// with an optional passphrase. Secrets live in the Keychain; a key stays in its own file.
/// Folders and connections refer to them, so one change reaches every host that uses it.
struct CredentialsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var editing: CredentialEditorRequest?
    @State private var savedSecrets: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Credentials").font(.headline)
                    Text("Passwords and key passphrases are stored in your login Keychain, never in the library file. Keys stay in their files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(CredentialKind.allCases, id: \.self) { kind in
                        Button("New \(kind.label)…") {
                            editing = CredentialEditorRequest(profile: CredentialProfile(name: "", kind: kind, username: ""), isNew: true)
                        }
                    }
                } label: {
                    Label("New Credential", systemImage: "plus")
                }
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            Table(model.inventory.credentials, selection: $selection) {
                TableColumn("Name") { profile in
                    Label(profile.name, systemImage: profile.kind == .sshKey ? "key.horizontal" : "person.badge.key")
                }
                TableColumn("Kind") { profile in
                    Text(profile.kind.label).foregroundStyle(.secondary)
                }
                TableColumn("Identity") { profile in
                    Text(identity(profile)).foregroundStyle(.secondary)
                }
                TableColumn("Secret") { profile in
                    Text(secretLabel(profile))
                        .foregroundStyle(savedSecrets.contains(profile.id) ? .secondary : .tertiary)
                }
                TableColumn("Used by") { profile in
                    let usage = model.inventory.usages(ofCredential: profile.id)
                    Text("\(usage.folders.count) groups, \(usage.connections.count) connections")
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let profile = model.inventory.credential(id) {
                    Button("Edit…") {
                        editing = CredentialEditorRequest(profile: profile, isNew: false)
                    }
                    Divider()
                    Button("Delete", role: .destructive) { delete(profile) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let profile = model.inventory.credential(id) {
                    editing = CredentialEditorRequest(profile: profile, isNew: false)
                }
            }
            .overlay {
                if model.inventory.credentials.isEmpty {
                    ContentUnavailableView {
                        Label("No Shared Credentials", systemImage: "key")
                    } description: {
                        Text("Create an identity once — a regional admin account, an SSH user, a deploy key — and assign it to groups or hosts.")
                    }
                }
            }
        }
        // Whether the profile is new travels with the request: a separate @State read only in
        // this closure reached the sheet stale, so a new credential opened as "Save" and was
        // never added.
        .sheet(item: $editing) { request in
            CredentialEditor(profile: request.profile, isNew: request.isNew) { refresh() }
        }
        .task(id: model.inventory.credentials.map(\.id)) { refresh() }
    }

    private func identity(_ profile: CredentialProfile) -> String {
        switch profile.kind {
        case .sshKey:
            [profile.username.nonEmpty, profile.keyPath].compactMap(\.self).joined(separator: " · ")
        default:
            profile.identityLabel
        }
    }

    private func secretLabel(_ profile: CredentialProfile) -> String {
        let saved = savedSecrets.contains(profile.id)
        return switch profile.kind {
        case .sshKey: saved ? "Passphrase saved" : "No passphrase saved"
        default: saved ? "Saved" : "Asked when connecting"
        }
    }

    static func secretAccount(for profile: CredentialProfile) -> SecretAccount {
        profile.kind == .sshKey ? .sshKeyPassphrase(profile.id) : .credential(profile.id)
    }

    private func refresh() {
        let profiles = model.inventory.credentials
        let credentials = model.credentials
        Task {
            var saved = Set<UUID>()
            for profile in profiles where await credentials.hasPassword(for: Self.secretAccount(for: profile)) {
                saved.insert(profile.id)
            }
            savedSecrets = saved
        }
    }

    private func delete(_ profile: CredentialProfile) {
        model.inventory.deleteCredential(profile.id)
        Task { try? await model.credentials.deletePassword(for: Self.secretAccount(for: profile)) }
    }
}

private struct CredentialEditorRequest: Identifiable {
    var profile: CredentialProfile
    var isNew: Bool
    var id: UUID { profile.id }
}

private struct CredentialEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: CredentialProfile
    let isNew: Bool
    let onSave: () -> Void
    @State private var secret = ""
    @State private var revealed: String?
    @State private var error: String?
    @State private var keyDescription: SSHKeyDescription?
    @State private var isReadingKey = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Kind", value: profile.kind.label)
                TextField("Name", text: $profile.name, prompt: Text(namePrompt))
                switch profile.kind {
                case .rdpPassword:
                    TextField("User name", text: $profile.username, prompt: Text("user, DOMAIN\\user or user@domain.example"))
                    TextField("Domain", text: $profile.domain, prompt: Text("Optional"))
                    SecureField("Password", text: $secret, prompt: Text(isNew ? "Optional — asked when connecting" : "Leave empty to keep the saved one"))
                case .sshPassword:
                    TextField("User", text: $profile.username, prompt: Text("e.g. root or ops"))
                    SecureField("Password", text: $secret, prompt: Text(isNew ? "Optional — asked when connecting" : "Leave empty to keep the saved one"))
                case .sshKey:
                    TextField("User", text: $profile.username, prompt: Text("Optional — the connection's or OpenSSH's user otherwise"))
                    HStack {
                        TextField("Key file", text: keyPathBinding, prompt: Text("~/.ssh/id_ed25519"))
                        Button("Choose…", action: chooseKey)
                    }
                    LabeledContent("Key") {
                        if isReadingKey {
                            ProgressView().controlSize(.small)
                        } else if let keyDescription {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(keyDescription.label)
                                Text(keyDescription.fingerprint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(profile.keyPath == nil ? "—" : "Not readable").foregroundStyle(.secondary)
                        }
                    }
                    SecureField("Passphrase", text: $secret, prompt: Text(isNew ? "Optional — asked when connecting" : "Leave empty to keep the saved one"))
                    Text("The key stays in its file; only its path is stored. Keys held in the Keychain itself aren't supported, because OpenSSH can only read keys from files or an agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isNew == false {
                    LabeledContent(profile.kind == .sshKey ? "Saved passphrase" : "Saved password") {
                        if let revealed {
                            Text(revealed).font(.body.monospaced()).textSelection(.enabled)
                        } else {
                            Button("Reveal…", action: reveal)
                        }
                    }
                }
                TextField("Notes", text: $profile.notes, axis: .vertical)
                    .lineLimit(2 ... 4)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(canSave == false)
            }
            .padding(14)
        }
        .frame(width: 480, height: profile.kind == .sshKey ? 520 : 400)
        .task(id: profile.keyPath) { await readKey() }
    }

    private var namePrompt: String {
        switch profile.kind {
        case .rdpPassword: "e.g. EMEA Admin"
        case .sshPassword: "e.g. Lab root"
        case .sshKey: "e.g. Deploy key"
        }
    }

    private var canSave: Bool {
        guard profile.name.isEmpty == false else { return false }
        switch profile.kind {
        case .rdpPassword, .sshPassword: return profile.username.isEmpty == false
        case .sshKey: return (profile.keyPath ?? "").isEmpty == false
        }
    }

    private var keyPathBinding: Binding<String> {
        Binding(get: { profile.keyPath ?? "" }, set: { profile.keyPath = $0.isEmpty ? nil : $0 })
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        panel.showsHiddenFiles = true
        panel.message = "Choose a private key. It stays in its file; RDP Manager stores only its path."
        if panel.runModal() == .OK, let url = panel.url {
            profile.keyPath = SSHSettingsSections.displayPath(url.path)
        }
    }

    private func readKey() async {
        guard profile.kind == .sshKey, let path = profile.keyPath, path.isEmpty == false else {
            keyDescription = nil
            return
        }
        isReadingKey = true
        keyDescription = await SSHKeyInspector.describe(path)
        isReadingKey = false
    }

    private func save() {
        if profile.kind == .sshKey {
            if let path = profile.keyPath, (try? SSHCommandBuilder.arguments(for: SSHTarget(host: "h", profileKeyPath: path), logPath: "/l")) == nil {
                error = "The key path can't contain quotes or control characters."
                return
            }
            profile.keyType = keyDescription?.label
            profile.keyFingerprint = keyDescription?.fingerprint
            profile.domain = ""
        }
        if profile.kind.isSSH, profile.username.isEmpty == false, SSHCommandBuilder.isValidUsername(profile.username) == false {
            error = "“\(profile.username)” is not a valid user name."
            return
        }
        model.inventory.saveCredential(profile)
        let secret = secret
        let account = CredentialsView.secretAccount(for: profile)
        Task {
            if secret.isEmpty == false {
                do {
                    try await model.credentials.setPassword(secret, for: account)
                } catch {
                    model.alert = AppAlert(title: "Not saved", message: error.localizedDescription)
                }
            }
            onSave()
        }
        dismiss()
    }

    /// Showing a secret needs the Mac's owner: Touch ID or the login password.
    private func reveal() {
        let context = LAContext()
        let account = CredentialsView.secretAccount(for: profile)
        Task {
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show the saved secret for “\(profile.name)”")
                revealed = try await model.credentials.password(for: account) ?? "Not saved"
            } catch {
                self.error = "Not revealed."
            }
        }
    }
}
