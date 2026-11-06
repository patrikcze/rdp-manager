import AppKit
import RDPManagerCore
import SwiftTerm

/// The terminal of one SSH session: SwiftTerm's view with the app's appearance settings, a
/// confirmation before risky pastes, and nothing that lets remote output act on the Mac by
/// itself. It belongs to the session, so it keeps its screen and scrollback across tab
/// switches and detached windows.
final class SSHTerminalView: TerminalView, TerminalOutputReceiver {
    private(set) var preferences: TerminalPreferences
    private var fontSizeOffset: Double = 0

    init(preferences: TerminalPreferences) {
        self.preferences = preferences
        var options = TerminalOptions.default
        options.scrollback = preferences.scrollbackLines
        options.termName = "xterm-256color"
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: nil, options: options)
        apply(preferences)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    nonisolated func receive(_ bytes: ArraySlice<UInt8>) {
        feed(byteArray: bytes)
    }

    var dimensions: (columns: UInt16, rows: UInt16) {
        let size = terminalStateSnapshot().dimensions
        return (UInt16(clamping: max(size.cols, 2)), UInt16(clamping: max(size.rows, 1)))
    }

    // MARK: - Appearance

    func apply(_ preferences: TerminalPreferences) {
        let preferences = preferences.clamped
        let scrollbackChanged = preferences.scrollbackLines != self.preferences.scrollbackLines
        self.preferences = preferences
        applyFont()
        applyColors()
        let shape: CursorStyle = switch (preferences.cursorShape, preferences.cursorBlinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
        setCursorStyle(shape)
        optionAsMetaKey = preferences.optionAsMeta
        bellStyle = switch preferences.bell {
        case .sound: .sound
        case .visual: .visual
        case .off: .none
        }
        if scrollbackChanged {
            changeScrollback(preferences.scrollbackLines)
        }
    }

    private func applyFont() {
        let size = CGFloat(min(max(preferences.fontSize + fontSizeOffset, TerminalPreferences.fontSizeRange.lowerBound), TerminalPreferences.fontSizeRange.upperBound))
        if preferences.fontName.isEmpty == false, let named = NSFont(name: preferences.fontName, size: size) {
            font = named
        } else {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private var isDark: Bool {
        switch preferences.theme {
        case .dark: true
        case .light: false
        case .system: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private func applyColors() {
        if isDark {
            nativeBackgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            nativeForegroundColor = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1)
            caretColor = NSColor.systemGray
        } else {
            nativeBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            nativeForegroundColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
            caretColor = NSColor.darkGray
        }
        selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if preferences.theme == .system { applyColors() }
    }

    // MARK: - Commands

    func changeFontSize(by step: Double) {
        fontSizeOffset = step == 0 ? 0 : fontSizeOffset + step
        applyFont()
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(item)
    }

    /// Asks before pasting text that would run as several commands: several lines, or a
    /// trailing newline, into a program that has not turned on bracketed paste.
    override func paste(_ sender: Any) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let bracketed = terminalStateSnapshot().bracketedPasteMode
        if preferences.confirmMultilinePaste, TerminalPreferences.isRiskyPaste(text, bracketedPasteActive: bracketed) {
            let alert = NSAlert()
            alert.messageText = "Paste \(text.split(whereSeparator: \.isNewline).count) lines?"
            alert.informativeText = "The program in this terminal hasn't asked for bracketed paste, so each line may run as a command as soon as it's pasted."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        super.paste(sender)
    }
}
