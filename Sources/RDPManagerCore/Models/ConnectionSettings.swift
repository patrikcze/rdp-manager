import Foundation

/// Settings a folder sets as defaults and a connection may override. Every field is optional:
/// nil means "inherit from the parent folder", and at the root, the built-in default.
/// New fields must stay optional so libraries saved by older versions keep decoding.
public struct ConnectionSettings: Codable, Equatable, Hashable, Sendable {
    public var credential: CredentialAssignment?
    public var display: DisplayMode?
    public var clipboardEnabled: Bool?
    public var audioPlaybackEnabled: Bool?
    /// Seconds each connection milestone may take before the attempt fails.
    public var timeoutSeconds: Int?
    /// Reconnect on its own after the network drops a session that was showing the desktop.
    public var autoReconnect: Bool?
    /// While a session has focus, ⌘ and ⌃ shortcuts go to the remote desktop (⌘ as the Windows key).
    public var sendsCommandShortcutsToRemote: Bool?
    /// Which security layers the connection may use.
    public var security: SecurityMode?
    /// How Network Level Authentication proves the identity.
    public var authentication: AuthenticationMode?
    /// Optional Kerberos KDC proxy (KKDCP) URL, for KDCs not reachable directly.
    public var kerberosKDCProxyURL: String?
    public var printersEnabled: Bool?
    /// Smart card readers and security keys with a PIV/CCID interface, such as YubiKey.
    public var smartCardsEnabled: Bool?
    public var microphoneEnabled: Bool?
    /// USB devices to redirect, as "vvvv:pppp" vendor and product IDs in hex.
    public var usbDevices: [String]?
    /// A folder on this Mac shown on the server as \\tsclient\<name>.
    public var sharedFolderPath: String?
    public var engine: EnginePreference?

    public init(
        credential: CredentialAssignment? = nil,
        display: DisplayMode? = nil,
        clipboardEnabled: Bool? = nil,
        audioPlaybackEnabled: Bool? = nil,
        timeoutSeconds: Int? = nil,
        autoReconnect: Bool? = nil,
        sendsCommandShortcutsToRemote: Bool? = nil,
        security: SecurityMode? = nil,
        authentication: AuthenticationMode? = nil,
        kerberosKDCProxyURL: String? = nil,
        printersEnabled: Bool? = nil,
        smartCardsEnabled: Bool? = nil,
        microphoneEnabled: Bool? = nil,
        usbDevices: [String]? = nil,
        sharedFolderPath: String? = nil,
        engine: EnginePreference? = nil
    ) {
        self.credential = credential
        self.display = display
        self.clipboardEnabled = clipboardEnabled
        self.audioPlaybackEnabled = audioPlaybackEnabled
        self.timeoutSeconds = timeoutSeconds
        self.autoReconnect = autoReconnect
        self.sendsCommandShortcutsToRemote = sendsCommandShortcutsToRemote
        self.security = security
        self.authentication = authentication
        self.kerberosKDCProxyURL = kerberosKDCProxyURL
        self.printersEnabled = printersEnabled
        self.smartCardsEnabled = smartCardsEnabled
        self.microphoneEnabled = microphoneEnabled
        self.usbDevices = usbDevices
        self.sharedFolderPath = sharedFolderPath
        self.engine = engine
    }

    /// Fields set here win; the rest come from `parent`.
    public func overlaying(_ parent: ConnectionSettings) -> ConnectionSettings {
        ConnectionSettings(
            credential: credential ?? parent.credential,
            display: display ?? parent.display,
            clipboardEnabled: clipboardEnabled ?? parent.clipboardEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled ?? parent.audioPlaybackEnabled,
            timeoutSeconds: timeoutSeconds ?? parent.timeoutSeconds,
            autoReconnect: autoReconnect ?? parent.autoReconnect,
            sendsCommandShortcutsToRemote: sendsCommandShortcutsToRemote ?? parent.sendsCommandShortcutsToRemote,
            security: security ?? parent.security,
            authentication: authentication ?? parent.authentication,
            kerberosKDCProxyURL: kerberosKDCProxyURL ?? parent.kerberosKDCProxyURL,
            printersEnabled: printersEnabled ?? parent.printersEnabled,
            smartCardsEnabled: smartCardsEnabled ?? parent.smartCardsEnabled,
            microphoneEnabled: microphoneEnabled ?? parent.microphoneEnabled,
            usbDevices: usbDevices ?? parent.usbDevices,
            sharedFolderPath: sharedFolderPath ?? parent.sharedFolderPath,
            engine: engine ?? parent.engine
        )
    }

    public var isEmpty: Bool {
        self == ConnectionSettings()
    }

    public func has(_ key: SettingKey) -> Bool {
        switch key {
        case .credential: credential != nil
        case .display: display != nil
        case .clipboard: clipboardEnabled != nil
        case .audio: audioPlaybackEnabled != nil
        case .timeout: timeoutSeconds != nil
        case .autoReconnect: autoReconnect != nil
        case .commandShortcuts: sendsCommandShortcutsToRemote != nil
        case .security: security != nil
        case .authentication: authentication != nil
        case .printers: printersEnabled != nil
        case .smartCards: smartCardsEnabled != nil
        case .microphone: microphoneEnabled != nil
        case .usb: usbDevices != nil
        case .sharedFolder: sharedFolderPath != nil
        case .engine: engine != nil
        }
    }
}

public enum SettingKey: CaseIterable, Sendable {
    case credential, display, clipboard, audio, timeout, autoReconnect, commandShortcuts
    case security, authentication, printers, smartCards, microphone, usb, sharedFolder, engine
}

/// Who a connection signs in as.
public enum CredentialAssignment: Codable, Equatable, Hashable, Sendable {
    /// A shared `CredentialProfile`.
    case shared(UUID)
    /// An identity of this connection or folder alone; a password, if saved, is stored under
    /// `SecretAccount.connection(id)` of the connection that uses it.
    case direct(username: String, domain: String)
    /// Ask every time.
    case prompt
}

/// The security layer a connection negotiates.
public enum SecurityMode: String, Codable, CaseIterable, Sendable {
    /// Network Level Authentication, else TLS. The server's identity is checked.
    case automatic
    /// Network Level Authentication only.
    case nla
    /// TLS without Network Level Authentication: the server's logon screen asks to sign in.
    case tls
    /// Standard RDP Security (RC4): for old or embedded servers. The server's identity cannot be
    /// verified and the encryption is weak, so it must be chosen per connection or group.
    case standardRDP

    public var label: String {
        switch self {
        case .automatic: "Automatic (NLA, then TLS)"
        case .nla: "NLA only"
        case .tls: "TLS only"
        case .standardRDP: "Standard RDP Security (insecure)"
        }
    }
}

/// How Network Level Authentication proves the user's identity.
public enum AuthenticationMode: String, Codable, CaseIterable, Sendable {
    case ntlm
    /// Kerberos, falling back to NTLM when no ticket can be obtained.
    case kerberos
    /// Kerberos only: fails instead of falling back to NTLM.
    case kerberosOnly

    public var label: String {
        switch self {
        case .ntlm: "NTLM"
        case .kerberos: "Kerberos (NTLM fallback)"
        case .kerberosOnly: "Kerberos only"
        }
    }
}

/// Which RDP engine a connection runs on.
public enum EnginePreference: String, Codable, CaseIterable, Sendable {
    /// RDPKit unless a setting needs FreeRDP.
    case automatic
    case rdpKit
    case freeRDP

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .rdpKit: "RDPKit"
        case .freeRDP: "FreeRDP"
        }
    }
}

/// How large the remote desktop is.
public enum DisplayMode: Codable, Equatable, Hashable, Sendable {
    /// The desktop follows the session's view, at the display's backing scale (HiDPI).
    case matchWindow
    /// A fixed desktop size in pixels, scaled to fit the view.
    case fixed(width: Int, height: Int)

    public var label: String {
        switch self {
        case .matchWindow: "Match window"
        case let .fixed(width, height): "\(width) × \(height)"
        }
    }

    public static let commonFixedSizes: [DisplayMode] = [
        .fixed(width: 1280, height: 720),
        .fixed(width: 1366, height: 768),
        .fixed(width: 1600, height: 900),
        .fixed(width: 1920, height: 1080),
        .fixed(width: 2560, height: 1440),
        .fixed(width: 3840, height: 2160),
    ]
}

/// Settings with every inherited value filled in; what a session actually connects with.
public struct ResolvedSettings: Equatable, Sendable {
    public var credential: CredentialAssignment
    public var display: DisplayMode
    public var clipboardEnabled: Bool
    public var audioPlaybackEnabled: Bool
    public var timeoutSeconds: Int
    public var autoReconnect: Bool
    public var sendsCommandShortcutsToRemote: Bool
    public var security: SecurityMode
    public var authentication: AuthenticationMode
    public var kerberosKDCProxyURL: String?
    public var printersEnabled: Bool
    public var smartCardsEnabled: Bool
    public var microphoneEnabled: Bool
    public var usbDevices: [String]
    public var sharedFolderPath: String?
    public var enginePreference: EnginePreference

    /// The built-in defaults at the top of every inheritance chain. Clipboard sharing is on as
    /// in Microsoft's client; device redirection is off until a folder or connection asks.
    public static let builtIn = ResolvedSettings(
        credential: .prompt,
        display: .matchWindow,
        clipboardEnabled: true,
        audioPlaybackEnabled: false,
        timeoutSeconds: 20,
        autoReconnect: true,
        sendsCommandShortcutsToRemote: true,
        security: .automatic,
        authentication: .ntlm,
        kerberosKDCProxyURL: nil,
        printersEnabled: false,
        smartCardsEnabled: false,
        microphoneEnabled: false,
        usbDevices: [],
        sharedFolderPath: nil,
        enginePreference: .automatic
    )

    public init(
        credential: CredentialAssignment,
        display: DisplayMode,
        clipboardEnabled: Bool,
        audioPlaybackEnabled: Bool,
        timeoutSeconds: Int,
        autoReconnect: Bool,
        sendsCommandShortcutsToRemote: Bool,
        security: SecurityMode = .automatic,
        authentication: AuthenticationMode = .ntlm,
        kerberosKDCProxyURL: String? = nil,
        printersEnabled: Bool = false,
        smartCardsEnabled: Bool = false,
        microphoneEnabled: Bool = false,
        usbDevices: [String] = [],
        sharedFolderPath: String? = nil,
        enginePreference: EnginePreference = .automatic
    ) {
        self.credential = credential
        self.display = display
        self.clipboardEnabled = clipboardEnabled
        self.audioPlaybackEnabled = audioPlaybackEnabled
        self.timeoutSeconds = timeoutSeconds
        self.autoReconnect = autoReconnect
        self.sendsCommandShortcutsToRemote = sendsCommandShortcutsToRemote
        self.security = security
        self.authentication = authentication
        self.kerberosKDCProxyURL = kerberosKDCProxyURL
        self.printersEnabled = printersEnabled
        self.smartCardsEnabled = smartCardsEnabled
        self.microphoneEnabled = microphoneEnabled
        self.usbDevices = usbDevices
        self.sharedFolderPath = sharedFolderPath
        self.enginePreference = enginePreference
    }

    public init(_ settings: ConnectionSettings, defaults: ResolvedSettings = .builtIn) {
        self.init(
            credential: settings.credential ?? defaults.credential,
            display: settings.display ?? defaults.display,
            clipboardEnabled: settings.clipboardEnabled ?? defaults.clipboardEnabled,
            audioPlaybackEnabled: settings.audioPlaybackEnabled ?? defaults.audioPlaybackEnabled,
            timeoutSeconds: min(max(settings.timeoutSeconds ?? defaults.timeoutSeconds, 5), 120),
            autoReconnect: settings.autoReconnect ?? defaults.autoReconnect,
            sendsCommandShortcutsToRemote: settings.sendsCommandShortcutsToRemote
                ?? defaults.sendsCommandShortcutsToRemote,
            security: settings.security ?? defaults.security,
            authentication: settings.authentication ?? defaults.authentication,
            kerberosKDCProxyURL: settings.kerberosKDCProxyURL ?? defaults.kerberosKDCProxyURL,
            printersEnabled: settings.printersEnabled ?? defaults.printersEnabled,
            smartCardsEnabled: settings.smartCardsEnabled ?? defaults.smartCardsEnabled,
            microphoneEnabled: settings.microphoneEnabled ?? defaults.microphoneEnabled,
            usbDevices: (settings.usbDevices ?? defaults.usbDevices).compactMap(USBDeviceID.normalized),
            sharedFolderPath: (settings.sharedFolderPath ?? defaults.sharedFolderPath).flatMap { $0.isEmpty ? nil : $0 },
            enginePreference: settings.engine ?? defaults.enginePreference
        )
    }

    /// The engine this connection runs on, and what made it choose FreeRDP.
    public var engine: EngineChoice {
        EngineChoice(for: self)
    }
}

/// The RDP engine a session uses. RDPKit (pure Swift, hardware H.264) runs every connection it
/// can; FreeRDP 3 takes the ones that need what only it has.
public enum RDPEngineKind: String, Sendable {
    case rdpKit
    case freeRDP

    public var label: String {
        switch self {
        case .rdpKit: "RDPKit"
        case .freeRDP: "FreeRDP"
        }
    }
}

public struct EngineChoice: Equatable, Sendable {
    public var kind: RDPEngineKind
    /// The settings that need FreeRDP, in words; empty when RDPKit runs or FreeRDP was chosen.
    public var freeRDPReasons: [String]
    private var authentication: AuthenticationMode

    public init(for settings: ResolvedSettings) {
        authentication = settings.authentication
        var reasons: [String] = []
        if settings.security == .standardRDP { reasons.append("Standard RDP Security") }
        if settings.authentication != .ntlm { reasons.append("Kerberos") }
        if settings.printersEnabled { reasons.append("printers") }
        if settings.smartCardsEnabled { reasons.append("smart cards") }
        if settings.microphoneEnabled { reasons.append("microphone") }
        if settings.usbDevices.isEmpty == false { reasons.append("USB devices") }
        freeRDPReasons = reasons
        switch settings.enginePreference {
        case .rdpKit: kind = .rdpKit
        case .freeRDP: kind = .freeRDP
        case .automatic: kind = reasons.isEmpty ? .rdpKit : .freeRDP
        }
    }

    /// Settings that the chosen engine cannot honour (RDPKit forced despite FreeRDP-only needs).
    public var ignoredSettings: [String] {
        kind == .rdpKit ? freeRDPReasons : []
    }

    /// Why this session must not start at all. "Kerberos only" is a promise never to sign in
    /// with NTLM; RDPKit has no Kerberos and would sign in with NTLM, so it doesn't connect.
    public var refusal: String? {
        guard kind == .rdpKit, authentication == .kerberosOnly else { return nil }
        return "Kerberos only needs the FreeRDP engine: RDPKit has no Kerberos and would sign in with NTLM. Set the engine to Automatic or FreeRDP, or allow NTLM fallback."
    }

    /// What the session tells the user about settings RDPKit can't honour, in plain words.
    public var notice: String? {
        guard refusal == nil, ignoredSettings.isEmpty == false else { return nil }
        var parts: [String] = []
        if ignoredSettings.contains("Kerberos") {
            parts.append("RDPKit has no Kerberos, so this session signs in with NTLM.")
        }
        let others = ignoredSettings.filter { $0 != "Kerberos" }
        if others.isEmpty == false {
            parts.append("RDPKit doesn't support \(others.joined(separator: ", ")); they are off in this session.")
        }
        parts.append("Set the engine to Automatic or FreeRDP to use \(ignoredSettings.count == 1 ? "it" : "them").")
        return parts.joined(separator: " ")
    }
}

/// Advice for a refused Kerberos-only sign-in. Kerberos asks for a ticket for the server's
/// name (TERMSRV/name), and a domain has none for an IP address, so the attempt is refused
/// even with the right password.
public enum KerberosAdvice {
    public static func signInMessage(_ message: String?, authentication: AuthenticationMode, address: HostAddress) -> String? {
        guard authentication == .kerberosOnly, address.isIPAddress else { return message }
        return "Kerberos can't sign in to an IP address. Use the server's DNS name (for example server.example.com) as the host, or allow NTLM fallback."
    }
}

/// A USB device's vendor and product ID.
public enum USBDeviceID {
    /// "1050:0407" style, lowercase, or nil when it is not two 16-bit hex numbers.
    public static func normalized(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "0x", with: "").split(separator: ":")
        guard parts.count == 2,
              parts.allSatisfy({ $0.count <= 4 && $0.isEmpty == false && UInt16($0, radix: 16) != nil })
        else { return nil }
        return parts.map { String(repeating: "0", count: 4 - $0.count) + $0 }.joined(separator: ":")
    }
}

/// Where in the inheritance chain a setting came from, for the editor's "Inherited from" hints.
public enum SettingSource: Equatable, Sendable {
    case connection
    case folder(UUID)
    case builtIn
}
