import AppKit
import RDPManagerCore
import SwiftUI

/// The inheritable SSH settings of a connection or a group. As in the RDP form, every setting
/// offers "Inherit", showing the value it would inherit.
struct SSHSettingsSections: View {
    @Binding var settings: SSHConnectionSettings
    let inherited: ResolvedSSHSettings
    /// SSH credential profiles (password or key) the connection may use.
    let profiles: [CredentialProfile]
    /// For a connection: its own password field. Nil for a group.
    var connectionPassword: Binding<String>?
    var hasSavedConnectionPassword = false

    private var resolved: ResolvedSSHSettings {
        ResolvedSSHSettings(settings, defaults: inherited)
    }

    var body: some View {
        Section {
            TextField("User", text: optionalText($settings.username),
                      prompt: Text(inherited.username.isEmpty ? "From OpenSSH config, else your Mac user" : "Inherit (\(inherited.username))"))
            Picker("Authentication", selection: $settings.authentication) {
                Text("Inherit (\(inherited.authentication.label))").tag(SSHAuthMethod?.none)
                Divider()
                ForEach(SSHAuthMethod.allCases, id: \.self) { Text($0.label).tag(SSHAuthMethod?.some($0)) }
            }
            Picker("Saved secret", selection: secretChoice) {
                Text("Inherit (\(secretLabel(inherited.secret)))").tag(SecretChoice.inherit)
                Divider()
                Text("None — ask when needed").tag(SecretChoice.none)
                if connectionPassword != nil {
                    Text("This connection's password").tag(SecretChoice.connection)
                }
                if profiles.isEmpty == false { Divider() }
                ForEach(profiles) { profile in
                    Text("\(profile.name) — \(profile.kind.label)").tag(SecretChoice.profile(profile.id))
                }
            }
            if settings.secret == .connectionSecret, let connectionPassword {
                SecureField("Password", text: connectionPassword,
                            prompt: Text(hasSavedConnectionPassword ? "Saved in Keychain — type to replace" : "Optional — asked when connecting"))
            }
            if usesKeyProfile == false, resolved.authentication == .publicKey || resolved.authentication == .automatic || settings.identityFile != nil {
                HStack {
                    TextField("Key file", text: optionalText($settings.identityFile),
                              prompt: Text(inherited.identityFile.map { "Inherit (\($0))" } ?? "Optional, e.g. ~/.ssh/id_ed25519"))
                    Button("Choose…") { chooseFile(\.identityFile, message: "Choose a private key. It stays in its file; RDP Manager stores only its path.") }
                }
            }
        } header: {
            Text("Sign In")
        } footer: {
            signInFooter
        }

        Section("Connection") {
            TextField("Host alias", text: optionalText($settings.hostAlias),
                      prompt: Text(inherited.hostAlias.map { "Inherit (\($0))" } ?? "Optional: a Host from ~/.ssh/config"))
            TextField("Jump hosts", text: optionalText($settings.proxyJump),
                      prompt: Text(inherited.proxyJump.map { "Inherit (\($0))" } ?? "Optional: [user@]host[:port], comma-separated"))
            Picker("Connect timeout", selection: $settings.connectTimeoutSeconds) {
                Text("Inherit (\(inherited.connectTimeoutSeconds) s)").tag(Int?.none)
                Divider()
                ForEach([5, 10, 20, 30, 60], id: \.self) { Text("\($0) seconds").tag(Int?.some($0)) }
            }
            Picker("Keepalive", selection: $settings.serverAliveIntervalSeconds) {
                Text("Inherit (\(inherited.serverAliveIntervalSeconds == 0 ? "off" : "every \(inherited.serverAliveIntervalSeconds) s"))").tag(Int?.none)
                Divider()
                Text("Off").tag(Int?.some(0))
                ForEach([15, 30, 60, 120], id: \.self) { Text("Every \($0) seconds").tag(Int?.some($0)) }
            }
            InheritableToggle(title: "Compression", value: $settings.compression, inherited: inherited.compression)
            InheritableToggle(title: "Reconnect after network drops", value: $settings.autoReconnect, inherited: inherited.autoReconnect)
        }

        Section {
            InheritableToggle(title: "Forward SSH agent", value: $settings.forwardAgent, inherited: inherited.forwardAgent)
            if resolved.forwardAgent {
                Label("Anyone with root on this server — or on a server you jump to from it — can use the keys in your SSH agent while you're connected. Turn this on only for servers you fully trust.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if resolved.authentication == .gssapi || settings.gssapiDelegateCredentials != nil {
                InheritableToggle(title: "Delegate Kerberos ticket", value: $settings.gssapiDelegateCredentials, inherited: inherited.gssapiDelegateCredentials)
            }
            TextField("Send environment variables", text: environmentText,
                      prompt: Text(inherited.sendEnvironment.isEmpty ? "Optional: names, e.g. LC_ALL" : inherited.sendEnvironment.joined(separator: ", ")))
        } header: {
            Text("Forwarding")
        } footer: {
            Text("Port forwardings and X11 are not offered. Variables are sent only if the server's AcceptEnv allows them.")
        }

        Section {
            InheritableToggle(title: "Use only the chosen key (IdentitiesOnly)", value: $settings.identitiesOnly, inherited: inherited.identitiesOnly)
            HStack {
                TextField("Certificate file", text: optionalText($settings.certificateFile),
                          prompt: Text(inherited.certificateFile.map { "Inherit (\($0))" } ?? "Optional, e.g. ~/.ssh/id_ed25519-cert.pub"))
                Button("Choose…") { chooseFile(\.certificateFile, message: "Choose an OpenSSH certificate.") }
            }
            TextField("Agent socket", text: optionalText($settings.identityAgent),
                      prompt: Text(inherited.identityAgent.map { "Inherit (\($0))" } ?? "Optional: IdentityAgent, e.g. 1Password's"))
            TextField("Terminal type", text: optionalText($settings.terminalType), prompt: Text("Inherit (\(inherited.terminalType))"))
            TextField("Start in directory", text: optionalText($settings.startupDirectory),
                      prompt: Text(inherited.startupDirectory.map { "Inherit (\($0))" } ?? "Optional"))
            TextField("Run command", text: optionalText($settings.startupCommand),
                      prompt: Text(inherited.startupCommand.map { "Inherit (\($0))" } ?? "Optional: runs instead of the login shell"))
        } header: {
            Text("Advanced")
        } footer: {
            Text("A startup command runs on the server as you, with your shell. Commands and directories are never taken from imported libraries or ~/.ssh/config.")
        }
    }

    @ViewBuilder
    private var signInFooter: some View {
        switch resolved.authentication {
        case .gssapi:
            Text("Kerberos needs a ticket on this Mac (kinit or Ticket Viewer) and the server's full DNS name; signing in to macOS doesn't always give you one. The server must accept GSSAPI (e.g. AD-joined with SSSD).")
        case .agent:
            Text("Uses the keys in your SSH agent (SSH_AUTH_SOCK), or the agent socket set under Advanced.")
        case .automatic:
            Text("OpenSSH decides from ~/.ssh/config: agent and default keys first, then a password or code, which the app asks for.")
        default:
            Text("Secrets stay in the Keychain. A password or passphrase is offered to OpenSSH only when it asks for this host's user or this key.")
        }
    }

    private var usesKeyProfile: Bool {
        if case let .profile(id) = resolved.secret, profiles.first(where: { $0.id == id })?.kind == .sshKey { return true }
        return false
    }

    private enum SecretChoice: Hashable {
        case inherit, none, connection, profile(UUID)
    }

    private var secretChoice: Binding<SecretChoice> {
        Binding {
            switch settings.secret {
            case nil: .inherit
            case SSHSecretSource.none?: .none
            case .connectionSecret?: .connection
            case let .profile(id)?: .profile(id)
            }
        } set: { choice in
            switch choice {
            case .inherit: settings.secret = nil
            case .none: settings.secret = SSHSecretSource.none
            case .connection: settings.secret = .connectionSecret
            case let .profile(id): settings.secret = .profile(id)
            }
        }
    }

    private func secretLabel(_ secret: SSHSecretSource) -> String {
        switch secret {
        case .none: "none"
        case .connectionSecret: "own password"
        case let .profile(id): profiles.first { $0.id == id }?.name ?? "missing"
        }
    }

    private var environmentText: Binding<String> {
        Binding(
            get: { settings.sendEnvironment?.joined(separator: ", ") ?? "" },
            set: { text in
                let names = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                settings.sendEnvironment = names.isEmpty ? nil : names
            }
        )
    }

    private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func chooseFile(_ keyPath: WritableKeyPath<SSHConnectionSettings, String?>, message: String) {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url {
            settings[keyPath: keyPath] = Self.displayPath(url.path)
        }
    }

    /// `/Users/me/.ssh/id` → `~/.ssh/id`, so a path survives on another Mac with another user.
    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension SSHConnectionSettings {
    /// Why these settings can't become ssh arguments, or nil when they can.
    func validationError(host: String) -> String? {
        let target = SSHTarget(host: host, settings: ResolvedSSHSettings(self))
        do {
            _ = try SSHCommandBuilder.arguments(for: target, logPath: "/tmp/check")
            if let username, username.isEmpty == false, SSHCommandBuilder.isValidUsername(username) == false {
                return "“\(username)” is not a valid user name."
            }
            if let type = terminalType, SSHCommandBuilder.isValidTerminalType(type) == false {
                return "“\(type)” is not a valid terminal type."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
