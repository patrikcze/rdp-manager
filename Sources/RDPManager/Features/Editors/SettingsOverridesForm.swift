import AppKit
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

        Section {
            Picker("Security layer", selection: $settings.security) {
                Text("Inherit (\(inherited.security.label))").tag(SecurityMode?.none)
                Divider()
                ForEach(SecurityMode.allCases, id: \.self) { Text($0.label).tag(SecurityMode?.some($0)) }
            }
            if resolved.security == .standardRDP {
                Label("Standard RDP Security can't verify the server and uses weak RC4 encryption. Use it only for servers that offer nothing else.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Authentication", selection: $settings.authentication) {
                Text("Inherit (\(inherited.authentication.label))").tag(AuthenticationMode?.none)
                Divider()
                ForEach(AuthenticationMode.allCases, id: \.self) { Text($0.label).tag(AuthenticationMode?.some($0)) }
            }
            if resolved.authentication != .ntlm {
                TextField("KDC proxy URL", text: optionalText($settings.kerberosKDCProxyURL),
                          prompt: Text(inherited.kerberosKDCProxyURL ?? "Optional, e.g. https://kdcproxy.example.com/KdcProxy"))
            }
        } header: {
            Text("Security")
        } footer: {
            if resolved.authentication != .ntlm {
                Text("Kerberos uses your user name and password to get a ticket from the domain's KDC, found through DNS, or through the KDC proxy.")
            }
        }

        Section {
            InheritableToggle(title: "Clipboard", value: $settings.clipboardEnabled, inherited: inherited.clipboardEnabled)
            InheritableToggle(title: "Play remote audio", value: $settings.audioPlaybackEnabled, inherited: inherited.audioPlaybackEnabled)
            InheritableToggle(title: "Microphone", value: $settings.microphoneEnabled, inherited: inherited.microphoneEnabled)
            InheritableToggle(title: "Printers", value: $settings.printersEnabled, inherited: inherited.printersEnabled)
            InheritableToggle(title: "Smart cards and security keys (YubiKey)", value: $settings.smartCardsEnabled, inherited: inherited.smartCardsEnabled)
            TextField("USB devices", text: usbText, prompt: Text(inherited.usbDevices.isEmpty ? "Vendor:product IDs, e.g. 1050:0407" : inherited.usbDevices.joined(separator: ", ")))
            HStack {
                TextField("Shared folder", text: optionalText($settings.sharedFolderPath),
                          prompt: Text(inherited.sharedFolderPath ?? "None"))
                Button("Choose…", action: chooseFolder)
            }
        } header: {
            Text("Devices and redirection")
        } footer: {
            Text("Printers are all printers set up on this Mac. Smart cards include every PC/SC reader, such as a YubiKey's PIV interface, for use inside Windows. The shared folder appears as \\\\tsclient\\Mac.")
        }

        Section {
            Picker("Engine", selection: $settings.engine) {
                Text("Inherit (\(inherited.enginePreference.label))").tag(EnginePreference?.none)
                Divider()
                ForEach(EnginePreference.allCases, id: \.self) { Text($0.label).tag(EnginePreference?.some($0)) }
            }
            LabeledContent("Runs on", value: engineSummary)
        } header: {
            Text("RDP engine")
        } footer: {
            Text("RDPKit renders with hardware H.264 and is used whenever it can be. FreeRDP adds Kerberos, Standard RDP Security, printers, smart cards, microphone and USB.")
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

    /// What this item resolves to with its own overrides, for warnings and the engine summary.
    private var resolved: ResolvedSettings {
        ResolvedSettings(settings, defaults: inherited)
    }

    private var engineSummary: String {
        let choice = resolved.engine
        switch choice.kind {
        case .rdpKit:
            if choice.refusal != nil { return "RDPKit — won't connect: Kerberos only needs FreeRDP" }
            return choice.ignoredSettings.isEmpty ? "RDPKit" : "RDPKit (ignores \(choice.ignoredSettings.joined(separator: ", ")))"
        case .freeRDP:
            return choice.freeRDPReasons.isEmpty ? "FreeRDP" : "FreeRDP, for \(choice.freeRDPReasons.joined(separator: ", "))"
        }
    }

    private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private var usbText: Binding<String> {
        Binding(
            get: { settings.usbDevices?.joined(separator: ", ") ?? "" },
            set: { text in
                let ids = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                settings.usbDevices = ids.isEmpty ? nil : ids
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "The server will be able to read, change and delete files in this folder."
        if panel.runModal() == .OK, let url = panel.url {
            settings.sharedFolderPath = url.path
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
