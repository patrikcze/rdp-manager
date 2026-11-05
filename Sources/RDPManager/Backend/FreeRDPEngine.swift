import AppKit
import CryptoKit
import FreeRDPBridge
import RDPKit
import RDPKitAppKit
import RDPManagerCore
import Security

/// The FreeRDP 3 engine: Kerberos, Standard RDP Security, and printer, smart card (YubiKey),
/// microphone and USB redirection. Software rendering through FreeRDP's GDI.
@MainActor
final class FreeRDPEngine: SessionEngine {
    let kind = RDPEngineKind.freeRDP
    weak var delegate: SessionEngineDelegate?

    private let canvas = FreeRDPCanvas()
    private let trustStore: CertificateTrustStore
    private var connection: FreeRDPConnection?
    private var request: EngineConnectRequest?
    private var showedDesktop = false
    private var certificateRefused = false
    private var viewerSurface: (size: CGSize, scale: CGFloat)?
    private var lastSentSize: (UInt32, UInt32, UInt32)?
    private var resizeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var clipboardEnabled = false
    private var pasteboardChangeCount = NSPasteboard.general.changeCount

    init(trustStore: CertificateTrustStore, sendsCommandShortcutsToRemote: Bool) {
        self.trustStore = trustStore
        canvas.claimsCommandShortcuts = sendsCommandShortcutsToRemote
        canvas.input = { [weak self] in self?.connection?.isConnected == true ? self?.connection : nil }
        canvas.onSurfaceChange = { [weak self] size, scale in
            self?.viewerSurface = (size, scale)
            self?.scheduleResize()
        }
    }

    var surface: NSView { canvas }
    var hasInputFocus: Bool { canvas.window?.firstResponder === canvas }

    // MARK: - SessionEngine

    func start(_ request: EngineConnectRequest) {
        stop()
        self.request = request
        showedDesktop = false
        certificateRefused = false
        clipboardEnabled = request.clipboardEnabled
        lastSentSize = nil

        let scale = canvas.backingScale
        let points = canvas.initialPointSize
        let size: (width: UInt32, height: UInt32, desktopScale: UInt32, deviceScale: UInt32)
        switch request.settings.display {
        case let .fixed(width, height):
            size = (UInt32(width), UInt32(height), 100, 100)
        case .matchWindow:
            let displayRequest = RDPDisplayRequest(pointSize: points, backingScaleFactor: scale)
            size = (displayRequest.width, displayRequest.height,
                    displayRequest.scaleFactors.desktopScaleFactor, displayRequest.scaleFactors.deviceScaleFactor)
        }
        let connection = FreeRDPConnection(engine: self, trustStore: trustStore, host: request.address.host, port: request.address.port)
        self.connection = connection
        let started = connection.start(FreeRDPConnection.Options(
            request: request,
            width: size.width, height: size.height,
            desktopScale: size.desktopScale, deviceScale: size.deviceScale,
            keyboardLayout: RDPMacKeyboardLayout.current().layout.rawValue,
            clientName: Host.current().localizedName ?? "RDP Manager"
        ))
        if started == false {
            self.connection = nil
            delegate?.engine(ended: .end(SessionEnd(kind: .failed, category: .client, title: "Invalid settings",
                                                    message: "FreeRDP rejected the connection settings.")),
                             showedDesktop: false)
            return
        }
        startTicking()
    }

    func stop() {
        resizeTask?.cancel()
        stopTicking()
        connection?.cancel()
        connection = nil
        canvas.clear()
    }

    func focusInput() {
        canvas.window?.makeFirstResponder(canvas)
    }

    func sendKeyChord(_ keys: [RemoteScancode]) {
        connection?.sendChord(keys)
    }

    func sendText(_ text: String) {
        connection?.sendText(text)
    }

    func setClipboardEnabled(_ enabled: Bool) {
        clipboardEnabled = enabled
        // The bridge forgets the offered Mac text and refuses later requests when it's off.
        connection?.setClipboardShared(enabled)
        if enabled {
            pasteboardChangeCount = -1 // offer what is on the pasteboard now
        }
    }

    func waitUntilEnded(timeout: TimeInterval) async {
        await connection?.waitUntilEnded(timeout: timeout)
    }

    // MARK: - Events from the connection (main actor)

    fileprivate func connected(width: Int, height: Int, selectedProtocol: UInt32, from source: FreeRDPConnection) {
        guard source === connection else { return }
        // CredSSP (2) or CredSSP with Early User Authorization (8): the password was checked.
        delegate?.engineActivated(credentialsVerified: selectedProtocol & 0x0A != 0)
        if selectedProtocol == 0 {
            delegate?.engine(receivedCertificateSHA256: nil, trustedBySystem: nil, trustedByUser: false)
        }
        _ = (width, height)
    }

    fileprivate func showFrame(_ image: CGImage, from source: FreeRDPConnection) {
        guard source === connection else { return }
        canvas.show(image)
        let first = showedDesktop == false
        if first {
            showedDesktop = true
            focusInput()
        }
        if first || lastShownSize != CGSize(width: image.width, height: image.height) {
            lastShownSize = CGSize(width: image.width, height: image.height)
            delegate?.engine(showedDesktopOfSize: lastShownSize, firstFrame: first)
        }
    }

    private var lastShownSize = CGSize.zero

    fileprivate func setCursor(_ cursor: NSCursor, from source: FreeRDPConnection) {
        guard source === connection else { return }
        canvas.setRemoteCursor(cursor)
    }

    fileprivate func certificate(sha256: String?, trustedBySystem: Bool, refusal: RDPServerCertificateRefusal?, host: String,
                                 from source: FreeRDPConnection) {
        guard source === connection, let request else { return }
        delegate?.engine(
            receivedCertificateSHA256: sha256,
            trustedBySystem: trustedBySystem,
            trustedByUser: trustStore.trusted.isTrusted(host: host, port: request.address.port, sha256: sha256)
        )
        guard let refusal else { return }
        certificateRefused = true
        delegate?.engine(refusedCertificate: CertificateIssue(
            kind: refusal == .changed ? .changed : .untrusted,
            host: host,
            port: request.address.port,
            sha256: sha256,
            systemTrustDetail: trustedBySystem ? nil : "macOS does not trust this certificate's issuer."
        ))
    }

    fileprivate func remoteClipboardText(_ text: String, from source: FreeRDPConnection) {
        guard source === connection, clipboardEnabled else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboardChangeCount = pasteboard.changeCount // not echoed back
    }

    fileprivate func ended(errorName: String, errorInfo: UInt32, errorInfoText: String, desktopTooLarge: Bool,
                           from source: FreeRDPConnection) {
        guard source === connection, let request else { return }
        connection = nil
        stopTicking()
        // A refused certificate already reported; the cancel it caused is not an end.
        guard certificateRefused == false else { return }
        let outcome = desktopTooLarge
            ? FreeRDPEndMapping.desktopTooLarge(host: request.address.host)
            : FreeRDPEndMapping.outcome(
                errorName: errorName, errorInfo: errorInfo, errorInfoText: errorInfoText,
                showedDesktop: showedDesktop, host: request.address.host, security: request.settings.security
            )
        delegate?.engine(ended: outcome, showedDesktop: showedDesktop)
    }

    // MARK: - Display

    private func scheduleResize() {
        resizeTask?.cancel()
        guard case .matchWindow = request?.settings.display, let viewerSurface, showedDesktop else { return }
        let displayRequest = RDPDisplayRequest(pointSize: viewerSurface.size, backingScaleFactor: viewerSurface.scale)
        let next = (displayRequest.width, displayRequest.height, displayRequest.scaleFactors.desktopScaleFactor)
        if let last = lastSentSize, last == next { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard Task.isCancelled == false, let self, let connection else { return }
            if connection.resize(width: next.0, height: next.1, desktopScale: next.2,
                                 deviceScale: displayRequest.scaleFactors.deviceScaleFactor) {
                lastSentSize = next
            }
        }
    }

    // MARK: - Ticks: statistics and clipboard

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                guard let self, Task.isCancelled == false else { return }
                tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        guard let connection else { return }
        if clipboardEnabled, request?.settings.clipboardEnabled == true {
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != pasteboardChangeCount {
                pasteboardChangeCount = pasteboard.changeCount
                if let text = pasteboard.string(forType: .string) {
                    connection.setLocalClipboardText(text)
                }
            }
        }
        let counts = connection.takeFrameCounts()
        delegate?.engine(
            updatedStatistics: SessionStatistics(
                framesPerSecond: showedDesktop ? Double(counts.updates) : nil,
                wireMegabitsPerSecond: nil,
                averageDecodeMilliseconds: nil,
                hardwareDecoding: false, // FreeRDP's GDI decodes in software in this build
                codec: nil,
                decodedFrames: counts.total,
                failedDecodes: 0,
                firstFrameMilliseconds: connection.firstFrameMilliseconds
            ),
            tlsProtocol: nil,
            connectAttempt: nil
        )
        if showedDesktop, lastSentSize == nil {
            scheduleResize() // Display Control is ready once the desktop shows.
        }
    }
}

/// One FreeRDP connection attempt: owns the C session, runs it on a thread of its own and
/// hands its events to the engine on the main queue. C callbacks reach it through an opaque
/// pointer; everything they touch is lock-protected.
final class FreeRDPConnection: @unchecked Sendable {
    struct Options {
        var request: EngineConnectRequest
        var width: UInt32
        var height: UInt32
        var desktopScale: UInt32
        var deviceScale: UInt32
        var keyboardLayout: UInt32
        var clientName: String
    }

    private weak var engine: FreeRDPEngine?
    private let trustStore: CertificateTrustStore
    private let host: String
    private let port: UInt16
    private let lock = NSLock()
    private var session: OpaquePointer?
    private var connectedFlag = false
    private var ended = false
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    // Framebuffer copy, BGRA, written on the session thread, turned into images on main.
    private var pixels: UnsafeMutableRawPointer?
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var displayScheduled = false
    private var updates = 0
    private var totalUpdates = 0
    private let startedAt = Date()
    private var firstFrameAt: Date?

    init(engine: FreeRDPEngine, trustStore: CertificateTrustStore, host: String, port: UInt16) {
        self.engine = engine
        self.trustStore = trustStore
        self.host = host
        self.port = port
    }

    deinit {
        pixels?.deallocate()
    }

    var isConnected: Bool { lock.withLock { connectedFlag } }

    var firstFrameMilliseconds: Double? {
        lock.withLock { firstFrameAt.map { $0.timeIntervalSince(startedAt) * 1000 } }
    }

    func takeFrameCounts() -> (updates: Int, total: Int) {
        lock.withLock {
            defer { updates = 0 }
            return (updates, totalUpdates)
        }
    }

    // MARK: - Lifecycle

    /// Creates the C session and starts its thread. The connection keeps itself alive until
    /// the session ends.
    func start(_ options: Options) -> Bool {
        let request = options.request
        let settings = request.settings
        var callbacks = rm_callbacks()
        let retained = Unmanaged.passRetained(self)
        callbacks.context = retained.toOpaque()
        callbacks.on_frame = { context, pixels, width, height, stride, x, y, w, h in
            FreeRDPConnection.from(context).frame(pixels, Int(width), Int(height), Int(stride), Int(x), Int(y), Int(w), Int(h))
        }
        callbacks.on_connected = { context, width, height, selected in
            FreeRDPConnection.from(context).connected(Int(width), Int(height), selected)
        }
        callbacks.on_certificate = { context, host, port, _, _, pem, _ in
            FreeRDPConnection.from(context).verify(host: host.map { String(cString: $0) }, pem: pem.map { String(cString: $0) })
        }
        callbacks.on_pointer = { context, pixels, width, height, hotX, hotY, hidden in
            FreeRDPConnection.from(context).pointer(pixels, Int(width), Int(height), Int(hotX), Int(hotY), hidden)
        }
        callbacks.on_remote_clipboard_text = { context, text in
            guard let text else { return }
            FreeRDPConnection.from(context).remoteClipboard(String(cString: text))
        }
        callbacks.on_ended = { context, lastError, errorInfo, failure in
            FreeRDPConnection.from(context).sessionEnded(lastError, errorInfo, desktopTooLarge: failure == RM_FAILURE_DESKTOP_TOO_LARGE)
        }

        let usb = settings.usbDevices.joined(separator: "#")
        let session: OpaquePointer? = withCStrings([
            request.address.host, request.username, request.domain, request.password, options.clientName,
            settings.kerberosKDCProxyURL ?? "", usb, settings.sharedFolderPath == nil ? "" : "Mac",
            settings.sharedFolderPath ?? "",
        ]) { strings in
            var config = rm_config()
            config.host = strings[0]
            config.port = request.address.port
            config.username = strings[1]
            config.domain = strings[2]
            config.password = strings[3]
            config.client_name = strings[4]
            config.kerberos_kdc_url = strings[5]
            config.usb_devices = strings[6]
            config.drive_name = strings[7]
            config.drive_path = strings[8]
            config.width = options.width
            config.height = options.height
            config.desktop_scale = options.desktopScale
            config.device_scale = options.deviceScale
            config.keyboard_layout = options.keyboardLayout
            config.timeout_ms = UInt32(settings.timeoutSeconds * 1000)
            config.security = switch settings.security {
            case .automatic: RM_SECURITY_AUTO
            case .nla: RM_SECURITY_NLA
            case .tls: RM_SECURITY_TLS
            case .standardRDP: RM_SECURITY_RDP
            }
            config.auth_package = switch settings.authentication {
            case .ntlm: RM_AUTH_NTLM
            case .kerberos: RM_AUTH_NEGOTIATE
            case .kerberosOnly: RM_AUTH_KERBEROS
            }
            config.clipboard = settings.clipboardEnabled
            config.audio_playback = settings.audioPlaybackEnabled
            config.microphone = settings.microphoneEnabled
            config.printers = settings.printersEnabled
            config.smartcards = settings.smartCardsEnabled
            return rm_session_new(&config, &callbacks)
        }
        guard let session else {
            retained.release()
            return false
        }
        // The channel exists when the settings allow it; the live switch decides what flows.
        rm_session_set_clipboard_shared(session, settings.clipboardEnabled && request.clipboardEnabled)
        // In automatic mode Standard RDP Security is never offered: it must be chosen.
        lock.withLock { self.session = session }
        // Handed to the session thread, which alone frees it after the run returns.
        nonisolated(unsafe) let handle = session
        let thread = Thread {
            rm_session_run(handle)
            // on_ended has run; nothing calls into the session after this.
            self.lock.withLock { self.session = nil }
            rm_session_free(handle)
            retained.release()
        }
        thread.name = "FreeRDP session \(request.address.host)"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func cancel() {
        lock.withLock {
            engine = nil
            connectedFlag = false
            if let session { rm_session_cancel(session) }
        }
    }

    func waitUntilEnded(timeout: TimeInterval) async {
        if lock.withLock({ ended }) { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let alreadyEnded = self.lock.withLock {
                        if self.ended { return true }
                        self.endWaiters.append(continuation)
                        return false
                    }
                    if alreadyEnded { continuation.resume() }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Input (any thread)

    private func withSession(_ body: (OpaquePointer) -> Void) {
        lock.withLock {
            guard connectedFlag, let session else { return }
            body(session)
        }
    }

    func sendMacKey(_ keyCode: UInt16, down: Bool) {
        withSession { rm_session_send_mac_key($0, keyCode, down) }
    }

    func sendChord(_ keys: [RemoteScancode]) {
        withSession { session in
            for key in keys { rm_session_send_scancode(session, key.code, key.extended, true) }
            for key in keys.reversed() { rm_session_send_scancode(session, key.code, key.extended, false) }
        }
    }

    func sendText(_ text: String) {
        withSession { session in
            for unit in text.utf16 {
                rm_session_send_unicode(session, unit, true)
                rm_session_send_unicode(session, unit, false)
            }
        }
    }

    func sendPointer(flags: UInt16, x: UInt16, y: UInt16) {
        withSession { rm_session_send_pointer($0, flags, x, y) }
    }

    func resize(width: UInt32, height: UInt32, desktopScale: UInt32, deviceScale: UInt32) -> Bool {
        var sent = false
        withSession { sent = rm_session_resize($0, width, height, desktopScale, deviceScale) }
        return sent
    }

    func setLocalClipboardText(_ text: String) {
        withSession { session in text.withCString { rm_session_set_local_clipboard_text(session, $0) } }
    }

    /// Unlike input, also before the desktop shows: the switch must hold from the start.
    func setClipboardShared(_ shared: Bool) {
        lock.withLock {
            guard let session else { return }
            rm_session_set_clipboard_shared(session, shared)
        }
    }

    // MARK: - Callbacks (session thread)

    private static func from(_ context: UnsafeMutableRawPointer?) -> FreeRDPConnection {
        Unmanaged<FreeRDPConnection>.fromOpaque(context!).takeUnretainedValue()
    }

    private func deliver(_ work: @escaping @MainActor (FreeRDPEngine, FreeRDPConnection) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let engine = self.lock.withLock({ self.engine }) else { return }
            work(engine, self)
        }
    }

    private func connected(_ width: Int, _ height: Int, _ selectedProtocol: UInt32) {
        lock.withLock { connectedFlag = true }
        deliver { engine, source in engine.connected(width: width, height: height, selectedProtocol: selectedProtocol, from: source) }
    }

    private func frame(_ source: UnsafePointer<UInt8>?, _ width: Int, _ height: Int, _ stride: Int,
                       _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        // The bridge bounds the size before FreeRDP allocates; this keeps the copy bounded even
        // if that ever changes.
        guard let source, let byteCount = Self.frameByteCount(width: width, height: height), stride >= width * 4 else { return }
        let schedule: Bool = lock.withLock {
            if width != pixelWidth || height != pixelHeight || pixels == nil {
                pixels?.deallocate()
                pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
                pixelWidth = width
                pixelHeight = height
                copy(from: source, stride: stride, x: 0, y: 0, w: width, h: height)
            } else {
                let x0 = max(0, x), y0 = max(0, y)
                copy(from: source, stride: stride, x: x0, y: y0, w: min(w, width - x0), h: min(h, height - y0))
            }
            updates += 1
            totalUpdates += 1
            if firstFrameAt == nil { firstFrameAt = Date() }
            defer { displayScheduled = true }
            return displayScheduled == false
        }
        guard schedule else { return }
        // Coalesce: one image per main-queue turn, whatever arrived meanwhile.
        DispatchQueue.main.async { [weak self] in
            guard let self, let image = makeImage(), let engine = lock.withLock({ self.engine }) else { return }
            engine.showFrame(image, from: self)
        }
    }

    /// BGRA bytes for a frame of this size, or nil when the size is outside the bridge's limits.
    static func frameByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0, width <= Int(RM_MAX_DESKTOP_SIDE), height <= Int(RM_MAX_DESKTOP_SIDE) else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard overflow == false, pixels <= Int(RM_MAX_DESKTOP_PIXELS) else { return nil }
        return pixels * 4
    }

    /// Under `lock`.
    private func copy(from source: UnsafePointer<UInt8>, stride: Int, x: Int, y: Int, w: Int, h: Int) {
        guard let pixels, w > 0, h > 0 else { return }
        let rowBytes = pixelWidth * 4
        for row in y ..< y + h {
            (pixels + row * rowBytes + x * 4).copyMemory(from: source + row * stride + x * 4, byteCount: w * 4)
        }
    }

    private func makeImage() -> CGImage? {
        lock.withLock {
            displayScheduled = false
            guard let pixels, let byteCount = Self.frameByteCount(width: pixelWidth, height: pixelHeight),
                  let data = CFDataCreate(nil, pixels.assumingMemoryBound(to: UInt8.self), byteCount),
                  let provider = CGDataProvider(data: data),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGImage(
                width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixelWidth * 4,
                space: space,
                // BGRA in memory, alpha ignored: the desktop is opaque.
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
    }

    private func pointer(_ source: UnsafePointer<UInt8>?, _ width: Int, _ height: Int, _ hotX: Int, _ hotY: Int, _ hidden: Bool) {
        let cursor: NSCursor
        if hidden {
            cursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
        } else if let source, width > 0, height > 0,
                  let data = CFDataCreate(nil, source, width * height * 4),
                  let provider = CGDataProvider(data: data),
                  let image = CGImage(
                      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                  ) {
            // Remote pixels are device pixels; on Retina the cursor shows at their point size.
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
            cursor = NSCursor(image: NSImage(cgImage: image, size: size),
                              hotSpot: NSPoint(x: CGFloat(hotX) / scale, y: CGFloat(hotY) / scale))
        } else {
            cursor = .arrow
        }
        deliver { engine, source in engine.setCursor(cursor, from: source) }
    }

    private func remoteClipboard(_ text: String) {
        deliver { engine, source in engine.remoteClipboardText(text, from: source) }
    }

    /// Decides on the server's certificate during TLS, before any credential is sent: macOS
    /// trust first, then the certificates the user trusted. Anything else is refused and the
    /// user is asked.
    private func verify(host: String?, pem: String?) -> rm_cert_decision {
        let host = host ?? self.host
        // FreeRDP sends the leaf followed by the chain the server presented.
        let ders = pem.map(Self.certificates(fromPEM:)) ?? []
        let certificates = ders.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard let leaf = ders.first, certificates.count == ders.count, certificates.isEmpty == false else {
            return RM_CERT_REJECT
        }
        let sha256 = SHA256.hash(data: leaf).map { String(format: "%02x", $0) }.joined(separator: ":")
        var trust: SecTrust?
        var systemTrusted = false
        if SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
           let trust {
            systemTrusted = SecTrustEvaluateWithError(trust, nil)
        }
        let info = RDPServerCertificateInfo(trusted: systemTrusted, sha256: sha256, warnings: [], host: host)
        let refusal = trustStore.refusal(of: info, port: port)
        deliver { engine, source in
            engine.certificate(sha256: sha256, trustedBySystem: systemTrusted, refusal: refusal, host: host, from: source)
        }
        return refusal == nil ? RM_CERT_ACCEPT_ONCE : RM_CERT_REJECT
    }

    /// Every certificate in `pem`, in order, as DER.
    static func certificates(fromPEM pem: String) -> [Data] {
        var result: [Data] = []
        var body = ""
        var inside = false
        for line in pem.components(separatedBy: .newlines) {
            if line.hasPrefix("-----BEGIN") {
                inside = true
                body = ""
            } else if line.hasPrefix("-----END") {
                if inside, let der = Data(base64Encoded: body) { result.append(der) }
                inside = false
            } else if inside {
                body += line.trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    private func sessionEnded(_ lastError: UInt32, _ errorInfo: UInt32, desktopTooLarge: Bool) {
        let name = String(cString: rm_error_name(lastError))
        let infoText = String(cString: rm_error_info_string(errorInfo))
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            connectedFlag = false
            ended = true
            defer { endWaiters = [] }
            return endWaiters
        }
        waiters.forEach { $0.resume() }
        deliver { engine, source in
            engine.ended(errorName: name, errorInfo: errorInfo, errorInfoText: infoText, desktopTooLarge: desktopTooLarge, from: source)
        }
    }
}

/// Calls `body` with C strings that stay valid for the call.
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafePointer<CChar>]) -> R) -> R {
    let duplicated = strings.map { strdup($0)! }
    defer { duplicated.forEach { free($0) } }
    return body(duplicated.map { UnsafePointer($0) })
}
