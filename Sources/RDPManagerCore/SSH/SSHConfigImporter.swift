import Foundation

/// Reads hosts from an OpenSSH client configuration (`~/.ssh/config`). Parsing only: nothing
/// in the file is run. Each concrete `Host` alias becomes a connection with its HostName,
/// User, Port, IdentityFile, CertificateFile, IdentitiesOnly, ProxyJump and keepalive
/// settings. Wildcard patterns and `Match` blocks are skipped (OpenSSH still applies them when
/// it connects). Commands (`ProxyCommand`, `LocalCommand`, `RemoteCommand`, `Match exec`,
/// `KnownHostsCommand`) and settings that would weaken the app's defaults
/// (`StrictHostKeyChecking`, `UserKnownHostsFile`, `ForwardAgent`, `SendEnv`…) are never
/// imported, and the hosts that had them are listed.
public enum SSHConfigImporter {
    public struct Result: Equatable, Sendable {
        public var connections: [Connection]
        /// Human-readable notes: what was skipped and why.
        public var notes: [String]
    }

    /// Directives whose values are commands or would override the app's security defaults.
    static let refused: Set<String> = [
        "proxycommand", "localcommand", "remotecommand", "permitlocalcommand", "knownhostscommand",
        "stricthostkeychecking", "userknownhostsfile", "globalknownhostsfile", "forwardagent",
        "forwardx11", "forwardx11trusted", "sendenv", "setenv", "controlmaster", "controlpath",
        "controlpersist", "gssapidelegatecredentials", "localforward", "remoteforward", "dynamicforward",
        "tunnel", "tunneldevice", "pkcs11provider", "securitykeyprovider", "canonicalizehostname",
        "batchmode", "hostkeyalias", "verifyhostkeydns", "updatehostkeys", "requesttty", "sessiontype",
    ]

    /// - Parameters:
    ///   - text: the configuration file's contents.
    ///   - readInclude: returns the contents of the files an `Include` names (already
    ///     expanded and restricted by the caller), or nil to ignore Include.
    public static func parse(
        _ text: String,
        folderID: UUID? = nil,
        readInclude: ((String) -> [(path: String, text: String)])? = nil
    ) -> Result {
        var blocks: [(patterns: [String], options: [(String, String)])] = []
        var notes: [String] = []
        var includeDepth = 0
        var seenIncludes = Set<String>()

        func walk(_ text: String, source: String) {
            var current: (patterns: [String], options: [(String, String)])?
            var inMatch = false
            for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.isEmpty == false, line.hasPrefix("#") == false else { continue }
                guard let (keyword, value) = split(line) else { continue }
                switch keyword {
                case "host":
                    if let current { blocks.append(current) }
                    current = (tokens(value), [])
                    inMatch = false
                case "match":
                    if let current { blocks.append(current) }
                    current = nil
                    inMatch = true
                    notes.append("A Match block in \(source) was skipped\(value.lowercased().contains("exec") ? " (Match exec is never run)" : "").")
                case "include":
                    guard let readInclude, includeDepth < 8 else {
                        notes.append("Include \(value) was not followed.")
                        continue
                    }
                    for pattern in tokens(value) {
                        for file in readInclude(pattern) where seenIncludes.insert(file.path).inserted {
                            includeDepth += 1
                            walk(file.text, source: (file.path as NSString).lastPathComponent)
                            includeDepth -= 1
                        }
                    }
                default:
                    guard inMatch == false else { continue }
                    if current == nil {
                        // Options before any Host apply to every host; OpenSSH applies them.
                        continue
                    }
                    current?.options.append((keyword, value))
                }
            }
            if let current { blocks.append(current) }
        }
        walk(text, source: "the configuration")

        var connections: [Connection] = []
        var seenAliases = Set<String>()
        for block in blocks {
            let concrete = block.patterns.filter { $0.contains(where: { "*?!".contains($0) }) == false }
            if concrete.count < block.patterns.count, concrete.isEmpty {
                continue // a pattern block: OpenSSH applies it at connect time
            }
            for alias in concrete where seenAliases.insert(alias.lowercased()).inserted {
                var hostName = alias
                var port: UInt16 = 22
                var ssh = SSHConnectionSettings()
                var refusedHere: [String] = []
                var values: [String: String] = [:]
                for (key, value) in block.options where values[key] == nil {
                    values[key] = value // first value wins, as in OpenSSH
                }
                for (key, value) in values {
                    let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    switch key {
                    case "hostname": hostName = unquoted
                    case "user": ssh.username = unquoted
                    case "port": port = UInt16(unquoted) ?? 22
                    case "identityfile": ssh.identityFile = unquoted
                    case "certificatefile": ssh.certificateFile = unquoted
                    case "identitiesonly": ssh.identitiesOnly = yes(unquoted)
                    case "proxyjump": ssh.proxyJump = unquoted
                    case "serveraliveinterval": ssh.serverAliveIntervalSeconds = Int(unquoted)
                    case "serveralivecountmax": ssh.serverAliveCountMax = Int(unquoted)
                    case "connecttimeout": ssh.connectTimeoutSeconds = Int(unquoted)
                    case "compression": ssh.compression = yes(unquoted)
                    default:
                        if refused.contains(key) { refusedHere.append(key) }
                    }
                }
                // Values the app would refuse to pass to ssh are dropped, not imported broken.
                if let jump = ssh.proxyJump, SSHCommandBuilder.isValidProxyJump(jump) == false {
                    ssh.proxyJump = nil
                    refusedHere.append("proxyjump")
                }
                if let user = ssh.username, SSHCommandBuilder.isValidUsername(user) == false {
                    ssh.username = nil
                }
                for path in [ssh.identityFile, ssh.certificateFile].compactMap(\.self) where (try? SSHCommandBuilder.quotedPath(path, field: "")) == nil {
                    if ssh.identityFile == path { ssh.identityFile = nil }
                    if ssh.certificateFile == path { ssh.certificateFile = nil }
                }
                guard HostAddress.isValidHost(hostName), hostName.hasPrefix("-") == false,
                      hostName.contains("%") == false
                else {
                    notes.append("\(alias): HostName “\(hostName)” was not imported.")
                    continue
                }
                if refusedHere.isEmpty == false {
                    notes.append("\(alias): not imported — \(Set(refusedHere).sorted().joined(separator: ", ")).")
                }
                connections.append(Connection(
                    name: alias, protocol: .ssh, host: hostName, port: port, folderID: folderID,
                    sortIndex: connections.count, ssh: ssh
                ))
            }
        }
        return Result(connections: connections, notes: notes)
    }

    /// `Keyword value`, `Keyword=value` or `Keyword = value`, keyword lowercased.
    static func split(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let keyword = line[..<separator].lowercased()
        var rest = line[separator...].drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        let value = rest.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (keyword, value)
    }

    /// Whitespace-separated tokens, honouring double quotes.
    static func tokens(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, quoted == false {
                if current.isEmpty == false { result.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if current.isEmpty == false { result.append(current) }
        return result
    }

    static func yes(_ value: String) -> Bool {
        ["yes", "true", "on"].contains(value.lowercased())
    }

    /// The files an `Include` pattern names, relative to `~/.ssh`, expanded with `glob`, kept
    /// only if they are regular files inside `home`.
    public static func includedFiles(_ pattern: String, home: String) -> [(path: String, text: String)] {
        var expanded = SSHSecretPolicy.expandTilde(pattern, home: home)
        if expanded.hasPrefix("/") == false {
            expanded = home + "/.ssh/" + expanded
        }
        var result: [(String, String)] = []
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(expanded, 0, nil, &matches) == 0 else { return [] }
        let homePrefix = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for index in 0 ..< Int(matches.gl_pathc) {
            guard let pointer = matches.gl_pathv[index] else { continue }
            let url = URL(fileURLWithPath: String(cString: pointer)).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(homePrefix),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? Int ?? 0) < 1_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            result.append((url.path, text))
        }
        return result
    }
}
