import Foundation

/// How terminals look and behave, for every SSH session. Saved in the app's preferences,
/// never with the library, and holds nothing secret.
public struct TerminalPreferences: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable {
        /// Dark or light with the system appearance.
        case system
        case dark
        case light

        public var label: String { rawValue.capitalized }
    }

    public enum CursorShape: String, Codable, CaseIterable, Sendable {
        case block, underline, bar

        public var label: String { rawValue.capitalized }
    }

    public enum Bell: String, Codable, CaseIterable, Sendable {
        case sound, visual, off

        public var label: String {
            switch self {
            case .sound: "Sound"
            case .visual: "Flash"
            case .off: "Off"
            }
        }
    }

    /// A font family name; the system monospaced font (SF Mono) when empty.
    public var fontName: String
    public var fontSize: Double
    public var theme: Theme
    public var cursorShape: CursorShape
    public var cursorBlinks: Bool
    public var scrollbackLines: Int
    public var bell: Bell
    /// Option sends Meta (Esc-prefixed) instead of typing the layout's Option characters.
    /// Off by default, so Czech and other layouts type `@`, `#`, `{`… and dead keys work.
    public var optionAsMeta: Bool
    /// Asks before pasting several lines into a program that hasn't turned on bracketed
    /// paste, where each line would run as a command.
    public var confirmMultilinePaste: Bool
    /// Lets remote programs set the Mac clipboard (OSC 52). Reading it is never allowed.
    public var allowRemoteClipboardWrite: Bool

    public static let scrollbackRange = 1000 ... 100_000
    public static let fontSizeRange = 8.0 ... 32.0

    public init(
        fontName: String = "",
        fontSize: Double = 13,
        theme: Theme = .system,
        cursorShape: CursorShape = .block,
        cursorBlinks: Bool = true,
        scrollbackLines: Int = 10_000,
        bell: Bell = .visual,
        optionAsMeta: Bool = false,
        confirmMultilinePaste: Bool = true,
        allowRemoteClipboardWrite: Bool = false
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.theme = theme
        self.cursorShape = cursorShape
        self.cursorBlinks = cursorBlinks
        self.scrollbackLines = scrollbackLines
        self.bell = bell
        self.optionAsMeta = optionAsMeta
        self.confirmMultilinePaste = confirmMultilinePaste
        self.allowRemoteClipboardWrite = allowRemoteClipboardWrite
    }

    /// Values from an older or hand-edited preference brought into range.
    public var clamped: TerminalPreferences {
        var copy = self
        copy.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        copy.scrollbackLines = min(max(scrollbackLines, Self.scrollbackRange.lowerBound), Self.scrollbackRange.upperBound)
        return copy
    }

    public static let defaultsKey = "terminalPreferences"

    public static func load(from defaults: UserDefaults) -> TerminalPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(TerminalPreferences.self, from: data)
        else { return TerminalPreferences() }
        return preferences.clamped
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(clamped) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Text that would run as several commands if pasted without bracketed paste.
    public static func isRiskyPaste(_ text: String, bracketedPasteActive: Bool) -> Bool {
        guard bracketedPasteActive == false else { return false }
        let trimmed = text.trimmingCharacters(in: .newlines)
        return trimmed.contains(where: \.isNewline) || text.hasSuffix("\n") || text.hasSuffix("\r")
    }
}
