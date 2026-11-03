import RDPManagerCore
import SwiftUI

/// The inheritable settings of a connection or a group. Each one offers "Inherit", which shows
/// the value it would inherit, or an explicit override.
struct SettingsOverridesSections: View {
    @Binding var settings: ConnectionSettings
    /// What this item would get without its own overrides.
    let inherited: ResolvedSettings
    let profiles: [CredentialProfile]
    /// For a connection's own identity, the password field bound by the editor.
    var directPassword: Binding<String>?
    var hasSavedDirectPassword = false

    var body: some View {
        Section("Sign In") {
            Picker("Credentials", selection: credentialChoice) {
                Text("Inherit (\(label(inherited.credential)))").tag(CredentialChoice.inherit)
                Divider()
                ForEach(profiles) { profile in
                    Text("\(profile.name) — \(profile.identityLabel)").tag(CredentialChoice.shared(profile.id))
                }
                if profiles.isEmpty == false { Divider() }
                Text("Specific user…").tag(CredentialChoice.direct)
                Text("Ask each time").tag(CredentialChoice.prompt)
            }
            if case let .direct(username, domain) = settings.credential {
                TextField("User name", text: Binding(
                    get: { username },
                    set: { settings.credential = .direct(username: $0, domain: domain) }
                ), prompt: Text("user, DOMAIN\\user or user@domain.example"))
                TextField("Domain", text: Binding(
                    get: { domain },
                    set: { settings.credential = .direct(username: username, domain: $0) }
                ), prompt: Text("Optional"))
                if let directPassword {
                    SecureField("Password", text: directPassword, prompt: Text(hasSavedDirectPassword ? "Saved in Keychain — type to replace" : "Optional — asked when connecting"))
                }
            }
        }

        Section("Display") {
            Picker("Resolution", selection: $settings.display) {
                Text("Inherit (\(inherited.display.label))").tag(DisplayMode?.none)
                Divider()
                Text("Match window (HiDPI)").tag(DisplayMode?.some(.matchWindow))
                ForEach(DisplayMode.commonFixedSizes, id: \.self) { mode in
                    Text(mode.label).tag(DisplayMode?.some(mode))
                }
            }
        }

        Section("Redirection") {
            InheritableToggle(title: "Clipboard", value: $settings.clipboardEnabled, inherited: inherited.clipboardEnabled)
            InheritableToggle(title: "Play remote audio", value: $settings.audioPlaybackEnabled, inherited: inherited.audioPlaybackEnabled)
        }

        Section("Behavior") {
            InheritableToggle(title: "Reconnect after network drops", value: $settings.autoReconnect, inherited: inherited.autoReconnect)
            InheritableToggle(title: "Send ⌘ shortcuts to remote (⌘ = Windows key)", value: $settings.sendsCommandShortcutsToRemote, inherited: inherited.sendsCommandShortcutsToRemote)
            Picker("Connection timeout", selection: $settings.timeoutSeconds) {
                Text("Inherit (\(inherited.timeoutSeconds) s)").tag(Int?.none)
                Divider()
                ForEach([10, 20, 30, 60, 120], id: \.self) { Text("\($0) seconds").tag(Int?.some($0)) }
            }
        }
    }

    private enum CredentialChoice: Hashable {
        case inherit, shared(UUID), direct, prompt
    }

    private var credentialChoice: Binding<CredentialChoice> {
        Binding {
            switch settings.credential {
            case nil: .inherit
            case let .shared(id): .shared(id)
            case .direct: .direct
            case .prompt: .prompt
            }
        } set: { choice in
            switch choice {
            case .inherit: settings.credential = nil
            case let .shared(id): settings.credential = .shared(id)
            case .prompt: settings.credential = .prompt
            case .direct:
                if case .direct = settings.credential { return }
                settings.credential = .direct(username: "", domain: "")
            }
        }
    }

    private func label(_ assignment: CredentialAssignment) -> String {
        switch assignment {
        case let .shared(id): profiles.first { $0.id == id }?.name ?? "missing"
        case let .direct(username, domain): domain.isEmpty ? username : "\(domain)\\\(username)"
        case .prompt: "ask each time"
        }
    }
}

/// On / Off / Inherit, showing the inherited value.
struct InheritableToggle: View {
    let title: String
    @Binding var value: Bool?
    let inherited: Bool

    var body: some View {
        Picker(title, selection: $value) {
            Text("Inherit (\(inherited ? "On" : "Off"))").tag(Bool?.none)
            Divider()
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
    }
}
