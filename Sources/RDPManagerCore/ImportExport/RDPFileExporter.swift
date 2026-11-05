import Foundation

/// Writes one connection as a Microsoft `.rdp` file (UTF-16 LE with a BOM, as Windows writes
/// them), so it opens in Microsoft's clients or another RDP Manager. Uses the connection's
/// effective settings, inherited ones included. Never contains a password.
public enum RDPFileExporter {
    public struct Result: Equatable, Sendable {
        public var data: Data
        /// The file's lines, for tests and previews.
        public var lines: [String]
        /// Settings that could not go into the file, in words.
        public var notes: [String]
    }

    public static func export(_ connection: Connection, settings: ResolvedSettings, profiles: [CredentialProfile]) -> Result {
        var lines: [String] = []
        var notes: [String] = []
        func add(_ key: String, _ value: Int) { lines.append("\(key):i:\(value)") }
        func add(_ key: String, _ value: String) { lines.append("\(key):s:\(singleLine(value))") }

        add("full address", connection.addressLabel)
        if let username = username(for: settings.credential, profiles: profiles) {
            add("username", username)
        }
        add("prompt for credentials", 0)

        switch settings.display {
        case .matchWindow:
            add("screen mode id", 1)
            add("dynamic resolution", 1)
        case let .fixed(width, height):
            add("screen mode id", 1)
            add("dynamic resolution", 0)
            add("desktopwidth", width)
            add("desktopheight", height)
        }
        add("session bpp", 32)
        add("use multimon", 0)

        switch settings.security {
        case .automatic, .nla:
            add("enablecredsspsupport", 1)
            add("authentication level", 2) // warn when the server can't be verified
        case .tls:
            add("enablecredsspsupport", 0)
            add("authentication level", 2)
        case .standardRDP:
            add("enablecredsspsupport", 0)
            add("negotiate security layer", 0)
            add("authentication level", 0)
            notes.append("Standard RDP Security is in the file; other clients may connect without verifying the server.")
        }

        add("redirectclipboard", settings.clipboardEnabled ? 1 : 0)
        add("audiomode", settings.audioPlaybackEnabled ? 0 : 2)
        add("audiocapturemode", settings.microphoneEnabled ? 1 : 0)
        add("redirectprinters", settings.printersEnabled ? 1 : 0)
        add("redirectsmartcards", settings.smartCardsEnabled ? 1 : 0)
        add("autoreconnection enabled", settings.autoReconnect ? 1 : 0)

        if settings.sharedFolderPath != nil {
            notes.append("The shared folder is a path on this Mac, so it isn't in the file.")
        }
        if settings.usbDevices.isEmpty == false {
            notes.append("USB devices aren't in the file; other clients choose them themselves.")
        }
        if settings.authentication != .ntlm || settings.kerberosKDCProxyURL != nil {
            notes.append("Kerberos settings aren't in the file; other clients use their own.")
        }
        if case .shared = settings.credential, username(for: settings.credential, profiles: profiles) == nil {
            notes.append("The connection's credential profile is missing, so no user name is in the file.")
        }

        let text = lines.joined(separator: "\r\n") + "\r\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian) ?? Data())
        return Result(data: data, lines: lines, notes: notes)
    }

    /// A file name for the connection: its name without characters Finder or Windows refuse.
    public static func fileName(for connection: Connection) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = connection.name.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return (cleaned.isEmpty ? connection.host : cleaned) + ".rdp"
    }

    /// `DOMAIN\user`, a UPN as typed, or nil when the connection asks every time.
    static func username(for credential: CredentialAssignment, profiles: [CredentialProfile]) -> String? {
        let pair: (username: String, domain: String)
        switch credential {
        case .prompt:
            return nil
        case let .direct(username, domain):
            pair = (username, domain)
        case let .shared(id):
            guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
            pair = (profile.username, profile.domain)
        }
        let user = pair.username.trimmingCharacters(in: .whitespaces)
        guard user.isEmpty == false else { return nil }
        let domain = pair.domain.trimmingCharacters(in: .whitespaces)
        return domain.isEmpty || user.contains("@") ? user : "\(domain)\\\(user)"
    }

    /// One `.rdp` value can't span lines; a line break would start a new setting.
    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }
}
