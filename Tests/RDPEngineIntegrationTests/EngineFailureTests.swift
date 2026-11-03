import Darwin
import Foundation
import RDPKit
@testable import RDPManager
import RDPManagerCore
import Testing

/// Real RDPKit connection attempts against sockets on this Mac. They need no Windows host and
/// verify the failure paths end to end: engine → typed failure → what the user is told →
/// whether the app reconnects on its own.
@Suite("RDP engine failure handling", .serialized, .timeLimit(.minutes(1)))
struct EngineFailureTests {
    @Test func closedPortIsANetworkFailureAndNotRetriedBeforeTheDesktop() async throws {
        let port = try LocalServer.unusedPort()
        let report = await attempt(port: port)
        guard case let .connect(error)? = report.failure else {
            Issue.record("Expected a TCP connect failure, got \(String(describing: report.failure))")
            return
        }
        #expect(error.category == .refused)

        guard case let .end(end) = SessionEndMapping.outcome(for: report, host: "127.0.0.1", showedDesktop: false) else {
            Issue.record("A refused connection must not ask for credentials")
            return
        }
        #expect(end.kind == .failed)
        #expect(end.category == .network)
        #expect(end.message.contains("Remote Desktop is enabled"))
        // It never showed a desktop, so it is not retried automatically.
        #expect(ReconnectPolicy().decision(after: end, wasShowingDesktop: false, attemptsMade: 0, enabled: true) == .stop)
    }

    @Test func nonRDPServiceIsReportedAsSuch() async throws {
        let server = try LocalServer(reply: Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".utf8))
        let report = await attempt(port: server.port)
        server.stop()
        guard case .noConnectionConfirm? = report.failure else {
            Issue.record("Expected noConnectionConfirm, got \(String(describing: report.failure))")
            return
        }
        guard case let .end(end) = SessionEndMapping.outcome(for: report, host: "127.0.0.1", showedDesktop: false) else {
            Issue.record("Expected an end")
            return
        }
        #expect(end.title == "No Remote Desktop service")
    }

    @Test func silentServerTimesOutWithinTheConfiguredBound() async throws {
        let server = try LocalServer(reply: nil)
        let started = Date()
        let report = await attempt(port: server.port, timeout: 5)
        server.stop()
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(report.failure != nil)
        guard case let .end(end) = SessionEndMapping.outcome(for: report, host: "127.0.0.1", showedDesktop: false) else {
            Issue.record("Expected an end")
            return
        }
        #expect(end.category == .network)
    }

    @Test func wrongCredentialsAskAgainInsteadOfRetrying() {
        var report = RDPConnectionReport.empty
        report.failure = .credSSP(status: .logonFailure)
        guard case let .promptForCredentials(message) = SessionEndMapping.outcome(for: report, host: "h", showedDesktop: false) else {
            Issue.record("Wrong credentials must prompt")
            return
        }
        #expect(message == SessionEndMapping.wrongCredentialsMessage)

        // The same failure after the desktop showed is an authentication end; never auto-retried.
        let end = SessionEndMapping.end(for: .credSSP(status: .accountLockedOut), report: report, host: "h")
        #expect(end.category == .authentication)
        #expect(ReconnectPolicy().decision(after: end, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
    }

    @Test func droppedLiveSessionReconnects() {
        let end = SessionEndMapping.end(for: .connectionLost, report: .empty, host: "h")
        #expect(ReconnectPolicy().decision(after: end, wasShowingDesktop: true, attemptsMade: 0, enabled: true)
            == .reconnect(attempt: 1, after: .seconds(2)))
    }

    private func attempt(port: UInt16, timeout: Int = 5) async -> RDPConnectionReport {
        await Task.detached {
            let target = try! RDPConnectionTarget(host: "127.0.0.1", port: port)
            let configuration = RDPConnectionConfiguration(
                target: target,
                timeoutSeconds: timeout,
                desktopSize: try! RDPDesktopSize(width: 1024, height: 768)
            )
            return RDPSessionClient().run(configuration: configuration)
        }.value
    }
}

private extension RDPConnectionReport {
    /// A report to hang a failure on for mapping tests: from a run that cannot connect.
    static var empty: RDPConnectionReport {
        let target = try! RDPConnectionTarget(host: "127.0.0.1", port: 1)
        return RDPSessionClient().run(configuration: RDPConnectionConfiguration(
            target: target, timeoutSeconds: 1, desktopSize: try! RDPDesktopSize(width: 1024, height: 768)
        ))
    }
}

/// A one-connection TCP server on 127.0.0.1 that sends `reply` (or nothing) and stays open
/// until stopped.
final class LocalServer: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32
    private var clientFD: Int32 = -1
    private let thread: Thread

    init(reply: Data?) throws {
        socketFD = try Self.listeningSocket()
        port = Self.port(of: socketFD)
        let fd = socketFD
        let box = ClientBox()
        thread = Thread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            box.fd = client
            var buffer = [UInt8](repeating: 0, count: 512)
            _ = read(client, &buffer, buffer.count)
            if let reply {
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
                close(client)
            }
        }
        clientBox = box
        thread.start()
    }

    private let clientBox: ClientBox
    private final class ClientBox: @unchecked Sendable { var fd: Int32 = -1 }

    func stop() {
        if clientBox.fd >= 0 { close(clientBox.fd) }
        close(socketFD)
    }

    /// A port nothing listens on: bound, read, then released.
    static func unusedPort() throws -> UInt16 {
        let fd = try listeningSocket()
        let port = port(of: fd)
        close(fd)
        return port
    }

    private static func listeningSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 1) == 0 else {
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    private static func port(of fd: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
