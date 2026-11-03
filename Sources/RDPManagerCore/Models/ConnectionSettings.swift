import Foundation

/// Settings a folder sets as defaults and a connection may override. Every field is optional:
/// nil means "inherit from the parent folder", and at the root, the built-in default.
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

    public init(
        credential: CredentialAssignment? = nil,
        display: DisplayMode? = nil,
        clipboardEnabled: Bool? = nil,
        audioPlaybackEnabled: Bool? = nil,
        timeoutSeconds: Int? = nil,
        autoReconnect: Bool? = nil,
        sendsCommandShortcutsToRemote: Bool? = nil
    ) {
        self.credential = credential
        self.display = display
        self.clipboardEnabled = clipboardEnabled
        self.audioPlaybackEnabled = audioPlaybackEnabled
        self.timeoutSeconds = timeoutSeconds
        self.autoReconnect = autoReconnect
        self.sendsCommandShortcutsToRemote = sendsCommandShortcutsToRemote
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
            sendsCommandShortcutsToRemote: sendsCommandShortcutsToRemote ?? parent.sendsCommandShortcutsToRemote
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
        }
    }
}

public enum SettingKey: CaseIterable, Sendable {
    case credential, display, clipboard, audio, timeout, autoReconnect, commandShortcuts
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

    /// The built-in defaults at the top of every inheritance chain. Clipboard sharing is on
    /// as in Microsoft's client; any folder or connection can turn it off.
    public static let builtIn = ResolvedSettings(
        credential: .prompt,
        display: .matchWindow,
        clipboardEnabled: true,
        audioPlaybackEnabled: false,
        timeoutSeconds: 20,
        autoReconnect: true,
        sendsCommandShortcutsToRemote: true
    )

    public init(
        credential: CredentialAssignment,
        display: DisplayMode,
        clipboardEnabled: Bool,
        audioPlaybackEnabled: Bool,
        timeoutSeconds: Int,
        autoReconnect: Bool,
        sendsCommandShortcutsToRemote: Bool
    ) {
        self.credential = credential
        self.display = display
        self.clipboardEnabled = clipboardEnabled
        self.audioPlaybackEnabled = audioPlaybackEnabled
        self.timeoutSeconds = timeoutSeconds
        self.autoReconnect = autoReconnect
        self.sendsCommandShortcutsToRemote = sendsCommandShortcutsToRemote
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
                ?? defaults.sendsCommandShortcutsToRemote
        )
    }
}

/// Where in the inheritance chain a setting came from, for the editor's "Inherited from" hints.
public enum SettingSource: Equatable, Sendable {
    case connection
    case folder(UUID)
    case builtIn
}
