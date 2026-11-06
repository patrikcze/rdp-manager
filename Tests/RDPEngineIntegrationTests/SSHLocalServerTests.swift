import AppKit
import Darwin
import Foundation
import RDPManagerCore
import Testing
@testable import RDPManager

/// A throwaway OpenSSH server on 127.0.0.1 and a random port, running as the current user
/// (non-root sshd lets only that user in). Everything lives in a temporary folder; nothing in
/// ~/.ssh is read or written by the server or by the client under test.
final class TestSSHServer: @unchecked Sendable {
    let directory: URL
    let port: UInt16
    let hostKey: URL
    private let process: Process

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd")
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")
    }

    init(authorizedKeys: [URL]) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "rdpm-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hostKey = directory.appending(path: "host_ed25519")
        try Self.keygen(hostKey, passphrase: "")
        let authorized = try authorizedKeys.map { try String(contentsOf: $0.appendingPathExtension("pub"), encoding: .utf8) }.joined()
        let authorizedFile = directory.appending(path: "authorized_keys")
        try authorized.write(to: authorizedFile, atomically: true, encoding: .utf8)
        port = try Self.freePort()
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        AuthorizedKeysFile \(authorizedFile.path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PidFile \(directory.appending(path: "sshd.pid").path)
        """
        let configFile = directory.appending(path: "sshd_config")
        try config.write(to: configFile, atomically: true, encoding: .utf8)
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", configFile.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Wait until it accepts connections.
        for _ in 0 ..< 100 {
            if Self.canConnect(port: port) { return }
            usleep(50000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    deinit {
        stop()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A fresh ed25519 key pair in the folder.
    func makeKey(_ name: String, passphrase: String = "") throws -> URL {
        let key = directory.appending(path: name)
        try Self.keygen(key, passphrase: passphrase)
        return key
    }

    func hostKeyFingerprint() throws -> String {
        let output = try Self.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", hostKey.path + ".pub"])
        return String(output.split(separator: " ")[1])
    }

    static func keygen(_ path: URL, passphrase: String) throws {
        _ = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", passphrase, "-C", "rdpm-test", "-f", path.path])
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return UInt16(bigEndian: address.sin_port)
    }

    static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}

/// The askpass helper built next to the test bundle.
private func useBuiltAskpassHelper() {
    guard OpenSSHProcessTransport.helperPathOverride == nil else { return }
    let bundle = Bundle(for: TestSSHServer.self)
    let candidate = URL(fileURLWithPath: bundle.bundlePath).deletingLastPathComponent().appending(path: "RDPManagerAskpass")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
        OpenSSHProcessTransport.helperPathOverride = candidate.resolvingSymlinksInPath().path
    }
}

private func privateFolders() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("rdpm-ssh.") }) ?? []
}

private func openDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}

/// End-to-end SSH sessions: the real OpenSSH client, PTY, askpass helper and log parsing,
/// against a local sshd. Password and keyboard-interactive sign-in need PAM (a root sshd)
/// and are not covered here; see docs/SSH-TESTING.md.
@MainActor
@Suite("SSH sessions against a local sshd", .serialized, .enabled(if: TestSSHServer.isAvailable))
final class SSHLocalServerTests {
    private func makeSession(
        server: TestSSHServer,
        key: URL?,
        knownHosts: URL,
        settings: SSHConnectionSettings = SSHConnectionSettings(),
        port: UInt16? = nil,
        store: InMemorySecretStore = InMemorySecretStore(),
        passphraseAccount: SecretAccount? = nil
    ) throws -> SSHSession {
        useBuiltAskpassHelper()
        var settings = settings
        settings.identityFile = key?.path ?? settings.identityFile
        settings.connectTimeoutSeconds = settings.connectTimeoutSeconds ?? 5
        let config = server.directory.appending(path: "client_config")
        if FileManager.default.fileExists(atPath: config.path) == false {
            try "".write(to: config, atomically: true, encoding: .utf8)
        }
        var target = SSHTarget(host: "127.0.0.1", port: port ?? server.port, username: NSUserName(), settings: ResolvedSSHSettings(settings))
        target.configFile = config.path
        target.userKnownHostsFile = knownHosts.path
        let session = SSHSession(
            connectionID: nil, title: "test", target: target,
            passwordAccount: nil, passphraseAccount: passphraseAccount,
            credentials: CredentialService(store: store),
            preferences: TerminalPreferences()
        )
        // Everything delivered to the terminal is also recorded, so tests read what the
        // server sent rather than SwiftTerm's screen of a window that is never shown.
        let tee = OutputRecorder(view: session.terminal)
        session.output.receiver = tee
        recorders[ObjectIdentifier(session)] = tee
        // The terminal sizes itself from its window, as in the app.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.terminal
        windows.append(window)
        return session
    }

    private var windows: [NSWindow] = []
    private var recorders: [ObjectIdentifier: OutputRecorder] = [:]

    private func wait(for session: SSHSession, seconds: Double = 15, until done: (SSHSessionPhase) -> Bool) async -> SSHSessionPhase {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, done(session.phase) == false {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return session.phase
    }

    private func screenText(_ session: SSHSession) -> String {
        recorders[ObjectIdentifier(session)]?.text ?? ""
    }

    private func waitForText(_ text: String, in session: SSHSession, seconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if screenText(session).contains(text) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func unknownHostKeyIsAskedThenTrustedAndRemembered() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let key = try server.makeKey("user")
        try (String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8))
            .write(to: server.directory.appending(path: "authorized_keys"), atomically: true, encoding: .utf8)
        let knownHosts = server.directory.appending(path: "known_hosts")
        var settings = SSHConnectionSettings()
        settings.startupCommand = "printf 'ready-%s\\n' $((6*7)); exec sleep 30"
        let session = try makeSession(server: server, key: key, knownHosts: knownHosts, settings: settings)

        session.connect()
        let asked = await wait(for: session) { if case .awaitingHostKeyDecision = $0 { true } else { $0.isEnded } }
        guard case let .awaitingHostKeyDecision(prompt) = asked else {
            Issue.record("Expected a host key prompt, got \(asked)")
            return
        }
        let expected = try server.hostKeyFingerprint()
        #expect(prompt.fingerprint == expected, "prompt: \(prompt.text)")
        #expect(prompt.host.contains("\(server.port)"))
        session.trustHostKey()

        let connected = await wait(for: session) { $0 == .connected || $0.isEnded }
        #expect(connected == .connected)
        #expect(session.authenticationMethod == "publickey")
        #expect(session.cipher?.isEmpty == false)
        #expect(await waitForText("ready-42", in: session))
        // OpenSSH recorded the key, with the custom port.
        let recorded = try String(contentsOf: knownHosts, encoding: .utf8)
        #expect(recorded.contains("[127.0.0.1]:\(server.port)"))

        session.disconnect()
        let ended = await wait(for: session) { $0.isEnded }
        guard case let .ended(end) = ended else { Issue.record("not ended"); return }
        #expect(end.kind == .userDisconnected)

        // Second connection: the key is known, no prompt.
        let again = try makeSession(server: server, key: key, knownHosts: knownHosts, settings: settings)
        again.connect()
        let phase = await wait(for: again) { $0 == .connected || $0.isEnded || { if case .awaitingHostKeyDecision = $0 { true } else { false } }($0) }
        #expect(phase == .connected)
        #expect(again.hostKeyVerified)
        again.close()
        await again.waitUntilEnded(timeout: 5)
    }

    @Test func changedHostKeyIsRefusedBeforeSigningIn() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let key = try server.makeKey("user")
        let impostor = try server.makeKey("impostor_host")
        let knownHosts = server.directory.appending(path: "known_hosts")
        let otherKey = try String(contentsOf: impostor.appendingPathExtension("pub"), encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:\(server.port) \(otherKey)\n".write(to: knownHosts, atomically: true, encoding: .utf8)
        let session = try makeSession(server: server, key: key, knownHosts: knownHosts)

        session.connect()
        let phase = await wait(for: session) { $0.isEnded || { if case .awaitingHostKeyDecision = $0 { true } else { false } }($0) }
        guard case let .ended(end) = phase else {
            Issue.record("A changed key must never be offered for trust: \(phase)")
            return
        }
        #expect(end.category == .certificate)
        #expect(end.title.contains("Changed"))
        #expect(session.authenticationMethod == nil)
    }

    @Test func wrongKeyFailsAuthenticationWithoutRetrying() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let stranger = try server.makeKey("stranger")
        let knownHosts = server.directory.appending(path: "known_hosts")
        try "[127.0.0.1]:\(server.port) \(String(contentsOf: server.hostKey.appendingPathExtension("pub"), encoding: .utf8))"
            .write(to: knownHosts, atomically: true, encoding: .utf8)
        var settings = SSHConnectionSettings()
        settings.authentication = .publicKey
        settings.autoReconnect = true
        let session = try makeSession(server: server, key: stranger, knownHosts: knownHosts, settings: settings)

        session.connect()
        let phase = await wait(for: session) { $0.isEnded }
        guard case let .ended(end) = phase else { Issue.record("not ended: \(phase)"); return }
        #expect(end.category == .authentication)
        #expect(session.reconnectCount == 0)
    }

    @Test func encryptedKeyPassphraseComesFromTheStoreThroughAskpass() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let passphrase = "correct horse \(UUID().uuidString.prefix(6))"
        let key = try server.makeKey("locked", passphrase: passphrase)
        try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .write(to: server.directory.appending(path: "authorized_keys"), atomically: true, encoding: .utf8)
        let knownHosts = server.directory.appending(path: "known_hosts")
        try "[127.0.0.1]:\(server.port) \(String(contentsOf: server.hostKey.appendingPathExtension("pub"), encoding: .utf8))"
            .write(to: knownHosts, atomically: true, encoding: .utf8)
        let store = InMemorySecretStore()
        let account = SecretAccount.sshKeyPassphrase(UUID())
        try store.setPassword(passphrase, for: account)
        var settings = SSHConnectionSettings()
        settings.startupCommand = "exec sleep 30"
        let session = try makeSession(server: server, key: key, knownHosts: knownHosts, settings: settings, store: store, passphraseAccount: account)

        session.connect()
        let phase = await wait(for: session) { $0 == .connected || $0.isEnded || { if case .awaitingInput = $0 { true } else { false } }($0) }
        #expect(phase == .connected, "phase: \(phase)")
        #expect(session.authenticationMethod == "publickey")
        session.close()
        await session.waitUntilEnded(timeout: 5)
    }

    @Test func wrongSavedPassphraseAsksTheUserInstead() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let key = try server.makeKey("locked", passphrase: "the-right-one")
        try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .write(to: server.directory.appending(path: "authorized_keys"), atomically: true, encoding: .utf8)
        let knownHosts = server.directory.appending(path: "known_hosts")
        try "[127.0.0.1]:\(server.port) \(String(contentsOf: server.hostKey.appendingPathExtension("pub"), encoding: .utf8))"
            .write(to: knownHosts, atomically: true, encoding: .utf8)
        let store = InMemorySecretStore()
        let account = SecretAccount.sshKeyPassphrase(UUID())
        try store.setPassword("a-wrong-one", for: account)
        let session = try makeSession(server: server, key: key, knownHosts: knownHosts, store: store, passphraseAccount: account)

        session.connect()
        let phase = await wait(for: session) { if case .awaitingInput = $0 { true } else { $0.isEnded } }
        guard case let .awaitingInput(request) = phase else { Issue.record("expected a prompt: \(phase)"); return }
        guard case .passphrase = request.kind else { Issue.record("expected a passphrase prompt"); return }
        #expect(request.message == "The saved passphrase was not accepted.")
        session.cancelInput()
        let ended = await wait(for: session) { $0.isEnded }
        guard case let .ended(end) = ended else { Issue.record("not ended"); return }
        #expect(end.kind == .userDisconnected)
    }

    @Test func agentKeysAuthenticate() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let key = try server.makeKey("agent_key")
        try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .write(to: server.directory.appending(path: "authorized_keys"), atomically: true, encoding: .utf8)
        let knownHosts = server.directory.appending(path: "known_hosts")
        try "[127.0.0.1]:\(server.port) \(String(contentsOf: server.hostKey.appendingPathExtension("pub"), encoding: .utf8))"
            .write(to: knownHosts, atomically: true, encoding: .utf8)
        let socket = server.directory.appending(path: "agent.sock").path
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { agent.terminate() }
        for _ in 0 ..< 50 where FileManager.default.fileExists(atPath: socket) == false { usleep(50000) }
        try TestSSHServer.run("/usr/bin/ssh-add", [key.path], environment: ["SSH_AUTH_SOCK": socket])

        var settings = SSHConnectionSettings()
        settings.authentication = .agent
        settings.identityAgent = socket
        settings.startupCommand = "exec sleep 30"
        let session = try makeSession(server: server, key: nil, knownHosts: knownHosts, settings: settings)
        session.connect()
        let phase = await wait(for: session) { $0 == .connected || $0.isEnded }
        #expect(phase == .connected, "phase: \(phase)")
        #expect(session.authenticationMethod == "publickey")
        session.close()
        await session.waitUntilEnded(timeout: 5)
    }

    @Test func resizeReachesTheRemoteTerminalWithoutReconnecting() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let key = try server.makeKey("user")
        try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .write(to: server.directory.appending(path: "authorized_keys"), atomically: true, encoding: .utf8)
        let knownHosts = server.directory.appending(path: "known_hosts")
        try "[127.0.0.1]:\(server.port) \(String(contentsOf: server.hostKey.appendingPathExtension("pub"), encoding: .utf8))"
            .write(to: knownHosts, atomically: true, encoding: .utf8)
        var settings = SSHConnectionSettings()
        // Prints the remote terminal's size every half second.
        settings.startupCommand = "while :; do echo \"size=$(stty size)\"; sleep 0.5; done"
        let session = try makeSession(server: server, key: key, knownHosts: knownHosts, settings: settings)
        session.connect()
        #expect(await wait(for: session) { $0 == .connected || $0.isEnded } == .connected)
        let initial = session.terminal.dimensions
        #expect(await waitForText("size=\(initial.rows) \(initial.columns)", in: session), "screen: \(screenText(session))")

        // What SwiftTerm reports when its view changes size (coalesced to display frames, so
        // it is called directly here: the test window is never on screen).
        session.sizeChanged(source: session.terminal, newCols: Int(initial.columns) + 21, newRows: Int(initial.rows) + 5)
        let expected = "size=\(initial.rows + 5) \(initial.columns + 21)"
        #expect(await waitForText(expected, in: session), "last line: \(screenText(session).split(whereSeparator: \.isNewline).last ?? "")")
        #expect(session.phase == .connected)
        #expect(session.reconnectCount == 0)
        session.close()
        await session.waitUntilEnded(timeout: 5)
    }

    @Test func proxyJumpConnectsWithoutDebugOutputInTheTerminal() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let key = try server.makeKey("user")
        try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .write(to: server.directory.appending(path: "authorized_keys"), atomically: true, encoding: .utf8)
        let knownHosts = server.directory.appending(path: "known_hosts")
        let hostKey = try String(contentsOf: server.hostKey.appendingPathExtension("pub"), encoding: .utf8)
        try "[127.0.0.1]:\(server.port) \(hostKey)[localhost]:\(server.port) \(hostKey)".write(to: knownHosts, atomically: true, encoding: .utf8)
        // The jump's own ssh reads only the config file, so it carries the test's key and
        // known_hosts too: nothing in ~/.ssh is used.
        try "Host *\n  IdentityFile \(key.path)\n  IdentitiesOnly yes\n  UserKnownHostsFile \(knownHosts.path)\n"
            .write(to: server.directory.appending(path: "client_config"), atomically: true, encoding: .utf8)
        var settings = SSHConnectionSettings()
        settings.proxyJump = "localhost:\(server.port)"
        settings.startupCommand = "echo through-the-jump; exec sleep 30"
        let session = try makeSession(server: server, key: key, knownHosts: knownHosts, settings: settings)
        session.connect()
        #expect(await wait(for: session) { $0 == .connected || $0.isEnded } == .connected)
        #expect(await waitForText("through-the-jump", in: session))
        #expect(screenText(session).contains("debug1") == false, "terminal: \(screenText(session))")
        #expect(session.authenticationMethod == "publickey")
        session.close()
        await session.waitUntilEnded(timeout: 5)
    }

    @Test func remoteExitEndsTheSessionWithoutReconnect() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let key = try server.makeKey("user")
        try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .write(to: server.directory.appending(path: "authorized_keys"), atomically: true, encoding: .utf8)
        let knownHosts = server.directory.appending(path: "known_hosts")
        try "[127.0.0.1]:\(server.port) \(String(contentsOf: server.hostKey.appendingPathExtension("pub"), encoding: .utf8))"
            .write(to: knownHosts, atomically: true, encoding: .utf8)
        var settings = SSHConnectionSettings()
        settings.startupCommand = "echo bye; exit 3"
        settings.autoReconnect = true
        let session = try makeSession(server: server, key: key, knownHosts: knownHosts, settings: settings)
        session.connect()
        let phase = await wait(for: session) { $0.isEnded }
        guard case let .ended(end) = phase else { Issue.record("not ended: \(phase)"); return }
        #expect(end.kind == .remoteEnded)
        #expect(end.message.contains("3"))
        #expect(session.reconnectCount == 0)
        #expect(await waitForText("bye", in: session))
    }

    @Test func silentServerTimesOut() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        // A port that accepts TCP and never speaks SSH.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let port = try TestSSHServer.freePort()
        address.sin_port = port.bigEndian
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 1)
        var settings = SSHConnectionSettings()
        settings.connectTimeoutSeconds = 3
        let session = try makeSession(server: server, key: nil, knownHosts: server.directory.appending(path: "known_hosts"), settings: settings, port: port)
        session.connect()
        let phase = await wait(for: session, seconds: 20) { $0.isEnded }
        guard case let .ended(end) = phase else { Issue.record("not ended: \(phase)"); return }
        #expect(end.category == .network || end.category == .server)
    }

    @Test func cancellingAtTheHostKeyPromptEndsCleanlyWithoutLeaks() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let before = openDescriptorCount()
        let foldersBefore = Set(privateFolders())
        let session = try makeSession(server: server, key: nil, knownHosts: server.directory.appending(path: "known_hosts"))
        session.connect()
        let asked = await wait(for: session) { if case .awaitingHostKeyDecision = $0 { true } else { $0.isEnded } }
        guard case .awaitingHostKeyDecision = asked else { Issue.record("expected a prompt: \(asked)"); return }
        session.disconnect()
        let phase = await wait(for: session) { $0.isEnded }
        guard case let .ended(end) = phase else { Issue.record("not ended"); return }
        #expect(end.kind == .userDisconnected)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(openDescriptorCount() <= before, "descriptors before \(before), after \(openDescriptorCount())")
        let leftovers = Set(privateFolders()).subtracting(foldersBefore)
        #expect(leftovers.isEmpty, "private folders left: \(leftovers)")
    }

    @Test func rejectingTheHostKeySendsNothing() async throws {
        let server = try TestSSHServer(authorizedKeys: [])
        defer { server.stop() }
        let knownHosts = server.directory.appending(path: "known_hosts")
        let session = try makeSession(server: server, key: nil, knownHosts: knownHosts)
        session.connect()
        let asked = await wait(for: session) { if case .awaitingHostKeyDecision = $0 { true } else { $0.isEnded } }
        guard case .awaitingHostKeyDecision = asked else { Issue.record("expected a prompt: \(asked)"); return }
        session.rejectHostKey()
        let phase = await wait(for: session) { $0.isEnded }
        guard case let .ended(end) = phase else { Issue.record("not ended"); return }
        #expect(end.category == .certificate)
        #expect(session.authenticationMethod == nil)
        #expect(((try? String(contentsOf: knownHosts, encoding: .utf8)) ?? "").isEmpty)
    }
}


/// Records the bytes a session delivers to its terminal, and passes them on.
final class OutputRecorder: TerminalOutputReceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [UInt8] = []
    nonisolated(unsafe) weak var view: SSHTerminalView?

    init(view: SSHTerminalView) {
        self.view = view
    }

    nonisolated func receive(_ bytes: ArraySlice<UInt8>) {
        lock.withLock { data += bytes }
        view?.receive(bytes)
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
