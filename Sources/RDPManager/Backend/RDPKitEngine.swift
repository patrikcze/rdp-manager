import AppKit
import RDPKit
import RDPKitAppKit
import RDPManagerCore

/// The RDPKit engine: pure Swift, hardware H.264 through VideoToolbox, NLA with NTLM.
/// Integration patterns follow RDPeek's session controller (MIT, © 2026 Anees Iqbal).
@MainActor
final class RDPKitEngine: SessionEngine {
    let kind = RDPEngineKind.rdpKit
    weak var delegate: SessionEngineDelegate?

    private let canvas = RemoteDesktopCanvas()
    private lazy var framePresenter = RDPFramePresenter(videoView: canvas.videoView)
    private let trustStore: CertificateTrustStore

    private var request: EngineConnectRequest?
    private var liveSession: RDPLiveSession?
    private var inputSession: RDPInputSession?
    private var displayControl: RDPDisplayControlSession?
    private var serverMonitorCount = 0
    private var lastSentDisplayRequest: RDPDisplayRequest?
    private var viewerSurface: (size: CGSize, scale: CGFloat)?
    private var resizeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var clipboard: RDPPasteboardClipboard?
    private let audioPlayer = RDPAudioPlayer()
    private let metricsStore = RDPRenderMetricsStore()
    private var latestFrame: RDPGraphicsFrameSnapshot?
    private var frameMetadata: RDPFrameMetadata?
    private var hasPresentedFrame = false
    private var tlsProtocol: String?
    private var certificateRefused = false

    init(trustStore: CertificateTrustStore, sendsCommandShortcutsToRemote: Bool) {
        self.trustStore = trustStore
        canvas.claimsCommandShortcuts = sendsCommandShortcutsToRemote
        canvas.onSurfaceChange = { [weak self] size, scale in
            self?.viewerSurface = (size, scale)
            self?.scheduleResize()
        }
        canvas.onCtrlAltEnd = { [weak self] in
            self?.sendKeyChord([.control, .alt, .delete])
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

    var surface: NSView { canvas }
    var hasInputFocus: Bool { canvas.hasInputFocus }

    // MARK: - SessionEngine

    func start(_ request: EngineConnectRequest) {
        stop()
        self.request = request
        let configuration: RDPConnectionConfiguration
        do {
            configuration = try makeConfiguration(request)
        } catch {
            delegate?.engine(ended: .end(SessionEnd(kind: .failed, category: .client, title: "Invalid settings", message: "\(error)")),
                             showedDesktop: false)
            return
        }
        hasPresentedFrame = false
        frameMetadata = nil
        latestFrame = nil
        tlsProtocol = nil
        certificateRefused = false
        metricsStore.reset(connectionStartedAt: Date())
        if configuration.clipboardEnabled {
            clipboard = RDPPasteboardClipboard(
                isSharingEnabled: request.clipboardEnabled,
                downloadRoot: FileManager.default.temporaryDirectory.appending(path: "RDP Manager Clipboard"),
                quarantineAgentName: "RDP Manager"
            )
        }
        let session = RDPLiveSession(threadName: "RDP session \(request.address.host)")
        liveSession = session
        run(session, configuration: configuration)
        startTicking()
        render()
    }

    func stop() {
        liveSession?.cancel()
        liveSession = nil
        detachChannels()
        stopTicking()
        framePresenter.clear()
        hasPresentedFrame = false
        render()
    }

    func focusInput() {
        canvas.makeInputFirstResponder()
    }

    func sendKeyChord(_ keys: [RemoteScancode]) {
        guard let inputSession else { return }
        let scancodes = keys.map { RDPKeyboardScancode(code: $0.code, isExtended: $0.extended) }
        let down = scancodes.map { RDPSlowPathInputEvent.keyboard(scancode: $0, isReleased: false) }
        let up = scancodes.reversed().map { RDPSlowPathInputEvent.keyboard(scancode: $0, isReleased: true) }
        inputSession.send(down + up)
    }

    func sendText(_ text: String) {
        guard let inputSession, inputSession.supportsUnicodeInput else { return }
        for unit in text.utf16 {
            inputSession.send([.unicode(codeUnit: unit, isReleased: false), .unicode(codeUnit: unit, isReleased: true)])
        }
    }

    func setClipboardEnabled(_ enabled: Bool) {
        clipboard?.setSharingEnabled(enabled)
    }

    func waitUntilEnded(timeout: TimeInterval) async {
        guard let liveSession else { return }
        _ = await liveSession.waitUntilEnded(timeout: timeout)
    }

    // MARK: - Connecting

    private func makeConfiguration(_ request: EngineConnectRequest) throws -> RDPConnectionConfiguration {
        let target = try RDPConnectionTarget(host: request.address.host, port: request.address.port)
        let credentials = request.username.isEmpty && request.password.isEmpty
            ? nil
            : try RDPCredentials.validated(username: request.username, domain: request.domain, password: request.password)
        let desktopSize: RDPDesktopSize
        switch request.settings.display {
        case let .fixed(width, height):
            desktopSize = try RDPDesktopSize(width: UInt16(clamping: width), height: UInt16(clamping: height))
        case .matchWindow:
            // Start at the view's size in points at 100%; Display Control switches to full
            // Retina pixels and the right scale once its channel opens.
            desktopSize = RDPDesktopSize(RDPDisplayRequest(pointSize: canvas.initialPointSize, backingScaleFactor: 1))
        }
        let keyboard = RDPMacKeyboardLayout.current()
        canvas.keyboard = keyboard
        var configuration = RDPConnectionConfiguration(
            target: target,
            credentials: credentials,
            timeoutSeconds: request.settings.timeoutSeconds,
            // Certificate warnings are never hidden: the trust decision is the user's.
            hideCertificateWarnings: false,
            graphicsFrameCaptureLimit: nil,
            desktopSize: desktopSize,
            // Not joining the channel at all when the policy says no: Windows empties its
            // clipboard on join, and nothing can cross.
            clipboardEnabled: request.settings.clipboardEnabled,
            clipboardFetchesRemoteCopies: false,
            audioPlaybackEnabled: request.settings.audioPlaybackEnabled,
            graphicsCapabilityProfile: .automatic,
            legacyRSAKeyExchange: .fallback,
            legacyCredSSP: false,
            sharedDrives: request.settings.sharedFolderPath.map {
                [RDPSharedDrive(name: "Mac", url: URL(fileURLWithPath: $0))]
            } ?? [],
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
                    recipient.deliver { engine in engine.finish(report) }
                }
            )
        ) { run in
            RDPSessionClient().run(
                configuration: configuration,
                onGraphicsFrame: run.onGraphicsFrame,
                onInputReady: { input in
                    recipient.deliver { engine in engine.activated(input) }
                },
                onDisplayControlReady: { control in
                    recipient.deliver { engine in engine.displayControlReady(control) }
                },
                onClipboardReady: { clipboard in
                    recipient.deliver { engine in engine.clipboard?.attach(clipboard) }
                },
                onClipboardText: { text, copyNumber in
                    recipient.deliver { engine in engine.clipboard?.receiveText(text, copyNumber: copyNumber) }
                },
                onClipboardFileGroupDescriptor: { list, copyNumber in
                    recipient.deliver { engine in engine.clipboard?.receiveFileList(list, copyNumber: copyNumber) }
                },
                onClipboardRemoteCopyUnavailable: { isEmpty, copyNumber in
                    recipient.deliver { engine in
                        engine.clipboard?.receiveRemoteCopyUnavailable(isEmpty: isEmpty, copyNumber: copyNumber)
                    }
                },
                onAudioSample: { sample in
                    recipient.deliver { engine in engine.play(sample) }
                },
                audioPlaybackDelay: { audioPlayer.playbackDelay },
                onCertificate: { info in
                    // Runs during TLS, before any credential is sent: refusing here means the
                    // server never sees the password.
                    let refusal = trustStore.refusal(of: info, port: port)
                    if refusal != nil {
                        run.cancellation.cancel()
                    }
                    recipient.deliver { engine in engine.received(info, refusal: refusal) }
                },
                onWireReceive: run.onWireReceive,
                liveReport: run.liveReport,
                cancellation: run.cancellation
            )
        }
    }

    // MARK: - Engine events (main actor, in order)

    private func received(_ info: RDPServerCertificateInfo, refusal: RDPServerCertificateRefusal?) {
        guard let request else { return }
        delegate?.engine(
            receivedCertificateSHA256: info.sha256,
            trustedBySystem: info.trusted,
            trustedByUser: trustStore.trusted.isTrusted(host: info.host, port: request.address.port, sha256: info.sha256)
        )
        guard let refusal else { return }
        certificateRefused = true
        stop()
        delegate?.engine(refusedCertificate: CertificateIssue(
            kind: refusal == .changed ? .changed : .untrusted,
            host: info.host.isEmpty ? request.address.host : info.host,
            port: request.address.port,
            sha256: info.sha256,
            systemTrustDetail: info.warnings.map(\.message).joined(separator: "\n").nonEmpty
        ))
    }

    private func activated(_ input: RDPInputSession) {
        inputSession = input
        if displayControl?.isEnded == true {
            displayControl = nil
        }
        delegate?.engineActivated(credentialsVerified: input.connectionContext.credentialsVerifiedBeforeActivation)
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
        }
        let first = hasPresentedFrame == false
        if first {
            hasPresentedFrame = true
        }
        if first || sizeChanged {
            render()
            delegate?.engine(showedDesktopOfSize: CGSize(width: Int(frame.width), height: Int(frame.height)), firstFrame: first)
        }
        if first {
            canvas.makeInputFirstResponder()
        }
    }

    private func play(_ sample: RDPAudioSample) {
        guard request?.settings.audioPlaybackEnabled == true else { return }
        _ = try? audioPlayer.enqueue(sample)
    }

    private func finish(_ report: RDPConnectionReport) {
        framePresenter.flush()
        let showedDesktop = hasPresentedFrame
        tlsProtocol = report.tlsProtocol ?? tlsProtocol
        detachChannels()
        liveSession = nil
        stopTicking()
        // A refused certificate already reported; its cancellation is not an end.
        guard certificateRefused == false, let request else { return }
        let outcome: EngineEnd = switch SessionEndMapping.outcome(for: report, host: request.address.host, showedDesktop: showedDesktop) {
        case let .promptForCredentials(message): .promptForCredentials(message: message)
        case let .end(end): .end(end)
        }
        delegate?.engine(ended: outcome, showedDesktop: showedDesktop)
        render()
    }

    // MARK: - Display

    private func scheduleResize() {
        resizeTask?.cancel()
        guard case .matchWindow = request?.settings.display,
              let viewerSurface, displayControl != nil,
              serverMonitorCount < 2 // A multi-monitor layout is the server's; leave it.
        else { return }
        let displayRequest = RDPDisplayRequest(pointSize: viewerSurface.size, backingScaleFactor: viewerSurface.scale)
        guard displayRequest != lastSentDisplayRequest else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard Task.isCancelled == false, let self, let control = displayControl else { return }
            if control.send(displayRequest) {
                lastSentDisplayRequest = displayRequest
            }
        }
    }

    // MARK: - Housekeeping

    private func render() {
        canvas.update(frame: frameMetadata, showsDesktop: hasPresentedFrame, inputSession: inputSession)
        framePresenter.isPacing = liveSession != nil
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                guard let self, Task.isCancelled == false else { return }
                clipboard?.poll()
                reportStatistics()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func reportStatistics() {
        var connectAttempt: Int?
        if let snapshot = liveSession?.liveReport.snapshot {
            // Known once the handshake is done; the final report only comes when the session ends.
            tlsProtocol = snapshot.tlsProtocol ?? tlsProtocol
            if hasPresentedFrame == false {
                connectAttempt = snapshot.connectAttempt
            }
        }
        let metrics = metricsStore.metrics
        let now = Date()
        let statistics = SessionStatistics(
            framesPerSecond: metrics.rollingFramesPerSecond(at: now),
            wireMegabitsPerSecond: metrics.rollingWireMegabitsPerSecond(at: now),
            averageDecodeMilliseconds: metrics.averageDecodeMilliseconds,
            hardwareDecoding: metrics.usesHardwareAcceleration,
            codec: latestFrame.map { RDPFrameMetadata($0).codecName },
            decodedFrames: metrics.decodedFrameCount,
            failedDecodes: metrics.failedDecodeCount,
            firstFrameMilliseconds: metrics.firstFrameLatencyMilliseconds
        )
        delegate?.engine(updatedStatistics: statistics, tlsProtocol: tlsProtocol, connectAttempt: connectAttempt)
    }

    private func detachChannels() {
        resizeTask?.cancel()
        inputSession = nil
        displayControl = nil
        lastSentDisplayRequest = nil
        clipboard?.detach()
        clipboard = nil
        audioPlayer.reset()
    }
}
