import Foundation

/// What a Quick Connect entry asks for. `host` and `host:port` stay RDP, as before SSH;
/// `ssh://[user@]host[:port]`, `ssh [user@]host` or the SSH picker make it an SSH session.
public enum QuickConnectTarget: Equatable, Sendable {
    case rdp(HostAddress)
    case ssh(username: String, address: HostAddress)

    public enum ParseError: Error, Equatable, LocalizedError {
        case address(HostAddress.ParseError)
        case invalidUser(String)

        public var errorDescription: String? {
            switch self {
            case let .address(error): error.errorDescription
            case let .invalidUser(user): "“\(user)” is not a valid user name."
            }
        }
    }

    public static func parse(_ text: String, preferring preferred: ConnectionProtocol = .rdp) throws(ParseError) -> QuickConnectTarget {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var isSSH = preferred == .ssh
        if input.lowercased().hasPrefix("ssh://") {
            input.removeFirst("ssh://".count)
            isSSH = true
        } else if input.lowercased().hasPrefix("ssh ") {
            input = input.dropFirst(4).trimmingCharacters(in: .whitespaces)
            isSSH = true
        }
        guard isSSH else {
            do {
                return .rdp(try HostAddress.parse(input))
            } catch {
                throw .address(error)
            }
        }
        while input.hasSuffix("/") { input.removeLast() }
        var username = ""
        if let at = input.lastIndex(of: "@") {
            username = String(input[..<at]).removingPercentEncoding ?? String(input[..<at])
            input = String(input[input.index(after: at)...])
            guard SSHCommandBuilder.isValidUsername(username) else { throw .invalidUser(username) }
        }
        do {
            let address = try HostAddress.parse(input, defaultPort: ConnectionProtocol.ssh.defaultPort)
            guard address.host.hasPrefix("-") == false else { throw HostAddress.ParseError.invalidHost(address.host) }
            return .ssh(username: username, address: address)
        } catch {
            throw .address(error as? HostAddress.ParseError ?? .invalidHost(input))
        }
    }
}
