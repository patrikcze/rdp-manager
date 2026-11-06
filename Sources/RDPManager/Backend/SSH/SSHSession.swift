import AppKit
import Observation
import RDPManagerCore
import SwiftTerm

/// Where an SSH session is, as far as OpenSSH's log and prompts actually tell. Starting the
/// process is not "connected": that needs OpenSSH's own "Entering interactive session".
enum SSHSessionPhase: Equatable {
    case idle
    /// ssh started; no connection to the server yet.
    case connecting
    /// Connected to the server; checking its host key against known_hosts.
    case verifyingHostKey
    /// The host key is unknown: the user decides before anything is sent.
    case awaitingHostKeyDecision(SSHHostKeyPrompt)
    /// The host key is trusted; signing in.
    case authenticating
    /// OpenSSH asked something only the user can answer.
    case awaitingInput(SSHInputRequest)
    /// The shell is live.
    case connected
    case reconnecting(attempt: Int, of: Int)
    case ended(SessionEnd)

    var status: SessionStatus {
        switch self {
        case .idle: SessionStatus(tone: .idle, label: "Not connected")
        case .connecting: SessionStatus(tone: .inProgress, label: "Connecting…")
        case .verifyingHostKey: SessionStatus(tone: .inProgress, label: "Verifying host key…")
        case .awaitingHostKeyDecision: SessionStatus(tone: .needsUser, label: "Host key needs review")
        case .authenticating: SessionStatus(tone: .inProgress, label: "Authenticating…")
        case let .awaitingInput(request): SessionStatus(tone: .needsUser, label: request.isConfirmation ? "Needs confirmation" : "Sign-in required")
        case .connected: SessionStatus(tone: .connected, label: "Connected")
        case let .reconnecting(attempt, total): SessionStatus(tone: .inProgress, label: "Reconnecting (\(attempt)/\(total))…")
        case let .ended(end): SessionStatus(tone: end.kind == .failed ? .failed : .ended, label: end.kind == .failed ? "Failed" : "Disconnected")
        }
    }

    var isEnded: Bool {
        if case .ended = self { true } else { false }
    }
}

/// A question for the user from OpenSSH: a password, passphrase, code, PIN or yes/no.
struct SSHInputRequest: Equatable, Identifiable {
    let id = UUID()
    var kind: SSHPromptKind
    /// Why it is asked again, e.g. the saved password was refused.
    var message: String?
    /// Where "Save in Keychain" writes after OpenSSH accepted it; nil when it can't be saved.
    var saveAccount: SecretAccount?

    var isConfirmation: Bool {
        if case .confirmation = kind { true } else { false }
    }

    var title: String {
        switch kind {
        case .password: "Password"
        case .passphrase: "Key Passphrase"
        case .keyboardInteractive: "Sign-In"
        case .pin: "Security Key PIN"
        case .confirmation: "OpenSSH Asks"
        default: "OpenSSH Asks"
        }
    }

    var promptText: String {
        switch kind {
        case let .password(user, host): "Password for \(user)@\(host)"
        case let .passphrase(path): "Passphrase for the key \(path)"
        case let .keyboardInteractive(user, host, prompt, _):
            [user.flatMap { user in host.map { "\(user)@\($0)" } }, prompt].compactMap(\.self).joined(separator: " — ")
        case let .pin(text), let .confirmation(text), let .other(text), let .notice(text): text
        case let .unknownHostKey(prompt): prompt.text
        }
    }
}

/// One SSH connection and its terminal, observed by the UI. Runs OpenSSH through an
/// `SSHTransport`; reads the log for its state, answers askpass prompts from the Keychain
/// only where `SSHSecretPolicy` allows, and otherwise asks the user. Independent of every
/// other session.
@MainActor
@Observable
final class SSHSession: Identifiable {
    let id = UUID()
    let connectionID: UUID?
    private(set) var title: String
    private(set) var target: SSHTarget
    private(set) var phase: SSHSessionPhase = .idle
    private(set) var connectedAt: Date?
    private(set) var reconnectCount = 0
    private(set) var serverHostKey: (type: String, fingerprint: String)?
    private(set) var hostKeyVerified = false
    private(set) var authenticationMethod: String?
    private(set) var keyExchange: String?
    private(set) var cipher: String?
    private(set) var remoteSoftware: String?
    /// The title the remote program set (sanitized), shown in the inspector.
    private(set) var remoteTitle: String?
    private(set) var lastNotice: String?
    /// A notice from OpenSSH such as "touch your security key"; cleared when it moves on.
    private(set) var securityKeyNotice: String?

    @ObservationIgnored var onConnected: ((SSHSession) -> Void)?
    /// A typed password was saved for a connection that had no saved secret.
    @ObservationIgnored var onSavedConnectionPassword: ((SSHSession) -> Void)?

    @ObservationIgnored let terminal: SSHTerminalView
    @ObservationIgnored private let makeTransport: @MainActor () -> SSHTransport
    @ObservationIgnored private var transport: SSHTransport?
    @ObservationIgnored let output = TerminalOutputSink()
    @ObservationIgnored private let credentials: CredentialService
    @ObservationIgnored private let secretAccounts: (password: SecretAccount?, passphrase: SecretAccount?)
    @ObservationIgnored private let reconnectPolicy = ReconnectPolicy()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var progress = SSHConnectionProgress()
    @ObservationIgnored private var policy: SSHSecretPolicy
    @ObservationIgnored private var pendingReply: (@Sendable (String?) -> Void)?
    @ObservationIgnored private var typedSecret: (value: String, account: SecretAccount, kind: SSHSecretPolicy.Secret)?
    @ObservationIgnored private var stoppedByUser = false
    @ObservationIgnored private var hostKeyRejectedByUser = false
    @ObservationIgnored private var wasConnected = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var attempt = 0

    init(
        connectionID: UUID?,
        title: String,
        target: SSHTarget,
        passwordAccount: SecretAccount?,
        passphraseAccount: SecretAccount?,
        credentials: CredentialService,
        preferences: TerminalPreferences,
        makeTransport: @escaping @MainActor () -> SSHTransport = { OpenSSHProcessTransport() }
    ) {
        self.connectionID = connectionID
        self.title = title
        self.target = target
        self.credentials = credentials
        self.makeTransport = makeTransport
        secretAccounts = (passwordAccount, passphraseAccount)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        policy = SSHSecretPolicy(
            host: target.host, username: target.username,
            keyPath: target.identityFile.map { SSHSecretPolicy.expandTilde($0, home: home) },
            hasPassword: false, hasPassphrase: false
        )
        terminal = SSHTerminalView(preferences: preferences)
        terminal.terminalDelegate = self
        output.receiver = terminal
    }

    var hostLabel: String { target.label }
    var status: SessionStatus { phase.status }
    var surface: NSView { terminal }
    var hasInputFocus: Bool { terminal.window?.firstResponder === terminal }
    var settings: ResolvedSSHSettings { target.settings }

    // MARK: - Lifecycle

    /// A connection the user asked for: resets automatic reconnects and starts ssh.
    func connect() {
        guard isClosed == false else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectCount = 0
        startAttempt()
    }

    /// Hangs up. Programs in the remote shell get SIGHUP, as when a terminal window closes.
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if isRunning {
            stoppedByUser = true
            answerPending(nil)
            transport?.stop()
        } else if phase.isEnded == false {
            phase = .ended(SSHEndMapping.end(exitStatus: nil, stoppedByUser: true, progress: progress))
        }
    }

    func close() {
        guard isClosed == false else { return }
        disconnect()
        isClosed = true
        typedSecret = nil
    }

    /// Waits for ssh to exit after `close`, as the app does at quit.
    func waitUntilEnded(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func startAttempt() {
        guard isRunning == false else { return }
        attempt += 1
        progress = SSHConnectionProgress()
        stoppedByUser = false
        hostKeyRejectedByUser = false
        wasConnected = false
        serverHostKey = nil
        hostKeyVerified = false
        authenticationMethod = nil
        keyExchange = nil
        cipher = nil
        remoteSoftware = nil
        securityKeyNotice = nil
        connectedAt = nil
        if reconnectCount == 0 { phase = .connecting }
        let thisAttempt = attempt
        // Whether secrets are saved is checked without reading them; they are read only for
        // a prompt that matches (SSHSecretPolicy).
        Task { [weak self, credentials, secretAccounts, target] in
            let usesProxy = await SSHConfigProbe.usesProxy(target)
            let hasPassword = if let account = secretAccounts.password { await credentials.hasPassword(for: account) } else { false }
            let hasPassphrase = if let account = secretAccounts.passphrase { await credentials.hasPassword(for: account) } else { false }
            guard let self, attempt == thisAttempt else { return }
            self.target.usesProxy = usesProxy
            policy.hasPassword = hasPassword
            policy.hasPassphrase = hasPassphrase
            launch()
        }
    }

    private func launch() {
        guard isClosed == false, isRunning == false else { return }
        let transport = makeTransport()
        transport.delegate = self
        self.transport = transport
        let size = terminal.dimensions
        do {
            try transport.start(target: target, columns: size.columns, rows: size.rows, output: output)
            isRunning = true
        } catch {
            phase = .ended(SessionEnd(kind: .failed, category: .client, title: "SSH Could Not Start", message: error.localizedDescription))
        }
    }

    // MARK: - Host key

    func trustHostKey() {
        guard case .awaitingHostKeyDecision = phase else { return }
        phase = .authenticating
        answerPending("yes")
    }

    func rejectHostKey() {
        guard case .awaitingHostKeyDecision = phase else { return }
        hostKeyRejectedByUser = true
        answerPending("no")
    }

    // MARK: - Prompts

    /// The user's answer. `save` keeps a password or passphrase in the Keychain once OpenSSH
    /// has accepted it, never before.
    func submit(_ answer: String, for request: SSHInputRequest, save: Bool) {
        guard case let .awaitingInput(current) = phase, current.id == request.id else { return }
        if save, let account = request.saveAccount {
            switch request.kind {
            case .password, .keyboardInteractive: typedSecret = (answer, account, .password)
            case .passphrase: typedSecret = (answer, account, .passphrase)
            default: break
            }
        }
        phase = .authenticating
        answerPending(answer)
    }

    /// A yes/no question from OpenSSH.
    func confirm(_ yes: Bool, for request: SSHInputRequest) {
        guard case let .awaitingInput(current) = phase, current.id == request.id else { return }
        phase = .authenticating
        answerPending(yes ? "yes" : "no")
    }

    /// Cancelling a sign-in prompt ends the attempt; an empty answer would be sent as a
    /// password otherwise.
    func cancelInput() {
        disconnect()
    }

    private func answerPending(_ answer: String?) {
        let reply = pendingReply
        pendingReply = nil
        reply?(answer)
    }

    // MARK: - Terminal commands

    func focusInput() {
        terminal.window?.makeFirstResponder(terminal)
    }

    /// Ctrl-C, as if typed.
    func sendInterrupt() {
        guard phase == .connected else { return }
        transport?.write([0x03])
    }

    func clearScrollback() {
        terminal.clearScrollback()
    }

    func copySelection() {
        terminal.copy(self)
    }

    func paste() {
        focusInput()
        terminal.paste(self)
    }

    func find() {
        focusInput()
        terminal.showFind()
    }

    func changeFontSize(by step: Double) {
        terminal.changeFontSize(by: step)
    }

    func apply(_ preferences: TerminalPreferences) {
        terminal.apply(preferences)
    }
}

// MARK: - Transport events

extension SSHSession: SSHTransportDelegate {
    func transport(logged event: SSHLogEvent) {
        progress.record(event)
        switch event {
        case .connectionEstablished:
            if case .connecting = phase { phase = .verifyingHostKey }
            if case .reconnecting = phase { phase = .verifyingHostKey }
        case let .remoteSoftware(software):
            remoteSoftware = String(software.prefix(80))
        case let .keyExchange(algorithm):
            keyExchange = algorithm
        case let .cipher(name):
            cipher = name
        case let .serverHostKey(type, fingerprint):
            serverHostKey = (type, fingerprint)
        case .hostKeyVerified:
            hostKeyVerified = true
            if phase == .verifyingHostKey { phase = .authenticating }
        case let .authenticated(method):
            authenticationMethod = method
            hostKeyVerified = true
            securityKeyNotice = nil
            if phase == .verifyingHostKey { phase = .authenticating }
            saveTypedSecret(acceptedBy: method)
            // Through a proxy the log is quieter (see SSHTarget.usesProxy): signing in is the
            // last thing it reports before the shell.
            if target.usesProxy || target.settings.proxyJump != nil { markConnected() }
        case .interactiveSession:
            markConnected()
        default:
            break
        }
    }

    private func markConnected() {
        guard phase != .connected else { return }
        reconnectCount = 0
        wasConnected = true
        connectedAt = Date()
        securityKeyNotice = nil
        phase = .connected
        onConnected?(self)
    }

    func transport(asked request: AskpassRequest, reply: @escaping @Sendable (String?) -> Void) {
        guard isClosed == false, stoppedByUser == false else { return reply(nil) }
        // One question at a time; a second one while the first waits is refused.
        guard pendingReply == nil else { return reply(nil) }
        let kind = SSHPromptClassifier.classify(request.prompt, hint: request.hint)
        switch kind {
        case let .notice(text):
            // Informational ("touch your security key"): shown, not answered.
            securityKeyNotice = text
            reply("")
            return
        case let .unknownHostKey(prompt):
            pendingReply = reply
            phase = .awaitingHostKeyDecision(prompt)
            return
        default:
            break
        }
        if let secret = policy.secret(for: kind) {
            let account = secret == .password ? secretAccounts.password : secretAccounts.passphrase
            guard let account else { return ask(kind, message: nil, reply: reply) }
            pendingReply = reply
            phase = .authenticating
            Task { [weak self, credentials] in
                let stored = try? await credentials.password(for: account)
                guard let self else { return reply(nil) }
                if let stored, stored.isEmpty == false {
                    answerPending(stored)
                } else {
                    pendingReply = nil
                    ask(kind, message: "The saved \(secret == .password ? "password" : "passphrase") could not be read.", reply: reply)
                }
            }
            return
        }
        // A secret the policy already offered once is being asked again: it was refused.
        let refusedAgain: String? = switch kind {
        case .password, .keyboardInteractive: policy.hasPassword ? "The saved password was not accepted." : nil
        case .passphrase: policy.hasPassphrase ? "The saved passphrase was not accepted." : nil
        default: nil
        }
        ask(kind, message: refusedAgain, reply: reply)
    }

    private func ask(_ kind: SSHPromptKind, message: String?, reply: @escaping @Sendable (String?) -> Void) {
        pendingReply = reply
        let saveAccount: SecretAccount? = switch kind {
        case .password: secretAccounts.password
        case let .keyboardInteractive(_, _, _, isPasswordLike): isPasswordLike ? secretAccounts.password : nil
        case .passphrase: secretAccounts.passphrase
        default: nil
        }
        phase = .awaitingInput(SSHInputRequest(kind: kind, message: message, saveAccount: saveAccount))
    }

    /// A secret typed with "Save" goes to the Keychain once OpenSSH reports that it worked.
    private func saveTypedSecret(acceptedBy method: String) {
        guard let typed = typedSecret else { return }
        let accepted = switch typed.kind {
        case .password: method == "password" || method == "keyboard-interactive"
        case .passphrase: method == "publickey"
        }
        typedSecret = nil
        guard accepted else { return }
        Task { [weak self, credentials] in
            do {
                try await credentials.setPassword(typed.value, for: typed.account)
                if let self, case .sshPassword = typed.account { onSavedConnectionPassword?(self) }
            } catch {
                self?.lastNotice = "The \(typed.kind == .password ? "password" : "passphrase") could not be saved: \(error.localizedDescription)"
            }
        }
    }

    func transport(exitedWithStatus status: Int32?, signal: Int32?) {
        isRunning = false
        transport = nil
        connectedAt = nil
        pendingReply = nil
        securityKeyNotice = nil
        typedSecret = nil
        var end = SSHEndMapping.end(exitStatus: status, stoppedByUser: stoppedByUser, progress: progress)
        if hostKeyRejectedByUser {
            end = SessionEnd(kind: .userDisconnected, category: .certificate, title: "Host Key Not Trusted",
                             message: "You did not trust the server's host key. Nothing was sent to it.")
        }
        guard isClosed == false else {
            phase = .ended(end)
            return
        }
        switch reconnectPolicy.decision(after: end, wasShowingDesktop: wasConnected || reconnectCount > 0,
                                        attemptsMade: reconnectCount, enabled: target.settings.autoReconnect) {
        case let .reconnect(attempt, delay):
            reconnectCount = attempt
            phase = .reconnecting(attempt: attempt, of: reconnectPolicy.maxAttempts)
            terminal.feed(text: "\r\n\u{1B}[2m[Connection lost — reconnecting. Nothing typed is resent.]\u{1B}[0m\r\n")
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard Task.isCancelled == false else { return }
                self?.startAttempt()
            }
        case .stop:
            phase = .ended(end)
        }
    }
}

// MARK: - Terminal events

extension SSHSession: TerminalViewDelegate {
    func sizeChanged(source _: TerminalView, newCols: Int, newRows: Int) {
        transport?.resize(columns: UInt16(clamping: max(newCols, 2)), rows: UInt16(clamping: max(newRows, 1)))
    }

    func setTerminalTitle(source _: TerminalView, title: String) {
        let clean = SSHLogParser.sanitized(title).prefix(120)
        remoteTitle = clean.isEmpty ? nil : String(clean)
    }

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}

    func send(source _: TerminalView, data: ArraySlice<UInt8>) {
        // Input goes to the running ssh only: nothing is buffered for a later connection.
        guard isRunning else { return }
        transport?.write(Array(data))
    }

    func scrolled(source _: TerminalView, position _: Double) {}

    func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}

    /// Links open only when the user clicks them, and only web links.
    func requestOpenLink(source _: TerminalView, link: String, params _: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            lastNotice = "Only web links open from the terminal."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func bell(source _: TerminalView) {
        NSSound.beep()
    }

    /// OSC 52: a remote program asks to set the Mac clipboard. Refused unless the user
    /// allowed it in Settings; reading the clipboard is never allowed.
    func clipboardCopy(source _: TerminalView, content: Data) {
        guard terminal.preferences.allowRemoteClipboardWrite else {
            lastNotice = "A remote program tried to set the clipboard. Allow it in Settings › Terminal."
            return
        }
        guard content.count <= 1_000_000, let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source _: TerminalView) -> Data? {
        nil
    }

    func iTermContent(source _: TerminalView, content _: ArraySlice<UInt8>) {}
}
