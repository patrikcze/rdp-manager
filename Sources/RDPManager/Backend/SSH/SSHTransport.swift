import Darwin
import Foundation
import RDPManagerCore

/// A question OpenSSH asked through askpass, waiting for an answer.
struct AskpassRequest: Sendable {
    var prompt: String
    /// `SSH_ASKPASS_PROMPT`: "confirm", "none" or nil.
    var hint: String?
}

/// What a transport reports to its session, on the main actor, in order.
@MainActor
protocol SSHTransportDelegate: AnyObject {
    func transport(logged event: SSHLogEvent)
    /// `reply(nil)` refuses (the helper exits with an error); every request gets one reply.
    func transport(asked request: AskpassRequest, reply: @escaping @Sendable (String?) -> Void)
    /// The process ended; every log line it wrote was delivered before this.
    func transport(exitedWithStatus status: Int32?, signal: Int32?)
}

/// Where terminal output goes. Written from the transport's queue; the terminal view's feed
/// is thread-safe. Held weakly, so a closed session's view is never kept alive or fed.
final class TerminalOutputSink: @unchecked Sendable {
    nonisolated(unsafe) weak var receiver: (any TerminalOutputReceiver)?
}

protocol TerminalOutputReceiver: AnyObject {
    nonisolated func receive(_ bytes: ArraySlice<UInt8>)
}

/// The SSH transport: something that runs one SSH connection on a terminal. The app has
/// one, OpenSSH; the protocol keeps the session and the view independent of it.
@MainActor
protocol SSHTransport: AnyObject {
    var delegate: SSHTransportDelegate? { get set }
    func start(target: SSHTarget, columns: UInt16, rows: UInt16, output: TerminalOutputSink) throws
    func write(_ bytes: [UInt8])
    func resize(columns: UInt16, rows: UInt16)
    /// Hangs up. The delegate still hears the exit.
    func stop()
}

/// Runs `/usr/bin/ssh` on a PTY with its log on a FIFO and its prompts on an askpass socket,
/// all inside a private 0700 folder that is removed when the process ends.
@MainActor
final class OpenSSHProcessTransport: SSHTransport {
    weak var delegate: SSHTransportDelegate?
    /// Tests run outside an app bundle and name the built helper here.
    nonisolated(unsafe) static var helperPathOverride: String?
    private var process: PTYProcess?
    private var channels: SSHSideChannels?

    /// The bundled askpass helper: next to the app's executable (Contents/MacOS), or in the
    /// build folder during development and tests.
    static var askpassHelperPath: String? {
        if let override = helperPathOverride { return override }
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "RDPManagerAskpass"),
            Bundle.main.bundleURL.appending(path: "RDPManagerAskpass"),
            Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "RDPManagerAskpass"),
        ].compactMap(\.self)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?
            .resolvingSymlinksInPath().path
    }

    func start(target: SSHTarget, columns: UInt16, rows: UInt16, output: TerminalOutputSink) throws {
        guard let helper = Self.askpassHelperPath else {
            throw TransportError.missingHelper
        }
        let queue = DispatchQueue(label: "rdpmanager.ssh", qos: .userInteractive)
        let channels = try SSHSideChannels(helperPath: helper, queue: queue)
        self.channels = channels
        let arguments: [String]
        do {
            arguments = try SSHCommandBuilder.arguments(for: target, logPath: channels.logPath)
        } catch {
            channels.close()
            throw error
        }
        let environment = SSHCommandBuilder.environment(
            from: ProcessInfo.processInfo.environment,
            terminalType: target.settings.terminalType,
            sendEnvironment: target.settings.sendEnvironment,
            askpassHelper: helper,
            askpassSocket: channels.socketPath
        )
        let delivery = MainQueueDelivery(transport: self)
        channels.onLogLine = { line in
            guard let event = SSHLogParser.parse(line) else { return }
            delivery.deliver { $0.delegate?.transport(logged: event) }
        }
        channels.onAskpass = { request, reply in
            delivery.deliver { transport in
                guard let delegate = transport.delegate else { return reply(nil) }
                delegate.transport(asked: request, reply: reply)
            }
        }
        do {
            let process = try PTYProcess(
                .init(executable: SSHCommandBuilder.sshPath, arguments: arguments, environment: environment, columns: columns, rows: rows),
                queue: queue,
                onOutput: { bytes in output.receiver?.receive(bytes[...]) },
                onExit: { status, signal in
                    // Same queue as the log: every line is read before the exit is reported.
                    channels.finishLog()
                    channels.close()
                    delivery.deliver { $0.delegate?.transport(exitedWithStatus: status, signal: signal) }
                }
            )
            // Only now, with ssh's pid known, are its askpass connections read. One that came
            // earlier waited in the listen backlog instead of failing the peer check.
            channels.startAccepting(from: process.pid)
            self.process = process
        } catch {
            channels.close()
            throw error
        }
    }

    func write(_ bytes: [UInt8]) {
        process?.write(bytes)
    }

    func resize(columns: UInt16, rows: UInt16) {
        process?.resize(columns: columns, rows: rows)
    }

    func stop() {
        channels?.refusePendingRequests()
        process?.terminate()
    }

    enum TransportError: Error, LocalizedError {
        case missingHelper

        var errorDescription: String? {
            "The askpass helper is missing from the app. Reinstall RDP Manager."
        }
    }
}

/// Hops to the main queue in submission order (a `Task` per event would not keep order).
private final class MainQueueDelivery: @unchecked Sendable {
    nonisolated(unsafe) weak var transport: OpenSSHProcessTransport?

    init(transport: OpenSSHProcessTransport) {
        self.transport = transport
    }

    func deliver(_ body: @escaping @MainActor (OpenSSHProcessTransport) -> Void) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                if let transport { body(transport) }
            }
        }
    }
}

/// The log FIFO and askpass socket of one ssh process, in a private folder.
final class SSHSideChannels: @unchecked Sendable {
    let directory: String
    let logPath: String
    let socketPath: String
    private let helperPath: String
    private let queue: DispatchQueue
    var onLogLine: (@Sendable (String) -> Void)?
    var onAskpass: (@Sendable (AskpassRequest, @escaping @Sendable (String?) -> Void) -> Void)?
    /// The ssh process: askpass connections must come from the helper running below it.
    var trustedAncestor: pid_t {
        lock.withLock { ancestor }
    }

    private let lock = NSLock()
    private var ancestor: pid_t = 0
    private var logReader: Int32 = -1
    private var logKeepAlive: Int32 = -1
    private var logSource: DispatchSourceRead?
    private var logBuffer: [UInt8] = []
    private var listener: Int32 = -1
    private var listenSource: DispatchSourceRead?
    /// The listen source starts suspended and is resumed once, by `startAccepting(from:)`.
    private var accepting = false
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var closed = false

    static let maximumLogLine = 4096

    init(helperPath: String, queue: DispatchQueue) throws {
        self.helperPath = helperPath
        self.queue = queue
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(queue))
        var template = Array((NSTemporaryDirectory() + "rdpm-ssh.XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        directory = String(cString: created)
        chmod(directory, 0o700)
        logPath = directory + "/log"
        socketPath = directory + "/askpass"
        do {
            try openLog()
            try openSocket()
        } catch {
            close()
            throw error
        }
    }

    // MARK: Log

    private func openLog() throws {
        guard mkfifo(logPath, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        logReader = open(logPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        // A writer of our own keeps the FIFO from reading EOF before ssh opens it.
        logKeepAlive = open(logPath, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        guard logReader >= 0, logKeepAlive >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let source = DispatchSource.makeReadSource(fileDescriptor: logReader, queue: queue)
        let reader = logReader
        source.setEventHandler { [weak self] in self?.readLog() }
        source.setCancelHandler { Darwin.close(reader) }
        source.resume()
        logSource = source
    }

    private func readLog() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(logReader, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            for byte in buffer[0 ..< count] {
                if byte == 0x0A {
                    emitLogLine()
                } else if logBuffer.count < Self.maximumLogLine {
                    logBuffer.append(byte)
                }
            }
        }
    }

    private func emitLogLine() {
        let line = String(decoding: logBuffer, as: UTF8.self)
        logBuffer.removeAll(keepingCapacity: true)
        onLogLine?(line)
    }

    /// Reads what is left after the process exited. Runs on the queue.
    func finishLog() {
        guard logSource != nil else { return }
        readLog()
        if logBuffer.isEmpty == false { emitLogLine() }
    }

    // MARK: Askpass

    private func openSocket() throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 4) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        let fd = listener
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { Darwin.close(fd) }
        // Not resumed yet: until ssh's pid is known no connection could pass the peer check.
        listenSource = source
    }

    /// Starts reading askpass connections, which must come from the helper below `ancestor`.
    /// Connections made before this wait in the backlog.
    func startAccepting(from ancestor: pid_t) {
        lock.withLock { self.ancestor = ancestor }
        queue.async { [self] in
            guard closed == false, accepting == false, let listenSource else { return }
            accepting = true
            listenSource.resume()
        }
    }

    private func accept() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            Self.prepareAccepted(client)
            guard AskpassPeer.isTrusted(client, helperPath: helperPath, ancestor: trustedAncestor) else {
                Darwin.close(client)
                continue
            }
            guard let hint = readField(client), let prompt = readField(client) else {
                Darwin.close(client)
                continue
            }
            // Watch for the helper going away (ssh killed it) while the user decides.
            let watch = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            watch.setEventHandler { [weak self] in
                var probe: UInt8 = 0
                if recv(client, &probe, 1, MSG_PEEK | MSG_DONTWAIT) == 0 { self?.finish(client, answer: nil) }
            }
            watch.setCancelHandler { Darwin.close(client) }
            clients[client] = watch
            watch.resume()
            let request = AskpassRequest(prompt: prompt, hint: hint.isEmpty ? nil : hint)
            onAskpass?(request) { [weak self] answer in
                self?.queue.async { self?.finish(client, answer: answer) }
            }
        }
    }

    /// An accepted socket inherits the listener's O_NONBLOCK on macOS. The helper may connect a
    /// moment before it writes its question; a non-blocking read then failed with EAGAIN, the
    /// connection was dropped and ssh took that as "no" ("Host key verification failed").
    /// Reads block instead, bounded by a 5 second timeout.
    static func prepareAccepted(_ client: Int32) {
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    private func readField(_ fd: Int32) -> String? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard length <= 65536, let bytes = readExactly(fd, Int(length)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer[offset...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { return nil }
            offset += received
        }
        return buffer
    }

    /// Sends the answer (or a refusal) and closes the connection. Runs on the queue.
    private func finish(_ client: Int32, answer: String?) {
        guard let watch = clients.removeValue(forKey: client) else { return }
        var bytes = Array((answer ?? "").utf8)
        let length = UInt32(bytes.count).bigEndian
        var message = [UInt8](repeating: answer == nil ? 1 : 0, count: 1) + withUnsafeBytes(of: length) { Array($0) } + bytes
        _ = message.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
        for index in bytes.indices { bytes[index] = 0 }
        for index in message.indices { message[index] = 0 }
        watch.cancel()
    }

    /// Refuses every question still waiting, as the session stops.
    func refusePendingRequests() {
        queue.async { [self] in
            for client in Array(clients.keys) { finish(client, answer: nil) }
        }
    }

    /// Closes everything and removes the folder. Safe to call more than once; runs on the
    /// queue when called from it.
    func close() {
        let work = { [self] in
            guard closed == false else { return }
            closed = true
            for client in Array(clients.keys) { finish(client, answer: nil) }
            logSource?.cancel()
            logSource = nil
            if logKeepAlive >= 0 { Darwin.close(logKeepAlive) }
            logKeepAlive = -1
            // A suspended source must be resumed before it is cancelled and released.
            if let listenSource, accepting == false {
                accepting = true
                listenSource.resume()
            }
            listenSource?.cancel()
            listenSource = nil
            unlink(socketPath)
            unlink(logPath)
            rmdir(directory)
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(queue) {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
}

/// Who may talk to a session's askpass socket: the bundled helper, run by this user, as a
/// descendant of the ssh process the session started (directly, or through ProxyJump's inner
/// ssh). Anything else is disconnected before a byte is read.
enum AskpassPeer {
    static func isTrusted(_ fd: Int32, helperPath: String, ancestor: pid_t) -> Bool {
        guard ancestor > 0 else { return false }
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
              credentials.cr_uid == getuid()
        else { return false }
        var pid: pid_t = 0
        length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0,
              executablePath(of: pid) == helperPath
        else { return false }
        return descends(pid, from: ancestor, maximumDepth: 4)
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func descends(_ pid: pid_t, from ancestor: pid_t, maximumDepth: Int) -> Bool {
        var current = pid
        for _ in 0 ..< maximumDepth {
            guard let parent = parent(of: current), parent > 1 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }
}
