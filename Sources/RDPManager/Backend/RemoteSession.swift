import AppKit
import Observation
import RDPKit
import RDPKitAppKit
import RDPManagerCore

/// Measured numbers of a live session, from RDPKit's render metrics. Nil means not measured.
struct SessionStatistics: Equatable {
    var framesPerSecond: Double?
    var wireMegabitsPerSecond: Double?
    var averageDecodeMilliseconds: Double?
    var hardwareDecoding: Bool?
    var codec: String?
    var decodedFrames: Int
    var failedDecodes: Int
    var firstFrameMilliseconds: Double?
}

/// The prompt shown when a session needs credentials.
struct CredentialPrompt: Equatable {
    var username: String
    var domain: String
    var message: String?
    /// Where "Save in Keychain" writes; nil when the session cannot save (Quick Connect).
    var saveAccount: SecretAccount?
}

/// One remote desktop connection: its RDPKit session, the surface that shows it, and the
/// state the UI observes. Every session is independent; closing one leaves the others alone.
@MainActor
@Observable
final class RemoteSession: Identifiable {
    let id = UUID()
    /// The saved connection this session opened, or nil for Quick Connect.
    let connectionID: UUID?
    private(set) var title: String
    let address: HostAddress
    private(set) var settings: ResolvedSettings

    private(set) var phase: SessionPhase = .idle
    private(set) var connectedAt: Date?
    private(set) var reconnectCount = 0
    private(set) var desktopPixelSize: CGSize?
    private(set) var signedInAs: String?
    private(set) var certificateSHA256: String?
    private(set) var certificateTrustedBySystem: Bool?
    private(set) var certificateTrustedByUser = false
    private(set) var tlsProtocol: String?
    private(set) var credentialPrompt: CredentialPrompt?
    private(set) var statistics: SessionStatistics?
    private(set) var clipboardEnabled: Bool
    private(set) var lastNotice: String?
    /// Engine stage while connecting, for diagnostics.
    private(set) var connectionStage: String?

    /// Called once per connection that showed the desktop, to record "last connected".
    @ObservationIgnored var onDesktopShown: ((RemoteSession) -> Void)?
    /// Called when the user asked to save credentials and the server verified them.
    @ObservationIgnored var onVerifiedCredentials: ((RemoteSession, _ username: String, _ domain: String) -> Void)?

    @ObservationIgnored let canvas = RemoteDesktopCanvas()
    @ObservationIgnored private lazy var framePresenter = RDPFramePresenter(videoView: canvas.videoView)
    @ObservationIgnored private let credentials: CredentialService
    @ObservationIgnored private let trustStore: CertificateTrustStore
    @ObservationIgnored private let profiles: [CredentialProfile]
    @ObservationIgnored private let reconnectPolicy = ReconnectPolicy()

    @ObservationIgnored private var liveSession: RDPLiveSession?
    @ObservationIgnored private var inputSession: RDPInputSession?
    @ObservationIgnored private var displayControl: RDPDisplayControlSession?
    @ObservationIgnored private var serverMonitorCount = 0
    @ObservationIgnored private var lastSentDisplayRequest: RDPDisplayRequest?
    @ObservationIgnored private var viewerSurface: (size: CGSize, scale: CGFloat)?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var credentialTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var clipboard: RDPPasteboardClipboard?
    @ObservationIgnored private let audioPlayer = RDPAudioPlayer()
    @ObservationIgnored private let metricsStore = RDPRenderMetricsStore()
    @ObservationIgnored private var latestFrame: RDPGraphicsFrameSnapshot?
    @ObservationIgnored private var frameMetadata: RDPFrameMetadata?
    @ObservationIgnored private var hasPresentedFrame = false
    @ObservationIgnored private var refusedCertificate: RDPServerCertificateInfo?

    /// The identity this attempt signs in with. The password stays in memory only for the
    /// session's lifetime, so Reconnect needs no new prompt; it is cleared when refused.
    @ObservationIgnored private var username = ""
    @ObservationIgnored private var domain = ""
    @ObservationIgnored private var password = ""
    @ObservationIgnored private var saveVerifiedPasswordTo: SecretAccount?
    @ObservationIgnored private var didAskForCredentials = false
    @ObservationIgnored private var isClosed = false

    init(
        connectionID: UUID?,
        title: String,
        address: HostAddress,
        settings: ResolvedSettings,
        profiles: [CredentialProfile],
        credentials: CredentialService,
        trustStore: CertificateTrustStore
    ) {
        self.connectionID = connectionID
        self.title = title
        self.address = address
        self.settings = settings
        self.profiles = profiles
        self.credentials = credentials
        self.trustStore = trustStore
        clipboardEnabled = settings.clipboardEnabled
        canvas.claimsCommandShortcuts = settings.sendsCommandShortcutsToRemote
        canvas.onSurfaceChange = { [weak self] size, scale in
            self?.viewerSurface = (size, scale)
            self?.scheduleResize()
        }
        framePresenter.onShow = { [weak self] presentation in
            self?.noteShown(presentation)
        }
        // The presenter paces frames to the display its clock view is on; the clock draws
        // nothing but has to be in the window.
        let clock = framePresenter.clockView
        clock.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        canvas.addSubview(clock)
    }

    var hostLabel: String {
        address.port == 3389 ? address.host : "\(address.host):\(address.port)"
    }

    var hasInputFocus: Bool { canvas.hasInputFocus }

    // MARK: - Lifecycle

    /// Starts a connection the user asked for: resets automatic reconnects, finds the
    /// password (Keychain, then prompt) and connects.
    func connect() {
        guard isClosed == false else { return }
        cancelPendingWork()
        reconnectCount = 0
        lastNotice = nil
        if password.isEmpty == false || didAskForCredentials {
            startAttempt()
            return
        }
        switch CredentialPlan.plan(for: settings.credential, connectionID: connectionID, profiles: profiles) {
        case let .prompt(username, domain, saveTo):
            askForCredentials(username: username, domain: domain, message: nil, saveTo: saveTo)
        case let .keychain(username, domain, account):
            self.username = username
            self.domain = domain
            phase = .resolvingCredentials
            credentialTask = Task { [weak self, credentials] in
                let stored: String?
                do {
                    stored = try await credentials.password(for: account)
                } catch {
                    self?.askForCredentials(
                        username: username, domain: domain,
                        message: "The saved password could not be read: \(error.localizedDescription)",
                        saveTo: account
                    )
                    return
                }
                guard let self, Task.isCancelled == false else { return }
                if let stored, stored.isEmpty == false {
                    password = stored
                    startAttempt()
                } else {
                    askForCredentials(username: username, domain: domain, message: nil, saveTo: account)
                }
            }
        }
    }

    /// Credentials the user typed. `save` writes them to the Keychain once the server has
    /// verified them, never before.
    func submitCredentials(username: String, domain: String, password: String, save: Bool) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username
        self.domain = domain
        self.password = password
        saveVerifiedPasswordTo = save ? credentialPrompt?.saveAccount : nil
        credentialPrompt = nil
        didAskForCredentials = true
        reconnectCount = 0
        startAttempt()
    }

    func cancelCredentialPrompt() {
        credentialPrompt = nil
        phase = .ended(SessionEnd(kind: .userDisconnected, category: .none, title: "Not connected", message: "Sign-in was cancelled."))
    }

    /// Ends the RDP connection. The Windows session stays on the server (disconnected, not
    /// signed out) until its policy ends it.
    func disconnect() {
        cancelPendingWork()
        endLiveSession()
        if case .ended = phase {} else {
            phase = .ended(.userDisconnected)
        }
    }

    /// Disconnects and releases everything; the session cannot be used again.
    func close() {
        guard isClosed == false else { return }
        disconnect()
        isClosed = true
        password = ""
    }

    /// Waits for the engine thread to tell the server goodbye, as the app does at quit.
    func waitUntilEnded(timeout: TimeInterval) async {
        guard let liveSession else { return }
        _ = await liveSession.waitUntilEnded(timeout: timeout)
    }

    // MARK: - Certificate decision

    /// Trusts the certificate that was refused, for this host and port, and connects again.
    func trustCertificateAndConnect() {
        guard let info = refusedCertificate,
              let key = RDPServerCertificateTrustKey(host: info.host.isEmpty ? address.host : info.host, port: address.port, sha256: info.sha256)
        else { return }
        trustStore.trust(key)
        refusedCertificate = nil
        startAttempt()
    }

    func rejectCertificate() {
        refusedCertificate = nil
        phase = .ended(SessionEnd(
            kind: .failed, category: .certificate, title: "Certificate not trusted",
            message: "The connection was closed before any credential was sent."
        ))
    }

    // MARK: - Commands

    func focusRemoteInput() {
        canvas.makeInputFirstResponder()
    }

    /// Ctrl+Alt+Del on the remote computer (the Secure Attention Sequence goes as scancodes;
    /// the Mac never sees it).
    func sendCtrlAltDelete() {
        sendChord([RDPKeyboardScancode(code: 0x1D, isExtended: false),
                   RDPKeyboardScancode(code: 0x38, isExtended: false),
                   RDPKeyboardScancode(code: 0x53, isExtended: true)])
    }

    /// The Windows key with `scancode` (e.g. R = 0x13, E = 0x12), or alone when nil.
    func sendWindowsKey(with scancode: UInt16?) {
        var keys = [RDPKeyboardScancode(code: 0x5B, isExtended: true)]
        if let scancode {
            keys.append(RDPKeyboardScancode(code: scancode, isExtended: false))
        }
        sendChord(keys)
    }

    func sendAltTab() {
        sendChord([RDPKeyboardScancode(code: 0x38, isExtended: false), RDPKeyboardScancode(code: 0x0F, isExtended: false)])
    }

    private func sendChord(_ keys: [RDPKeyboardScancode]) {
        guard let inputSession else { return }
        let down = keys.map { RDPSlowPathInputEvent.keyboard(scancode: $0, isReleased: false) }
        let up = keys.reversed().map { RDPSlowPathInputEvent.keyboard(scancode: $0, isReleased: true) }
        inputSession.send(down + up)
    }

    func setClipboardEnabled(_ enabled: Bool) {
        clipboardEnabled = enabled
        clipboard?.setSharingEnabled(enabled)
        if enabled, clipboard == nil, phase.isActive {
            lastNotice = "Clipboard sharing starts with the next connection."
        }
    }

    // MARK: - Attempts

    private func askForCredentials(username: String, domain: String, message: String?, saveTo: SecretAccount?) {
        credentialPrompt = CredentialPrompt(username: username, domain: domain, message: message, saveAccount: saveTo)
        phase = .awaitingCredentials(message: message)
    }

    private func startAttempt() {
        endLiveSession()
        let configuration: RDPConnectionConfiguration
        do {
            configuration = try makeConfiguration()
        } catch {
            phase = .ended(SessionEnd(kind: .failed, category: .client, title: "Invalid settings", message: "\(error)"))
            return
        }
        if reconnectCount == 0 {
            phase = .connecting(detail: nil)
        }
        hasPresentedFrame = false
        frameMetadata = nil
        latestFrame = nil
        statistics = nil
        certificateSHA256 = nil
        certificateTrustedBySystem = nil
        metricsStore.reset(connectionStartedAt: Date())
        signedInAs = username.isEmpty ? nil : (domain.isEmpty ? username : "\(domain)\\\(username)")
        if configuration.clipboardEnabled {
            clipboard = RDPPasteboardClipboard(
                isSharingEnabled: clipboardEnabled,
                downloadRoot: FileManager.default.temporaryDirectory.appending(path: "RDP Manager Clipboard"),
                quarantineAgentName: "RDP Manager"
            )
        }

        let session = RDPLiveSession(threadName: "RDP session \(address.host)")
        liveSession = session
        run(session, configuration: configuration)
        startTicking()
        render()
    }

    private func makeConfiguration() throws -> RDPConnectionConfiguration {
        let target = try RDPConnectionTarget(host: address.host, port: address.port)
        let credentials = username.isEmpty && password.isEmpty
            ? nil
            : try RDPCredentials.validated(username: username, domain: domain, password: password)
        let desktopSize: RDPDesktopSize
        switch settings.display {
        case let .fixed(width, height):
            desktopSize = try RDPDesktopSize(width: UInt16(clamping: width), height: UInt16(clamping: height))
        case .matchWindow:
            // Start at the view's size in points at 100%; Display Control switches to full
            // Retina pixels and the right scale once its channel opens.
            var surface = canvas.bounds.size
            if surface.width < 200 || surface.height < 200 {
                surface = (canvas.window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            }
            desktopSize = RDPDesktopSize(RDPDisplayRequest(pointSize: surface, backingScaleFactor: 1))
        }
        let keyboard = RDPMacKeyboardLayout.current()
        canvas.keyboard = keyboard
        var configuration = RDPConnectionConfiguration(
            target: target,
            credentials: credentials,
            timeoutSeconds: settings.timeoutSeconds,
            // Certificate warnings are never hidden: the trust decision is the user's.
            hideCertificateWarnings: false,
            graphicsFrameCaptureLimit: nil,
            desktopSize: desktopSize,
            // Not joining the channel at all when the policy says no: Windows empties its
            // clipboard on join, and nothing can cross.
            clipboardEnabled: settings.clipboardEnabled,
            clipboardFetchesRemoteCopies: false,
            audioPlaybackEnabled: settings.audioPlaybackEnabled,
            graphicsCapabilityProfile: .automatic,
            legacyRSAKeyExchange: .fallback,
            legacyCredSSP: false,
            clientName: Host.current().localizedName ?? "RDP Manager"
        )
        configuration.keyboard = keyboard
        // macOS may fail the first connect into the local network while it asks for access.
        configuration.connectAttempts = 3
        configuration.connectRetryDelay = 1.3
        return configuration
    }

    private func run(_ session: RDPLiveSession, configuration: RDPConnectionConfiguration) {
        let recipient = session.recipient(self)
        let trustStore = trustStore
        let port = configuration.port
        let audioPlayer = audioPlayer
        session.start(
            events: RDPLiveSession.Events(
                onFrameDecoded: { [weak self] presentation, receivedAt, decodedAt, timing in
                    guard let self else { return }
                    metricsStore.recordDecodedFrame(presentation.frame, receivedAt: receivedAt, decodedAt: decodedAt, timing: timing)
                    if framePresenter.present(presentation) == .replaced {
                        metricsStore.recordSkippedPresentationFrame(at: Date())
                    }
                },
                onFrameDecodeFailed: { [weak self] receivedAt, description in
                    self?.metricsStore.recordDecodeFailure(receivedAt: receivedAt, errorDescription: description)
                },
                onWireReceive: { [weak self] sample in
                    self?.metricsStore.recordWireReceive(sample)
                },
                onServerLayout: { [weak self] layout in
                    self?.serverMonitorCount = layout.monitors.count
                    self?.scheduleResize()
                },
                onEnd: { report in
                    recipient.deliver { session in
                        session.finish(report)
                    }
                }
            )
        ) { run in
            RDPSessionClient().run(
                configuration: configuration,
                onGraphicsFrame: run.onGraphicsFrame,
                onInputReady: { input in
                    recipient.deliver { session in session.activated(input) }
                },
                onDisplayControlReady: { control in
                    recipient.deliver { session in session.displayControlReady(control) }
                },
                onClipboardReady: { clipboard in
                    recipient.deliver { session in session.clipboard?.attach(clipboard) }
                },
                onClipboardText: { text, copyNumber in
                    recipient.deliver { session in session.clipboard?.receiveText(text, copyNumber: copyNumber) }
                },
                onClipboardFileGroupDescriptor: { list, copyNumber in
                    recipient.deliver { session in session.clipboard?.receiveFileList(list, copyNumber: copyNumber) }
                },
                onClipboardRemoteCopyUnavailable: { isEmpty, copyNumber in
                    recipient.deliver { session in
                        session.clipboard?.receiveRemoteCopyUnavailable(isEmpty: isEmpty, copyNumber: copyNumber)
                    }
                },
                onAudioSample: { sample in
                    recipient.deliver { session in session.play(sample) }
                },
                audioPlaybackDelay: { audioPlayer.playbackDelay },
                onCertificate: { info in
                    // Runs during TLS, before any credential is sent: refusing here means the
                    // server never sees the password.
                    let refusal = trustStore.trusted.refusal(of: info, port: port, acceptsUntrusted: false)
                    if refusal != nil {
                        run.cancellation.cancel()
                    }
                    recipient.deliver { session in session.received(info, refusal: refusal) }
                },
                onWireReceive: run.onWireReceive,
                liveReport: run.liveReport,
                cancellation: run.cancellation
            )
        }
    }

    // MARK: - Engine events (main actor, in order)

    private func received(_ info: RDPServerCertificateInfo, refusal: RDPServerCertificateRefusal?) {
        certificateSHA256 = info.sha256
        certificateTrustedBySystem = info.trusted
        certificateTrustedByUser = trustStore.trusted.isTrusted(host: info.host, port: address.port, sha256: info.sha256)
        guard let refusal else { return }
        refusedCertificate = info
        endLiveSession()
        phase = .awaitingCertificateDecision(CertificateIssue(
            kind: refusal == .changed ? .changed : .untrusted,
            host: info.host.isEmpty ? address.host : info.host,
            port: address.port,
            sha256: info.sha256,
            systemTrustDetail: info.warnings.map(\.message).joined(separator: "\n").nilIfEmpty
        ))
    }

    private func activated(_ input: RDPInputSession) {
        inputSession = input
        if displayControl?.isEnded == true {
            displayControl = nil
        }
        // Over NLA the server checked the password before activating: only then is it worth
        // saving.
        if let account = saveVerifiedPasswordTo, input.connectionContext.credentialsVerifiedBeforeActivation {
            saveVerifiedPasswordTo = nil
            let password = password
            Task { [weak self, credentials] in
                do {
                    try await credentials.setPassword(password, for: account)
                    if let self {
                        onVerifiedCredentials?(self, username, domain)
                    }
                } catch {
                    self?.lastNotice = "The password could not be saved: \(error.localizedDescription)"
                }
            }
        }
        render()
    }

    private func displayControlReady(_ control: RDPDisplayControlSession) {
        displayControl = control
        lastSentDisplayRequest = nil
        serverMonitorCount = control.serverMonitors.count
        scheduleResize()
    }

    private func noteShown(_ presentation: RDPDecodedFramePresentation) {
        let frame = presentation.frame
        latestFrame = frame
        let sizeChanged = frameMetadata?.width != frame.width || frameMetadata?.height != frame.height
        if sizeChanged {
            frameMetadata = RDPFrameMetadata(frame)
            desktopPixelSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        }
        if hasPresentedFrame == false {
            hasPresentedFrame = true
            reconnectCount = 0
            connectedAt = Date()
            phase = .connected
            onDesktopShown?(self)
            render()
            canvas.makeInputFirstResponder()
        } else if sizeChanged {
            render()
        }
    }

    private func play(_ sample: RDPAudioSample) {
        guard settings.audioPlaybackEnabled else { return }
        _ = try? audioPlayer.enqueue(sample)
    }

    private func finish(_ report: RDPConnectionReport) {
        framePresenter.flush()
        let wasShowingDesktop = hasPresentedFrame
        tlsProtocol = report.tlsProtocol ?? tlsProtocol
        detachChannels()
        liveSession = nil
        stopTicking()
        // A refused certificate already decided the phase; its cancellation is not an end.
        if case .awaitingCertificateDecision = phase {
            render()
            return
        }
        switch SessionEndMapping.outcome(for: report, host: address.host, showedDesktop: wasShowingDesktop) {
        case let .promptForCredentials(message):
            password = ""
            didAskForCredentials = false
            let account = CredentialPlan.plan(for: settings.credential, connectionID: connectionID, profiles: profiles)
            let saveTo: SecretAccount? = switch account {
            case let .keychain(_, _, account): account
            case let .prompt(_, _, account): account
            }
            askForCredentials(username: username, domain: domain, message: message, saveTo: saveTo)
        case let .end(end):
            if end.category == .authentication {
                password = ""
                didAskForCredentials = false
            }
            switch reconnectPolicy.decision(
                after: end,
                wasShowingDesktop: wasShowingDesktop || reconnectCount > 0,
                attemptsMade: reconnectCount,
                enabled: settings.autoReconnect
            ) {
            case let .reconnect(attempt, delay):
                reconnectCount = attempt
                phase = .reconnecting(attempt: attempt, of: reconnectPolicy.maxAttempts)
                reconnectTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard Task.isCancelled == false else { return }
                    self?.startAttempt()
                }
            case .stop:
                phase = .ended(end)
            }
        }
        render()
    }

    // MARK: - Display

    private func scheduleResize() {
        resizeTask?.cancel()
        guard case .matchWindow = settings.display,
              let viewerSurface, displayControl != nil,
              serverMonitorCount < 2 // A multi-monitor layout is the server's; leave it.
        else { return }
        let request = RDPDisplayRequest(pointSize: viewerSurface.size, backingScaleFactor: viewerSurface.scale)
        guard request != lastSentDisplayRequest else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard Task.isCancelled == false, let self, let control = displayControl else { return }
            if control.send(request) {
                lastSentDisplayRequest = request
            }
        }
    }

    // MARK: - Housekeeping

    private func render() {
        canvas.update(frame: frameMetadata, showsDesktop: hasPresentedFrame && phase.isActive, inputSession: inputSession)
        framePresenter.isPacing = liveSession != nil
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                guard let self, Task.isCancelled == false else { return }
                clipboard?.poll()
                refreshStatistics()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func refreshStatistics() {
        if let snapshot = liveSession?.liveReport.snapshot, hasPresentedFrame == false {
            connectionStage = snapshot.stage
            if case .connecting = phase, let attempt = snapshot.connectAttempt, attempt > 1 {
                phase = .connecting(detail: "Trying again (\(attempt)/3)…")
            }
        }
        let metrics = metricsStore.metrics
        let now = Date()
        statistics = SessionStatistics(
            framesPerSecond: metrics.rollingFramesPerSecond(at: now),
            wireMegabitsPerSecond: metrics.rollingWireMegabitsPerSecond(at: now),
            averageDecodeMilliseconds: metrics.averageDecodeMilliseconds,
            hardwareDecoding: metrics.usesHardwareAcceleration,
            codec: latestFrame.map { RDPFrameMetadata($0).codecName },
            decodedFrames: metrics.decodedFrameCount,
            failedDecodes: metrics.failedDecodeCount,
            firstFrameMilliseconds: metrics.firstFrameLatencyMilliseconds
        )
    }

    private func cancelPendingWork() {
        reconnectTask?.cancel()
        reconnectTask = nil
        credentialTask?.cancel()
        credentialTask = nil
    }

    private func endLiveSession() {
        liveSession?.cancel()
        liveSession = nil
        detachChannels()
        stopTicking()
        framePresenter.clear()
        hasPresentedFrame = false
        render()
    }

    private func detachChannels() {
        resizeTask?.cancel()
        inputSession = nil
        displayControl = nil
        lastSentDisplayRequest = nil
        clipboard?.detach()
        clipboard = nil
        audioPlayer.reset()
        connectedAt = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
