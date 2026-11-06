import Darwin
import Foundation
import Testing
@testable import RDPManager

/// The askpass socket's timing. OpenSSH may ask its first question (a host key, a key
/// passphrase) before the app knows ssh's pid; that question must wait, not fail the peer
/// check, or ssh reads the failure as "no" and the user is never asked. Seen on CI.
@Suite("Askpass channel")
struct AskpassChannelTests {
    @Test func aConnectionBeforeSSHIsKnownWaitsInsteadOfBeingRefused() async throws {
        let channels = try SSHSideChannels(
            helperPath: "/nonexistent/RDPManagerAskpass",
            queue: DispatchQueue(label: "rdpmanager.tests.askpass")
        )
        defer { channels.close() }
        let client = try connect(to: channels.socketPath)
        defer { Darwin.close(client) }

        // Not yet accepting: the connection sits in the backlog, still open.
        try await Task.sleep(for: .milliseconds(300))
        #expect(peek(client) == .open)

        // Accepting now: this test process isn't the helper below that pid, so it is refused.
        channels.startAccepting(from: getpid())
        var state = peek(client)
        let deadline = Date().addingTimeInterval(5)
        while state == .open, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            state = peek(client)
        }
        #expect(state == .closed)
    }

    @Test func closingBeforeAcceptingReleasesTheSocket() throws {
        let channels = try SSHSideChannels(
            helperPath: "/nonexistent/RDPManagerAskpass",
            queue: DispatchQueue(label: "rdpmanager.tests.askpass")
        )
        let directory = channels.directory
        channels.close()
        #expect(FileManager.default.fileExists(atPath: directory) == false)
    }

    private enum PeerState { case open, closed }

    private func peek(_ fd: Int32) -> PeerState {
        var byte: UInt8 = 0
        let received = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return received == 0 || (received < 0 && errno != EAGAIN && errno != EWOULDBLOCK) ? .closed : .open
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }
}
