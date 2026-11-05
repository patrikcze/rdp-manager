import FreeRDPBridge
import Foundation
@testable import RDPManager
import RDPManagerCore
import Testing

/// The FreeRDP bridge's own safety rules, checked on a session that is created but never
/// connected (no network).
@Suite("FreeRDP bridge safety")
struct FreeRDPBridgeSafetyTests {
    /// A session for 127.0.0.1 with no-op callbacks. Never run, so nothing is sent.
    private func withSession(clipboard: Bool, _ body: (OpaquePointer) -> Void) {
        var callbacks = rm_callbacks()
        callbacks.on_ended = { _, _, _, _ in }
        let session: OpaquePointer? = "127.0.0.1".withCString { host in
            var config = rm_config()
            config.host = host
            config.port = 3389
            config.width = 1024
            config.height = 768
            config.desktop_scale = 100
            config.device_scale = 100
            config.timeout_ms = 1000
            config.clipboard = clipboard
            return rm_session_new(&config, &callbacks)
        }
        guard let session else {
            Issue.record("rm_session_new failed")
            return
        }
        body(session)
        rm_session_free(session)
    }

    @Test func turningClipboardSharingOffForgetsTheOfferedText() {
        withSession(clipboard: true) { session in
            "secret".withCString { rm_session_set_local_clipboard_text(session, $0) }
            #expect(rm_session_offers_clipboard_text(session))
            rm_session_set_clipboard_shared(session, false)
            #expect(rm_session_offers_clipboard_text(session) == false)
            // Text arriving while sharing is off is not kept either.
            "later".withCString { rm_session_set_local_clipboard_text(session, $0) }
            #expect(rm_session_offers_clipboard_text(session) == false)
            // Turning it back on offers nothing until new text is set.
            rm_session_set_clipboard_shared(session, true)
            #expect(rm_session_offers_clipboard_text(session) == false)
            "again".withCString { rm_session_set_local_clipboard_text(session, $0) }
            #expect(rm_session_offers_clipboard_text(session))
        }
    }

    @Test func clipboardOffInSettingsOffersNothing() {
        withSession(clipboard: false) { session in
            "secret".withCString { rm_session_set_local_clipboard_text(session, $0) }
            #expect(rm_session_offers_clipboard_text(session) == false)
        }
    }

    @Test func resizeWithoutAChannelIsRefusedSafely() {
        withSession(clipboard: true) { session in
            #expect(rm_session_resize(session, 1920, 1080, 100, 100) == false)
            #expect(rm_session_resize(session, 60000, 60000, 100, 100) == false)
        }
    }

    @Test(arguments: [
        (1024, 768, true), (7680, 4320, true), (8192, 4608, true), (6016, 3384, true),
        (8193, 100, false), (100, 8193, false), (8192, 8192, false), (65535, 65535, false), (0, 768, false),
    ])
    func desktopSizesAreBounded(width: Int, height: Int, allowed: Bool) {
        #expect(rm_desktop_size_is_allowed(UInt32(width), UInt32(height)) == allowed)
        #expect((FreeRDPConnection.frameByteCount(width: width, height: height) != nil) == allowed)
    }

    @Test func frameByteCountNeverOverflows() {
        #expect(FreeRDPConnection.frameByteCount(width: .max, height: .max) == nil)
        #expect(FreeRDPConnection.frameByteCount(width: -1, height: 10) == nil)
        #expect(FreeRDPConnection.frameByteCount(width: 1920, height: 1080) == 1920 * 1080 * 4)
    }

    @Test func oversizedDesktopEndsWithAClearReason() {
        guard case let .end(end) = FreeRDPEndMapping.desktopTooLarge(host: "h") else {
            Issue.record("expected an end")
            return
        }
        #expect(end.kind == .failed)
        #expect(end.category == .server)
        #expect(ReconnectPolicy().decision(after: end, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
    }
}
