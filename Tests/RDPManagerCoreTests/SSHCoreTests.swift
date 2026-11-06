import Foundation
import Testing
@testable import RDPManagerCore

@MainActor
@Suite("SSH: library migration, inheritance and Keychain references")
struct SSHInventoryTests {
    /// A library as RDP Manager 0.3.1 saved it (schema 1).
    static let version1Library = """
    {
      "connections" : [
        {
          "color" : "red",
          "createdAt" : "2026-10-01T10:00:00.000Z",
          "folderID" : "11111111-1111-1111-1111-111111111111",
          "host" : "dc01.example.com",
          "id" : "22222222-2222-2222-2222-222222222222",
          "isFavorite" : true,
          "lastConnectedAt" : "2026-11-01T08:30:00.000Z",
          "name" : "DC01",
          "notes" : "primary",
          "operatingSystemLabel" : "Windows Server 2025",
          "port" : 3390,
          "settings" : {
            "credential" : { "direct" : { "domain" : "EMEA", "username" : "admin" } },
            "printersEnabled" : true
          },
          "sortIndex" : 0,
          "tags" : [ "dc" ]
        }
      ],
      "credentials" : [
        { "domain" : "EMEA", "id" : "33333333-3333-3333-3333-333333333333", "name" : "EMEA Admin", "notes" : "", "username" : "admin" }
      ],
      "expandedFolderIDs" : [ "11111111-1111-1111-1111-111111111111" ],
      "folders" : [
        {
          "defaults" : { "credential" : { "shared" : { "_0" : "33333333-3333-3333-3333-333333333333" } } },
          "id" : "11111111-1111-1111-1111-111111111111",
          "name" : "EMEA",
          "notes" : "",
          "sortIndex" : 0
        }
      ],
      "schemaVersion" : 1
    }
    """

    @Test func version1LibraryLoadsAsRDPWithEverythingKept() throws {
        let inventory = try InventoryMigrator.decode(Data(Self.version1Library.utf8))
        #expect(inventory.schemaVersion == 2)
        let connection = try #require(inventory.connections.first)
        #expect(connection.connectionProtocol == .rdp)
        #expect(connection.id == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(connection.port == 3390)
        #expect(connection.isFavorite)
        #expect(connection.color == .red)
        #expect(connection.tags == ["dc"])
        #expect(connection.lastConnectedAt != nil)
        #expect(connection.settings.credential == .direct(username: "admin", domain: "EMEA"))
        #expect(connection.settings.printersEnabled == true)
        #expect(connection.ssh.isEmpty)
        let folder = try #require(inventory.folders.first)
        #expect(folder.defaults.credential == .shared(UUID(uuidString: "33333333-3333-3333-3333-333333333333")!))
        #expect(folder.sshDefaults.isEmpty)
        #expect(inventory.credentials.first?.kind == .rdpPassword)
        #expect(inventory.expandedFolderIDs == [folder.id])

        // Saved again, it is schema 2 and reads back the same.
        let saved = try InventoryMigrator.encoder.encode(inventory)
        #expect(try InventoryMigrator.decode(saved) == inventory)
        #expect(String(decoding: saved, as: UTF8.self).contains("\"schemaVersion\" : 2"))
    }

    @Test func newerSchemaIsStillRefused() {
        let newer = Self.version1Library.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 3")
        #expect(throws: InventoryMigrationError.self) { try InventoryMigrator.decode(Data(newer.utf8)) }
    }

    @Test func defaultPortsAndAddressLabels() {
        let ssh = Connection(name: "rocky10", protocol: .ssh, host: "rocky10.example.com")
        #expect(ssh.port == 22)
        #expect(ssh.addressLabel == "rocky10.example.com")
        let custom = Connection(name: "jump", protocol: .ssh, host: "fe80::1", port: 2222)
        #expect(custom.addressLabel == "[fe80::1]:2222")
        #expect(Connection(name: "dc", host: "dc").port == 3389)
    }

    @Test func switchingProtocolKeepsADeliberatePort() {
        #expect(ConnectionProtocol.rdp.port(3389, whenSwitchingTo: .ssh) == 22)
        #expect(ConnectionProtocol.ssh.port(22, whenSwitchingTo: .rdp) == 3389)
        #expect(ConnectionProtocol.rdp.port(3390, whenSwitchingTo: .ssh) == 3390)
        #expect(ConnectionProtocol.ssh.port(2222, whenSwitchingTo: .rdp) == 2222)
    }

    @Test func mixedFolderInheritanceIsProtocolAware() {
        let store = InventoryStore(persistence: InMemoryInventoryPersistence(), saveDelay: .zero)
        let rdpProfile = store.addCredential(CredentialProfile(name: "Windows admin", username: "admin", domain: "EMEA"))
        let group = store.addFolder(named: "Mixed", in: nil)
        var folder = group
        folder.defaults.credential = .shared(rdpProfile.id)
        folder.sshDefaults.username = "ops"
        folder.sshDefaults.proxyJump = "bastion.example.com"
        store.update(folder)
        let rdp = store.addConnection(Connection(name: "DC01", host: "dc01", folderID: group.id))
        let ssh = store.addConnection(Connection(name: "rocky10", protocol: .ssh, host: "rocky10", folderID: group.id))

        #expect(store.resolvedSettings(for: rdp).credential == .shared(rdpProfile.id))
        // The RDP credential never reaches the SSH host.
        let resolved = store.resolvedSSHSettings(for: ssh)
        #expect(resolved.secret == SSHSecretSource.none)
        #expect(resolved.username == "ops")
        #expect(resolved.proxyJump == "bastion.example.com")
        #expect(store.source(of: .username, for: ssh) == .folder(group.id))
        #expect(store.source(of: .forwardAgent, for: ssh) == .builtIn)
        #expect(resolved.forwardAgent == false)
        #expect(resolved.gssapiDelegateCredentials == false)
        #expect(store.sshUsername(for: ssh) == "ops")
        #expect(store.connections(in: group.id).map(\.connectionProtocol) == [.rdp, .ssh])
    }

    @Test func sshKeyProfileSuppliesTheUserWhenNoneIsSet() {
        let store = InventoryStore(persistence: InMemoryInventoryPersistence(), saveDelay: .zero)
        let key = store.addCredential(CredentialProfile(name: "Deploy key", kind: .sshKey, username: "deploy", keyPath: "~/.ssh/id_ed25519"))
        var connection = Connection(name: "web", protocol: .ssh, host: "web")
        connection.ssh.secret = .profile(key.id)
        connection = store.addConnection(connection)
        #expect(store.sshUsername(for: connection) == "deploy")
        #expect(store.usages(ofCredential: key.id).connections.map(\.id) == [connection.id])
        store.deleteCredential(key.id)
        #expect(store.connection(connection.id)?.ssh.secret == nil)
    }

    @Test func unusedPasswordCleanupKeepsSSHSecrets() {
        let store = InventoryStore(persistence: InMemoryInventoryPersistence(), saveDelay: .zero)
        let key = store.addCredential(CredentialProfile(name: "key", kind: .sshKey, username: "u", keyPath: "~/.ssh/id"))
        let password = store.addCredential(CredentialProfile(name: "pw", kind: .sshPassword, username: "u"))
        let ssh = store.addConnection(Connection(name: "h", protocol: .ssh, host: "h"))
        let rdp = store.addConnection(Connection(name: "w", host: "w"))
        let gone = UUID()
        let accounts: [SecretAccount] = [
            .sshKeyPassphrase(key.id), .credential(password.id), .sshPassword(ssh.id), .connection(rdp.id),
            .sshKeyPassphrase(gone), .sshPassword(gone), .credential(gone), .connection(gone),
        ]
        #expect(Set(store.orphanedSecretAccounts(in: accounts)) == [.sshKeyPassphrase(gone), .sshPassword(gone), .credential(gone), .connection(gone)])
    }

    @Test func secretAccountNamesStayStable() {
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        #expect(SecretAccount.credential(id).rawValue == "credential:44444444-4444-4444-4444-444444444444")
        #expect(SecretAccount.connection(id).rawValue == "connection:44444444-4444-4444-4444-444444444444")
        #expect(SecretAccount.sshPassword(id).rawValue == "ssh-password:44444444-4444-4444-4444-444444444444")
        #expect(SecretAccount.sshKeyPassphrase(id).rawValue == "ssh-key-passphrase:44444444-4444-4444-4444-444444444444")
        for account in [SecretAccount.credential(id), .connection(id), .sshPassword(id), .sshKeyPassphrase(id)] {
            #expect(SecretAccount(rawValue: account.rawValue) == account)
        }
    }

    @Test func libraryExportCarriesBothProtocolsWithoutSecrets() throws {
        let key = CredentialProfile(name: "key", kind: .sshKey, username: "deploy", keyPath: "~/.ssh/id_ed25519", keyFingerprint: "SHA256:abc")
        var ssh = Connection(name: "rocky10", protocol: .ssh, host: "rocky10", port: 2222)
        ssh.ssh = SSHConnectionSettings(username: "root", secret: .profile(key.id), proxyJump: "bastion",
                                        forwardAgent: true, gssapiDelegateCredentials: true,
                                        sendEnvironment: ["AWS_PROFILE"], startupDirectory: "/srv", startupCommand: "tmux attach")
        var folder = Folder(name: "Linux")
        folder.sshDefaults.startupCommand = "rm -rf ~"
        ssh.folderID = folder.id
        let rdp = Connection(name: "DC01", host: "dc01", folderID: folder.id)
        let inventory = Inventory(folders: [folder], connections: [ssh, rdp], credentials: [key])
        let store = InMemorySecretStore()
        try store.setPassword("hunter2-secret", for: .sshKeyPassphrase(key.id))

        let data = try LibraryArchive(inventory: inventory).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("hunter2-secret") == false)
        #expect(text.contains("\"formatVersion\" : 2"))
        let archive = try LibraryArchive.decode(data)
        #expect(archive.connections.map(\.connectionProtocol) == [.ssh, .rdp])

        let imported = archive.inventoryForImport(under: nil)
        let importedSSH = try #require(imported.inventory.connections.first { $0.isSSH })
        #expect(importedSSH.port == 2222)
        #expect(importedSSH.ssh.username == "root")
        #expect(importedSSH.ssh.proxyJump == "bastion")
        #expect(importedSSH.ssh.startupCommand == nil)
        #expect(importedSSH.ssh.startupDirectory == nil)
        #expect(importedSSH.ssh.forwardAgent == nil)
        #expect(importedSSH.ssh.gssapiDelegateCredentials == nil)
        #expect(importedSSH.ssh.sendEnvironment == nil)
        // The key profile reference follows the profile's new identifier.
        let newKey = try #require(imported.inventory.credentials.first)
        #expect(importedSSH.ssh.secret == .profile(newKey.id))
        #expect(imported.inventory.folders.first?.sshDefaults.startupCommand == nil)
        #expect(imported.removedSettings.contains { $0.contains("startup command") })
        #expect(imported.removedSettings.contains { $0.contains("agent forwarding") })
    }

    @Test func formatOneArchivesStillImportAsRDP() throws {
        let archive = """
        { "format": "com.rdpmanager.library", "formatVersion": 1, "exportedAt": "2026-10-01T10:00:00.000Z",
          "folders": [], "credentials": [],
          "connections": [ { "id": "22222222-2222-2222-2222-222222222222", "name": "DC01", "host": "dc01", "port": 3389,
            "sortIndex": 0, "tags": [], "isFavorite": false, "notes": "", "operatingSystemLabel": "",
            "settings": {}, "createdAt": "2026-10-01T10:00:00.000Z" } ] }
        """
        let decoded = try LibraryArchive.decode(Data(archive.utf8))
        #expect(decoded.connections.first?.connectionProtocol == .rdp)
    }
}

@Suite("SSH: ssh arguments and environment")
struct SSHCommandTests {
    @Test func forcedSafetyOptions() throws {
        let target = SSHTarget(host: "rocky10.example.com", port: 2222, username: "root")
        let arguments = try SSHCommandBuilder.arguments(for: target, logPath: "/tmp/x/log")
        let joined = arguments.joined(separator: " ")
        #expect(joined.contains("StrictHostKeyChecking=ask"))
        #expect(joined.contains("StrictHostKeyChecking=no") == false)
        #expect(joined.contains("/dev/null") == false)
        #expect(joined.contains("ForwardAgent=no"))
        #expect(joined.contains("GSSAPIDelegateCredentials=no"))
        #expect(joined.contains("PermitLocalCommand=no"))
        #expect(joined.contains("ControlPath=none"))
        #expect(Array(arguments.suffix(2)) == ["--", "rocky10.example.com"])
        #expect(arguments.contains("-p") && arguments.contains("2222"))
        #expect(arguments.contains("-l") && arguments.contains("root"))
        #expect(arguments.prefix(3) == ["-v", "-E", "/tmp/x/log"])
    }

    @Test func optInSettingsAppear() throws {
        var settings = SSHConnectionSettings(authentication: .publicKey, identityFile: "~/.ssh/my key", proxyJump: "ops@jump:2200,bastion",
                                             compression: true, forwardAgent: true, gssapiDelegateCredentials: true, sendEnvironment: ["LANG"])
        settings.certificateFile = "~/.ssh/my key-cert.pub"
        let arguments = try SSHCommandBuilder.arguments(for: SSHTarget(host: "h", settings: ResolvedSSHSettings(settings)), logPath: "/l")
        #expect(arguments.contains("IdentityFile=\"~/.ssh/my key\""))
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.contains("ProxyJump=ops@jump:2200,bastion"))
        #expect(arguments.contains("ForwardAgent=yes"))
        #expect(arguments.contains("PreferredAuthentications=publickey"))
        #expect(arguments.contains("SendEnv=LANG"))
        #expect(arguments.contains("Compression=yes"))
    }

    @Test(arguments: [
        SSHTarget(host: "-oProxyCommand=evil"),
        SSHTarget(host: "h", username: "-oProxyCommand=x"),
        SSHTarget(host: "h", username: "a b"),
        SSHTarget(host: "h", settings: ResolvedSSHSettings(SSHConnectionSettings(identityFile: "a\" -o ProxyCommand=\"x"))),
        SSHTarget(host: "h", settings: ResolvedSSHSettings(SSHConnectionSettings(identityFile: "a\nProxyCommand x"))),
        SSHTarget(host: "h", settings: ResolvedSSHSettings(SSHConnectionSettings(proxyJump: "a b"))),
        SSHTarget(host: "h", settings: ResolvedSSHSettings(SSHConnectionSettings(proxyJump: "-oProxyCommand=x"))),
        SSHTarget(host: "h", settings: ResolvedSSHSettings(SSHConnectionSettings(hostAlias: "x y"))),
        SSHTarget(host: "h", settings: ResolvedSSHSettings(SSHConnectionSettings(sendEnvironment: ["A*"]))),
    ])
    func injectionAttemptsAreRefused(_ target: SSHTarget) {
        #expect(throws: SSHArgumentError.self) { try SSHCommandBuilder.arguments(for: target, logPath: "/l") }
    }

    @Test func knownHostsCanNeverBeDevNull() {
        var target = SSHTarget(host: "h")
        target.userKnownHostsFile = "/dev/null"
        #expect(throws: SSHArgumentError.self) { try SSHCommandBuilder.arguments(for: target, logPath: "/l") }
    }

    @Test func startupDirectoryIsQuotedForTheRemoteShell() {
        #expect(SSHCommandBuilder.remoteCommand(directory: nil, command: nil) == nil)
        #expect(SSHCommandBuilder.remoteCommand(directory: "/srv/it's here", command: nil)
            == "cd -- '/srv/it'\\''s here' && exec \"$SHELL\" -l")
        #expect(SSHCommandBuilder.remoteCommand(directory: nil, command: "htop") == "htop")
    }

    @Test func environmentIsRebuiltWithoutSecrets() {
        let base = ["HOME": "/Users/me", "USER": "me", "SSH_AUTH_SOCK": "/tmp/agent", "AWS_SECRET_ACCESS_KEY": "s3cr3t",
                    "PATH": "/opt/evil:/usr/bin", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "MY_TOKEN": "t"]
        let environment = SSHCommandBuilder.environment(from: base, terminalType: "xterm-256color", sendEnvironment: ["MY_TOKEN"],
                                                        askpassHelper: "/App/Contents/MacOS/RDPManagerAskpass", askpassSocket: "/tmp/s")
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment["MY_TOKEN"] == "t") // only because the connection asked to send it
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["TERM"] == "xterm-256color")
    }
}

@Suite("SSH: OpenSSH log and how sessions end")
struct SSHLogTests {
    @Test func stableMessagesAreRecognized() {
        #expect(SSHLogParser.parse("debug1: Connection established.") == .connectionEstablished)
        #expect(SSHLogParser.parse("debug1: Server host key: ssh-ed25519 SHA256:abc") == .serverHostKey(type: "ssh-ed25519", fingerprint: "SHA256:abc"))
        #expect(SSHLogParser.parse("debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none") == .cipher("chacha20-poly1305@openssh.com"))
        #expect(SSHLogParser.parse("Authenticated to 127.0.0.1 ([127.0.0.1]:22999) using \"publickey\".") == .authenticated(method: "publickey"))
        #expect(SSHLogParser.parse("debug1: Entering interactive session.") == .interactiveSession)
        #expect(SSHLogParser.parse("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@") == nil)
        #expect(SSHLogParser.parse("@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @") == .hostKeyChanged)
        #expect(SSHLogParser.parse("Offending ECDSA key in /Users/me/.ssh/known_hosts:12") == .offendingKnownHostsEntry("/Users/me/.ssh/known_hosts:12"))
        #expect(SSHLogParser.parse("debug2: something else") == nil)
    }

    @Test func serverTextIsSanitizedAndBounded() {
        let hostile = "ssh: connect to host x: \u{1B}]52;c;ZXZpbA==\u{07}" + String(repeating: "A", count: 5000)
        guard case let .error(line) = SSHLogParser.parse(hostile) else { Issue.record("expected an error line"); return }
        #expect(line.contains("\u{1B}") == false)
        #expect(line.count <= SSHLogParser.maximumLineLength)
    }

    private func end(_ lines: [String], status: Int32? = 255, user: Bool = false) -> SessionEnd {
        var progress = SSHConnectionProgress()
        for line in lines { if let event = SSHLogParser.parse(line) { progress.record(event) } }
        return SSHEndMapping.end(exitStatus: status, stoppedByUser: user, progress: progress)
    }

    @Test func failuresAreCategorized() {
        #expect(end(["me@h: Permission denied (publickey,password)."]).category == .authentication)
        #expect(end(["ssh: Could not resolve hostname nowhere: nodename nor servname provided, or not known"]).category == .network)
        #expect(end(["ssh: connect to host 10.0.0.1 port 22: Connection refused"]).category == .network)
        #expect(end(["Connection timed out during banner exchange"]).category == .network)
        #expect(end(["Unable to negotiate with 1.2.3.4 port 22: no matching host key type found."]).category == .unsupported)
        #expect(end(["@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @", "Host key verification failed."]).category == .certificate)
        #expect(end([], status: nil, user: true).kind == .userDisconnected)
        let dropped = end(["debug1: Entering interactive session.", "Timeout, server h not responding."])
        #expect(dropped.category == .network)
        #expect(dropped.kind == .failed)
        let exited = end(["debug1: Entering interactive session."], status: 0)
        #expect(exited.kind == .remoteEnded)
    }

    @Test func reconnectOnlyAfterADroppedLiveSession() {
        let policy = ReconnectPolicy()
        let dropped = end(["debug1: Entering interactive session.", "client_loop: send disconnect: Broken pipe"])
        #expect(policy.decision(after: dropped, wasShowingDesktop: true, attemptsMade: 0, enabled: true) != .stop)
        let refused = end(["me@h: Permission denied (publickey)."])
        #expect(policy.decision(after: refused, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
        let changed = end(["@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @"])
        #expect(policy.decision(after: changed, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
        let user = end([], status: nil, user: true)
        #expect(policy.decision(after: user, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
    }
}

@Suite("SSH: askpass prompts and when saved secrets may answer")
struct SSHPromptTests {
    @Test func realOpenSSHPromptsAreClassified() {
        let hostKey = """
        The authenticity of host '[127.0.0.1]:22999 ([127.0.0.1]:22999)' can't be established.
        ED25519 key fingerprint is: SHA256:rArJ29opguypEjzyEcpQf3UFL5Xy1wCaW3QguMfOukg
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        guard case let .unknownHostKey(prompt) = SSHPromptClassifier.classify(hostKey, hint: nil) else {
            Issue.record("not a host key prompt"); return
        }
        #expect(prompt.host == "[127.0.0.1]:22999 ([127.0.0.1]:22999)")
        #expect(prompt.keyType == "ED25519")
        #expect(prompt.fingerprint == "SHA256:rArJ29opguypEjzyEcpQf3UFL5Xy1wCaW3QguMfOukg")

        #expect(SSHPromptClassifier.classify("root@rocky10's password: ", hint: nil) == .password(user: "root", host: "rocky10"))
        #expect(SSHPromptClassifier.classify("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ", hint: nil) == .passphrase(keyPath: "/Users/me/.ssh/id_ed25519"))
        #expect(SSHPromptClassifier.classify("(root@rocky10) Password: ", hint: nil)
            == .keyboardInteractive(user: "root", host: "rocky10", prompt: "Password:", isPasswordLike: true))
        #expect(SSHPromptClassifier.classify("(root@rocky10) Verification code: ", hint: nil)
            == .keyboardInteractive(user: "root", host: "rocky10", prompt: "Verification code:", isPasswordLike: false))
        #expect(SSHPromptClassifier.classify("Confirm user presence for key ED25519-SK SHA256:x", hint: "none") == .notice("Confirm user presence for key ED25519-SK SHA256:x"))
        #expect(SSHPromptClassifier.classify("Enter PIN for ED25519-SK key /Users/me/.ssh/id_sk: ", hint: nil) == .pin("Enter PIN for ED25519-SK key /Users/me/.ssh/id_sk:"))
        if case .confirmation = SSHPromptClassifier.classify("Warning: the ECDSA host key for 'h' differs from the key for the IP address '1.2.3.4'\nAre you sure you want to continue connecting (yes/no)?", hint: nil) {} else {
            Issue.record("expected a confirmation")
        }
        if case .other = SSHPromptClassifier.classify("Enter new password: ", hint: nil) {} else { Issue.record("a new password is not the saved one") }
    }

    @Test func savedSecretsAnswerOnlyMatchingPromptsOnce() {
        var policy = SSHSecretPolicy(host: "rocky10", username: "root", keyPath: "/Users/me/.ssh/id_ed25519", hasPassword: true, hasPassphrase: true)
        #expect(policy.secret(for: .password(user: "root", host: "evil")) == nil)
        #expect(policy.secret(for: .password(user: "admin", host: "rocky10")) == nil)
        #expect(policy.secret(for: .keyboardInteractive(user: "root", host: "rocky10", prompt: "Verification code:", isPasswordLike: false)) == nil)
        #expect(policy.secret(for: .other("password please")) == nil)
        #expect(policy.secret(for: .password(user: "root", host: "rocky10")) == .password)
        // A second request means the first was refused: ask the user.
        #expect(policy.secret(for: .password(user: "root", host: "rocky10")) == nil)
        #expect(policy.secret(for: .keyboardInteractive(user: "root", host: "rocky10", prompt: "Password:", isPasswordLike: true)) == nil)
        #expect(policy.secret(for: .passphrase(keyPath: "/Users/me/.ssh/other")) == nil)
        #expect(policy.secret(for: .passphrase(keyPath: "/Users/me/.ssh/id_ed25519")) == .passphrase)
        #expect(policy.secret(for: .passphrase(keyPath: "/Users/me/.ssh/id_ed25519")) == nil)

        var nothingSaved = SSHSecretPolicy(host: "h", username: "", keyPath: nil, hasPassword: false, hasPassphrase: false)
        #expect(nothingSaved.secret(for: .password(user: "u", host: "h")) == nil)
        #expect(nothingSaved.secret(for: .unknownHostKey(SSHHostKeyPrompt(host: "h", keyType: nil, fingerprint: nil, text: ""))) == nil)
    }

    @Test func promptTextIsCleaned() {
        let text = SSHPromptClassifier.clean("Password:\u{1B}[31m \u{202E}evil" + String(repeating: "x", count: 10000))
        #expect(text.contains("\u{1B}") == false)
        #expect(text.contains("\u{202E}") == false)
        #expect(text.count <= SSHPromptClassifier.maximumPromptLength)
    }
}

@Suite("SSH: Quick Connect, ~/.ssh/config import, terminal preferences")
struct SSHInputTests {
    @Test func quickConnectStaysRDPUnlessSSHIsAsked() throws {
        #expect(try QuickConnectTarget.parse("server01") == .rdp(HostAddress(host: "server01", port: 3389)))
        #expect(try QuickConnectTarget.parse("server01:3390") == .rdp(HostAddress(host: "server01", port: 3390)))
        #expect(try QuickConnectTarget.parse("ssh://root@rocky10:2222") == .ssh(username: "root", address: HostAddress(host: "rocky10", port: 2222)))
        #expect(try QuickConnectTarget.parse("ssh://rocky10") == .ssh(username: "", address: HostAddress(host: "rocky10", port: 22)))
        #expect(try QuickConnectTarget.parse("ssh admin@[fe80::1]:2200") == .ssh(username: "admin", address: HostAddress(host: "fe80::1", port: 2200)))
        #expect(try QuickConnectTarget.parse("ops@web01", preferring: .ssh) == .ssh(username: "ops", address: HostAddress(host: "web01", port: 22)))
        #expect(throws: QuickConnectTarget.ParseError.self) { try QuickConnectTarget.parse("ssh://-oProxyCommand=x@h") }
        #expect(throws: QuickConnectTarget.ParseError.self) { try QuickConnectTarget.parse("ssh://-oProxyCommand=x") }
        #expect(throws: QuickConnectTarget.ParseError.self) { try QuickConnectTarget.parse("user@host") }
    }

    @Test func sshConfigImportTakesConcreteHostsOnly() {
        let config = """
        Host *
            ServerAliveInterval 60
            ForwardAgent yes
        Host web01 web02
            HostName 10.0.0.%h
            User deploy
        Host db
            HostName db.internal.example.com
            User postgres
            Port 2222
            IdentityFile ~/.ssh/db_ed25519
            IdentitiesOnly yes
            ProxyJump ops@bastion.example.com
            ServerAliveInterval 15
        Host evil
            HostName evil.example.com
            ProxyCommand nc %h %p
            LocalCommand open -a Calculator
            RemoteCommand rm -rf /
            ForwardAgent yes
        Match exec "touch /tmp/pwned"
            User x
        Host *.corp
            User corp
        Include extra.conf
        """
        let result = SSHConfigImporter.parse(config) { pattern in
            pattern == "extra.conf" ? [("/Users/me/.ssh/extra.conf", "Host extra\n  HostName extra.example.com\n")] : []
        }
        // web01/web02 use a %h token OpenSSH expands at connect time: listed, not imported.
        #expect(result.connections.map(\.name) == ["db", "evil", "extra"])
        #expect(result.notes.contains { $0.contains("web01") })
        #expect(result.connections.allSatisfy { $0.isSSH })
        let db = result.connections.first { $0.name == "db" }
        #expect(db?.host == "db.internal.example.com")
        #expect(db?.port == 2222)
        #expect(db?.ssh.username == "postgres")
        #expect(db?.ssh.identityFile == "~/.ssh/db_ed25519")
        #expect(db?.ssh.identitiesOnly == true)
        #expect(db?.ssh.proxyJump == "ops@bastion.example.com")
        #expect(db?.ssh.serverAliveIntervalSeconds == 15)
        let evil = result.connections.first { $0.name == "evil" }
        #expect(evil?.ssh.startupCommand == nil)
        #expect(evil?.ssh.forwardAgent == nil)
        #expect(result.notes.contains { $0.contains("evil") && $0.contains("proxycommand") && $0.contains("localcommand") && $0.contains("remotecommand") })
        #expect(result.notes.contains { $0.contains("Match exec is never run") })
        #expect(result.connections.contains { $0.name.contains("*") } == false)
    }

    @Test func riskyPastesNeedConfirmation() {
        #expect(TerminalPreferences.isRiskyPaste("ls -la", bracketedPasteActive: false) == false)
        #expect(TerminalPreferences.isRiskyPaste("ls\nrm -rf ~", bracketedPasteActive: false))
        #expect(TerminalPreferences.isRiskyPaste("reboot\n", bracketedPasteActive: false))
        #expect(TerminalPreferences.isRiskyPaste("ls\nrm -rf ~", bracketedPasteActive: true) == false)
    }

    @Test func preferencesAreClampedAndSafeByDefault() {
        let defaults = TerminalPreferences()
        #expect(defaults.allowRemoteClipboardWrite == false)
        #expect(defaults.confirmMultilinePaste)
        #expect(defaults.optionAsMeta == false)
        var wild = TerminalPreferences()
        wild.fontSize = 400
        wild.scrollbackLines = 10_000_000
        #expect(wild.clamped.fontSize == TerminalPreferences.fontSizeRange.upperBound)
        #expect(wild.clamped.scrollbackLines == TerminalPreferences.scrollbackRange.upperBound)
    }
}
