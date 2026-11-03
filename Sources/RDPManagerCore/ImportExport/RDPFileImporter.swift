import Foundation

/// Reads Microsoft `.rdp` files (`name:type:value` lines, usually UTF-16 LE with a BOM).
/// Only settings RDP Manager can honour are taken; every other non-default setting is reported,
/// so an import never silently drops something the file asked for.
public enum RDPFileImporter {
    public struct Result: Equatable, Sendable {
        public var connection: Connection
        /// Settings in the file that were not applied, in words.
        public var warnings: [String]
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case unreadable
        case missingAddress

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The file is not a readable .rdp file."
            case .missingAddress: "The file has no “full address”."
            }
        }
    }

    /// Keys RDP Manager reads, or knows to be harmless presentation details.
    private static let handledKeys: Set<String> = [
        "full address", "server port", "username", "domain", "redirectclipboard", "audiomode",
        "desktopwidth", "desktopheight", "dynamic resolution", "smart sizing", "screen mode id",
        "session bpp", "use multimon", "prompt for credentials", "authentication level",
        "enablecredsspsupport", "negotiate security layer", "autoreconnection enabled",
        "alternate full address", "winposstr", "compression", "keyboardhook", "displayconnectionbar",
        "disable wallpaper", "allow font smoothing", "allow desktop composition", "disable full window drag",
        "disable menu anims", "disable themes", "disable cursor setting", "bitmapcachepersistenable",
        "connection type", "networkautodetect", "bandwidthautodetect", "videoplaybackmode",
        "gatewayusagemethod", "gatewayprofileusagemethod", "gatewaycredentialssource", "promptcredentialonce",
        "kdcproxyname", "use redirection server name", "rdgiskdcproxy", "drivestoredirect",
        "remoteapplicationmode", "redirectprinters", "redirectcomports", "redirectsmartcards",
        "redirectposdevices", "redirectdirectx", "audiocapturemode", "devicestoredirect",
        "camerastoredirect", "usbdevicestoredirect", "redirectwebauthn", "selectedmonitors",
        "maximizetocurrentdisplays", "singlemoninwindowedmode", "desktopscalefactor",
        "gatewayhostname", "gatewaybrokeringtype", "pinconnectionbar", "redirectlocation",
        "encode redirected video capture", "redirected video capture encoding quality",
        "audioqualitymode", "gatewayaccesstoken", "enablerdsaadauth", "targetisaadjoined",
        "server name", "loadbalanceinfo",
    ]

    public static func parse(data: Data, fileName: String) throws(ImportError) -> Result {
        guard let text = decode(data) else {
            throw .unreadable
        }
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // name:type:value, where value may itself contain colons.
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            values[parts[0].lowercased().trimmingCharacters(in: .whitespaces)] = String(parts[2])
        }
        guard let address = values["full address"].flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw .missingAddress
        }

        var warnings: [String] = []
        let defaultPort = values["server port"].flatMap(UInt16.init) ?? 3389
        let parsed: HostAddress
        do {
            parsed = try HostAddress.parse(address, defaultPort: defaultPort)
        } catch {
            throw .missingAddress
        }

        var settings = ConnectionSettings()
        if let username = values["username"], username.isEmpty == false {
            let (domain, user) = splitDomain(username, explicitDomain: values["domain"])
            settings.credential = .direct(username: user, domain: domain)
        }
        if let clipboard = values["redirectclipboard"].flatMap(Int.init) {
            settings.clipboardEnabled = clipboard != 0
        }
        if let audio = values["audiomode"].flatMap(Int.init) {
            // 0 plays on this computer; 1 on the remote computer; 2 nowhere.
            settings.audioPlaybackEnabled = audio == 0
        }
        if values["dynamic resolution"].flatMap(Int.init) == 0,
           let width = values["desktopwidth"].flatMap(Int.init),
           let height = values["desktopheight"].flatMap(Int.init),
           width >= 200, height >= 200 {
            settings.display = .fixed(width: width, height: height)
        }
        if let reconnect = values["autoreconnection enabled"].flatMap(Int.init) {
            settings.autoReconnect = reconnect != 0
        }

        if let gateway = values["gatewayhostname"], gateway.isEmpty == false,
           (values["gatewayusagemethod"].flatMap(Int.init) ?? 0) != 0 {
            warnings.append("RD Gateway “\(gateway)” is not supported yet; the connection goes to the host directly.")
        }
        if values["remoteapplicationmode"].flatMap(Int.init) == 1 {
            warnings.append("RemoteApp is not supported; the full desktop opens instead.")
        }
        if let drives = values["drivestoredirect"], drives.isEmpty == false {
            warnings.append("Drive redirection (“\(drives)”) was not imported.")
        }
        for (key, label) in [
            ("redirectprinters", "Printer redirection"),
            ("redirectsmartcards", "Smart card redirection"),
            ("audiocapturemode", "Microphone redirection"),
            ("redirectcomports", "Serial port redirection"),
        ] where values[key].flatMap(Int.init) == 1 {
            warnings.append("\(label) is not supported.")
        }
        if values["use multimon"].flatMap(Int.init) == 1 {
            warnings.append("Multiple monitors were requested; the session uses one window.")
        }
        if values["enablerdsaadauth"].flatMap(Int.init) == 1 {
            warnings.append("Microsoft Entra ID authentication is not supported.")
        }
        let unknown = values.keys.filter { handledKeys.contains($0) == false }.sorted()
        if unknown.isEmpty == false {
            warnings.append("Ignored settings: \(unknown.joined(separator: ", ")).")
        }

        let baseName = (fileName as NSString).deletingPathExtension
        let connection = Connection(
            name: baseName.isEmpty ? parsed.host : baseName,
            host: parsed.host,
            port: parsed.port,
            settings: settings
        )
        return Result(connection: connection, warnings: warnings)
    }

    /// `DOMAIN\user` or `user@domain` stays as the user typed it for UPNs; a down-level name
    /// is split so the domain field shows it.
    static func splitDomain(_ username: String, explicitDomain: String?) -> (domain: String, user: String) {
        if let separator = username.firstIndex(of: "\\") {
            return (String(username[..<separator]), String(username[username.index(after: separator)...]))
        }
        return (explicitDomain ?? "", username)
    }

    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        // UTF-16 LE without a BOM: every other byte of ASCII text is zero.
        if data.count >= 4, data[data.startIndex + 1] == 0, data[data.startIndex + 3] == 0 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
