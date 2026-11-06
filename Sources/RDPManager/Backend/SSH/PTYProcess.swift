import Darwin
import Foundation

/// A child process on a pseudo-terminal that this app owns from spawn to reap.
///
/// Spawned with `posix_spawn` (no shell, no `fork` in a threaded process) as the leader of a
/// new session, with the PTY's slave side as stdin, stdout and stderr. Every other descriptor
/// is closed in the child (`POSIX_SPAWN_CLOEXEC_DEFAULT`). The PTY is not its controlling
/// terminal, so window-size changes and hangups are signalled explicitly, to this pid only.
/// Reading, writing and reaping happen on one serial queue, never on the main thread. Only
/// this process is ever signalled.
final class PTYProcess: @unchecked Sendable {
    struct Configuration {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var columns: UInt16
        var rows: UInt16
    }

    enum SpawnError: Error, LocalizedError {
        case pty(String, Int32)
        case spawn(Int32)

        var errorDescription: String? {
            switch self {
            case let .pty(step, code): "Could not create a terminal (\(step): \(String(cString: strerror(code))))."
            case let .spawn(code): "Could not start ssh (\(String(cString: strerror(code))))."
            }
        }
    }

    /// Output larger than this per read is split; pending input beyond the limit is refused.
    static let readChunk = 65536
    static let maximumPendingInput = 4 * 1024 * 1024

    let pid: pid_t
    private let master: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var pendingInput: [UInt8] = []
    private var hasExited = false
    private var masterClosed = false
    private var suspendedRead = false
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (_ exitStatus: Int32?, _ signal: Int32?) -> Void

    /// Starts the process. `onOutput` and `onExit` run on the process's own serial queue;
    /// `onExit` runs once, after all output written before exit was delivered.
    init(
        _ configuration: Configuration,
        queue: DispatchQueue,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onExit: @escaping @Sendable (_ exitStatus: Int32?, _ signal: Int32?) -> Void
    ) throws {
        self.onOutput = onOutput
        self.onExit = onExit
        self.queue = queue

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw SpawnError.pty("posix_openpt", errno) }
        var slave: Int32 = -1
        var ok = false
        defer {
            if slave >= 0 { close(slave) }
            if ok == false { close(master) }
        }
        guard grantpt(master) == 0 else { throw SpawnError.pty("grantpt", errno) }
        guard unlockpt(master) == 0 else { throw SpawnError.pty("unlockpt", errno) }
        // TIOCPTYGNAME instead of ptsname(), which isn't thread-safe.
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard ioctl(master, TIOCPTYGNAME, &nameBuffer) == 0 else { throw SpawnError.pty("ptsname", errno) }
        let slavePath = String(cString: nameBuffer)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        // Open the slave here first, so its size and modes are set before the child opens
        // it, and the master never reads EOF before the child has it open.
        slave = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard slave >= 0 else { throw SpawnError.pty("open", errno) }
        var size = winsize(ws_row: configuration.rows, ws_col: configuration.columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &size)
        var modes = termios()
        if tcgetattr(slave, &modes) == 0 {
            modes.c_iflag |= tcflag_t(IUTF8)
            _ = tcsetattr(slave, TCSANOW, &modes)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opened by path in the child, after setsid.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([configuration.executable] + configuration.arguments).map { strdup($0) } + [nil]
        let envp = configuration.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, configuration.executable, &actions, &attributes, argv, envp)
        guard status == 0 else { throw SpawnError.spawn(status) }
        ok = true
        self.pid = pid
        self.master = master
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        queue.sync { startSources() }
    }

    // MARK: - Input

    /// Sends bytes to the process, in order. Refused (and false) once too much is waiting.
    func write(_ bytes: [UInt8]) {
        guard bytes.isEmpty == false else { return }
        queue.async { [self] in
            guard masterClosed == false, hasExited == false else { return }
            guard pendingInput.count + bytes.count <= Self.maximumPendingInput else { return }
            pendingInput += bytes
            flushInput()
        }
    }

    /// Sets the terminal's size and tells the process (SIGWINCH), which tells the server.
    func resize(columns: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard masterClosed == false else { return }
            var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, TIOCSWINSZ, &size)
            // A process started by posix_spawn has no controlling terminal (macOS assigns one
            // only through TIOCSCTTY, which posix_spawn can't do), so the kernel sends no
            // SIGWINCH. Send it to our own child, which then reads the new size from its stdin.
            if hasExited == false { kill(pid, SIGWINCH) }
        }
    }

    /// Hangs up: SIGHUP, as closing a terminal does, then SIGKILL if it is still running after
    /// `grace`. Only this process's pid is signalled, and only before it was reaped.
    func terminate(grace: TimeInterval = 2) {
        queue.async { [self] in
            guard hasExited == false else { return }
            kill(pid, SIGHUP)
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                guard hasExited == false else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Sources

    /// The sources hold the object strongly until the process is reaped, so a process is
    /// never left unreaped because its owner let go early.
    private func startSources() {
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { self.drainOutput() }
        // The descriptor is closed only once its sources are cancelled, never under them.
        read.setCancelHandler {
            self.writeSource?.cancel()
            self.writeSource = nil
            self.masterClosed = true
            close(self.master)
        }
        read.resume()
        readSource = read

        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { self.reap() }
        process.resume()
        processSource = process
        // It may have exited before the source existed.
        reap()
    }

    private func drainOutput() {
        guard masterClosed == false, suspendedRead == false else { return }
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if count > 0 {
                onOutput(Array(buffer[0 ..< count]))
                if count < Self.readChunk { return }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            // EOF or EIO: the slave side is gone (the process exited). Reading stops; the
            // descriptor closes when the process is reaped.
            readSource?.suspend()
            suspendedRead = true
            return
        }
    }

    private func flushInput() {
        while pendingInput.isEmpty == false {
            let written = pendingInput.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if written > 0 {
                pendingInput.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
                    source.setEventHandler { self.flushInput() }
                    source.resume()
                    writeSource = source
                }
                return
            }
            pendingInput.removeAll()
            break
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func reap() {
        guard hasExited == false else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return }
        hasExited = true
        processSource?.cancel()
        processSource = nil
        // Whatever the process wrote before exiting is still in the PTY.
        drainOutput()
        pendingInput.removeAll()
        // A suspended source must be resumed before it can be cancelled.
        if suspendedRead { readSource?.resume() }
        readSource?.cancel()
        readSource = nil
        let low = status & 0x7F
        if low == 0 {
            onExit((status >> 8) & 0xFF, nil)
        } else {
            onExit(nil, low)
        }
    }
}
