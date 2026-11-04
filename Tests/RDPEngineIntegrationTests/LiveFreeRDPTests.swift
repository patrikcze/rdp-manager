import Foundation
import FreeRDPBridge
import Testing

/// Connects to a real Windows host through the FreeRDP bridge. Opt in; credentials come only
/// from the environment and are never stored:
///   RDPM_LIVE_HOST=… RDPM_LIVE_USER=… RDPM_LIVE_PASSWORD=… swift test --filter LiveFreeRDP
@Suite(
    "Live FreeRDP connection",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RDPM_LIVE_HOST"] != nil),
    .timeLimit(.minutes(1))
)
struct LiveFreeRDPTests {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    @Test(arguments: [RM_SECURITY_AUTO, RM_SECURITY_NLA])
    func signsInAndReceivesTheDesktop(security: rm_security) throws {
        let probe = try LiveProbe.run(
            host: environment["RDPM_LIVE_HOST"]!,
            username: environment["RDPM_LIVE_USER"],
            password: environment["RDPM_LIVE_PASSWORD"],
            security: security,
            secondsAfterConnect: 3
        )
        #expect(probe.connectedSize != nil, "never connected: \(probe.endDescription)")
        #expect(probe.framePixels > 0, "no desktop pixels arrived")
        #expect(probe.certificateSeen, "the certificate callback never ran")
        if let size = probe.connectedSize {
            #expect(size.width == 1280 && size.height == 800)
        }
    }

    @Test func wrongPasswordIsAnAuthenticationFailure() throws {
        let probe = try LiveProbe.run(
            host: environment["RDPM_LIVE_HOST"]!,
            username: environment["RDPM_LIVE_USER"],
            password: "definitely-not-the-password",
            security: RM_SECURITY_NLA,
            secondsAfterConnect: 0
        )
        #expect(probe.connectedSize == nil)
        #expect(probe.endDescription.contains("AUTHENTICATION") || probe.endDescription.contains("LOGON"),
                "unexpected end: \(probe.endDescription)")
    }
}

/// Runs one bridge session on a thread and records what its callbacks reported.
final class LiveProbe: @unchecked Sendable {
    private let lock = NSLock()
    var connectedSize: (width: UInt32, height: UInt32)?
    var framePixels = 0
    var certificateSeen = false
    var lastError: UInt32 = 0
    var errorInfo: UInt32 = 0
    let ended = DispatchSemaphore(value: 0)
    let connected = DispatchSemaphore(value: 0)

    var endDescription: String {
        "\(String(cString: rm_error_name(lastError))) / \(String(cString: rm_error_info_string(errorInfo)))"
    }

    static func run(host: String, username: String?, password: String?, security: rm_security,
                    secondsAfterConnect: Int) throws -> LiveProbe {
        let probe = LiveProbe()
        let unmanaged = Unmanaged.passRetained(probe)
        defer { unmanaged.release() }

        var callbacks = rm_callbacks()
        callbacks.context = unmanaged.toOpaque()
        callbacks.on_frame = { context, _, _, _, _, _, _, w, h in
            let probe = Unmanaged<LiveProbe>.fromOpaque(context!).takeUnretainedValue()
            probe.lock.withLock { probe.framePixels += Int(w) * Int(h) }
        }
        callbacks.on_connected = { context, width, height, _ in
            let probe = Unmanaged<LiveProbe>.fromOpaque(context!).takeUnretainedValue()
            probe.lock.withLock { probe.connectedSize = (width, height) }
            probe.connected.signal()
        }
        callbacks.on_certificate = { context, _, _, _, _, _, _ in
            let probe = Unmanaged<LiveProbe>.fromOpaque(context!).takeUnretainedValue()
            probe.lock.withLock { probe.certificateSeen = true }
            return RM_CERT_ACCEPT_ONCE // A test VM's self-signed certificate.
        }
        callbacks.on_ended = { context, lastError, errorInfo in
            let probe = Unmanaged<LiveProbe>.fromOpaque(context!).takeUnretainedValue()
            probe.lock.withLock {
                probe.lastError = lastError
                probe.errorInfo = errorInfo
            }
            probe.ended.signal()
        }

        let session: OpaquePointer? = host.withCString { hostC in
            (username ?? "").withCString { userC in
                (password ?? "").withCString { passC in
                    "RDPM-TEST".withCString { nameC in
                        var config = rm_config()
                        config.host = hostC
                        config.port = 3389
                        config.username = userC
                        config.password = passC
                        config.width = 1280
                        config.height = 800
                        config.desktop_scale = 100
                        config.device_scale = 100
                        config.timeout_ms = 10000
                        config.client_name = nameC
                        config.security = security
                        config.clipboard = true
                        return rm_session_new(&config, &callbacks)
                    }
                }
            }
        }
        let handle = try #require(session)
        let thread = Thread { rm_session_run(handle) }
        thread.start()
        if probe.connected.wait(timeout: .now() + 20) == .success, secondsAfterConnect > 0 {
            Thread.sleep(forTimeInterval: TimeInterval(secondsAfterConnect))
        }
        rm_session_cancel(handle)
        _ = probe.ended.wait(timeout: .now() + 15)
        Thread.sleep(forTimeInterval: 0.2) // let rm_session_run return
        rm_session_free(handle)
        return probe
    }
}
