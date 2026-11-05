import LocalAuthentication
import RDPManagerCore
import SwiftUI

/// Shared identities: a name, a user and domain, and a password in the Keychain. Folders and
/// connections refer to them, so one password change reaches every host that uses it.
struct CredentialsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var editing: CredentialEditorRequest?
    @State private var savedPasswords: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Credentials").font(.headline)
                    Text("Passwords are stored in your login Keychain, never in the library file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editing = CredentialEditorRequest(profile: CredentialProfile(name: "", username: ""), isNew: true)
                } label: {
                    Label("New Credential", systemImage: "plus")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            Table(model.inventory.credentials, selection: $selection) {
                TableColumn("Name") { profile in
                    Label(profile.name, systemImage: "person.badge.key")
                }
                TableColumn("Identity") { profile in
                    Text(profile.identityLabel).foregroundStyle(.secondary)
                }
                TableColumn("Password") { profile in
                    Text(savedPasswords.contains(profile.id) ? "Saved" : "Asked when connecting")
                        .foregroundStyle(savedPasswords.contains(profile.id) ? .secondary : .tertiary)
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
                    Button("Delete", role: .destructive) { delete(id) }
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
                        Text("Create an identity once — for example a regional admin account — and assign it to groups or hosts.")
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

    private func refresh() {
        let profiles = model.inventory.credentials
        let credentials = model.credentials
        Task {
            var saved = Set<UUID>()
            for profile in profiles where await credentials.hasPassword(for: .credential(profile.id)) {
                saved.insert(profile.id)
            }
            savedPasswords = saved
        }
    }

    private func delete(_ id: UUID) {
        model.inventory.deleteCredential(id)
        Task { try? await model.credentials.deletePassword(for: .credential(id)) }
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
    @State private var password = ""
    @State private var revealed: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $profile.name, prompt: Text("e.g. EMEA Admin"))
                TextField("User name", text: $profile.username, prompt: Text("user, DOMAIN\\user or user@domain.example"))
                TextField("Domain", text: $profile.domain, prompt: Text("Optional"))
                SecureField("Password", text: $password, prompt: Text(isNew ? "Optional — asked when connecting" : "Leave empty to keep the saved one"))
                if isNew == false {
                    LabeledContent("Saved password") {
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
                    .disabled(profile.name.isEmpty || profile.username.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 460, height: 400)
    }

    private func save() {
        model.inventory.saveCredential(profile)
        let password = password
        let account = SecretAccount.credential(profile.id)
        Task {
            if password.isEmpty == false {
                do {
                    try await model.credentials.setPassword(password, for: account)
                } catch {
                    model.alert = AppAlert(title: "Password not saved", message: error.localizedDescription)
                }
            }
            onSave()
        }
        dismiss()
    }

    /// Showing a password needs the Mac's owner: Touch ID or the login password.
    private func reveal() {
        let context = LAContext()
        let account = SecretAccount.credential(profile.id)
        Task {
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show the saved password for “\(profile.name)”")
                revealed = try await model.credentials.password(for: account) ?? "Not saved"
            } catch {
                self.error = "Not revealed."
            }
        }
    }
}
