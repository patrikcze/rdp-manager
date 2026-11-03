import Foundation

/// A host and port the user typed, as in Quick Connect: `server01.example.com`,
/// `server01.example.com:3390`, `10.10.20.30`, `fe80::1` or `[fe80::1]:3390`.
public struct HostAddress: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = 3389) {
        self.host = host
        self.port = port
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case invalidPort(String)
        case invalidHost(String)

        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a host name or address."
            case let .invalidPort(port): "“\(port)” is not a valid port. Use a number from 1 to 65535."
            case let .invalidHost(host): "“\(host)” is not a valid host name or address."
            }
        }
    }

    public static func parse(_ text: String, defaultPort: UInt16 = 3389) throws(ParseError) -> HostAddress {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept pasted rdp:// or "full address" style prefixes.
        for prefix in ["rdp://", "ms-rd://"] where input.lowercased().hasPrefix(prefix) {
            input.removeFirst(prefix.count)
        }
        while input.hasSuffix("/") {
            input.removeLast()
        }
        guard input.isEmpty == false else {
            throw .empty
        }

        let host: String
        var portText: String?
        if input.hasPrefix("[") {
            // [IPv6]:port
            guard let close = input.firstIndex(of: "]") else {
                throw .invalidHost(input)
            }
            host = String(input[input.index(after: input.startIndex) ..< close])
            let rest = input[input.index(after: close)...]
            if rest.isEmpty == false {
                guard rest.hasPrefix(":") else {
                    throw .invalidHost(input)
                }
                portText = String(rest.dropFirst())
            }
        } else if input.filter({ $0 == ":" }).count == 1 {
            let parts = input.split(separator: ":", omittingEmptySubsequences: false)
            host = String(parts[0])
            portText = String(parts[1])
        } else {
            // No colon, or a bare IPv6 address with several.
            host = input
        }

        guard isValidHost(host) else {
            throw .invalidHost(host)
        }
        var port = defaultPort
        if let portText {
            guard let value = UInt16(portText), value > 0 else {
                throw .invalidPort(portText)
            }
            port = value
        }
        return HostAddress(host: host, port: port)
    }

    /// Host names, IPv4 and IPv6 literals. Deliberately permissive about labels (underscores
    /// occur in real Windows names) but rejects whitespace, paths and credentials in URLs.
    static func isValidHost(_ host: String) -> Bool {
        guard host.isEmpty == false, host.count <= 253 else {
            return false
        }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "/\\@?#[]<>\"'`|{}^%,;"))
        if host.unicodeScalars.contains(where: forbidden.contains) {
            return false
        }
        if host.contains(":") {
            // IPv6: hex digits, colons, dots (embedded IPv4) and a zone index.
            let ipv6 = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
            let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
            return address.unicodeScalars.allSatisfy(ipv6.contains)
        }
        return host.hasPrefix(".") == false && host.hasPrefix("-") == false
    }
}
