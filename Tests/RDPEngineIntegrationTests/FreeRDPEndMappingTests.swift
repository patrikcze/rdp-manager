import Foundation
@testable import RDPManager
import RDPManagerCore
import Testing

@Suite("FreeRDP end mapping")
struct FreeRDPEndMappingTests {
    private func end(_ name: String, info: UInt32 = 0, showed: Bool = false, security: SecurityMode = .automatic) -> EngineEnd {
        FreeRDPEndMapping.outcome(errorName: name, errorInfo: info, errorInfoText: "info", showedDesktop: showed,
                                  host: "h", security: security)
    }

    @Test(arguments: ["FREERDP_ERROR_AUTHENTICATION_FAILED", "FREERDP_ERROR_CONNECT_LOGON_FAILURE",
                      "FREERDP_ERROR_CONNECT_WRONG_PASSWORD", "FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS"])
    func refusedSignInAsksAgainAndNeverRetries(name: String) {
        guard case .promptForCredentials = end(name) else {
            Issue.record("\(name) should ask for credentials")
            return
        }
        guard case let .end(after) = end(name, showed: true) else { return }
        #expect(after.category == .authentication)
        #expect(ReconnectPolicy().decision(after: after, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
    }

    @Test func signOutAndTakeoverAreNormalEnds() {
        for info in [FreeRDPEndMapping.ErrorInfo.logoffByUser, FreeRDPEndMapping.ErrorInfo.rpcInitiatedLogoff,
                     FreeRDPEndMapping.ErrorInfo.disconnectedByOtherConnection] {
            guard case let .end(e) = end("FREERDP_ERROR_SUCCESS", info: info, showed: true) else { continue }
            #expect(e.kind == .remoteEnded)
            #expect(ReconnectPolicy().decision(after: e, wasShowingDesktop: true, attemptsMade: 0, enabled: true) == .stop)
        }
    }

    @Test func droppedConnectionReconnects() {
        guard case let .end(e) = end("FREERDP_ERROR_CONNECT_TRANSPORT_FAILED", showed: true) else {
            Issue.record("expected an end")
            return
        }
        #expect(e.category == .network)
        #expect(ReconnectPolicy().decision(after: e, wasShowingDesktop: true, attemptsMade: 0, enabled: true) != .stop)
    }

    @Test func standardRDPSecurityRefusalIsNamed() {
        guard case let .end(e) = end("FREERDP_ERROR_CONNECT_TRANSPORT_FAILED", security: .standardRDP) else {
            Issue.record("expected an end")
            return
        }
        #expect(e.title == "Standard RDP Security refused")
        #expect(e.category == .server)
    }

    @Test func dnsAndCancelAreReadCorrectly() {
        if case let .end(e) = end("FREERDP_ERROR_DNS_NAME_NOT_FOUND") { #expect(e.title == "Host not found") }
        if case let .end(e) = end("FREERDP_ERROR_CONNECT_CANCELLED") { #expect(e.kind == .userDisconnected) }
    }

    @Test func pemChainsSplitIntoCertificates() {
        let block = "-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----"
        let ders = FreeRDPConnection.certificates(fromPEM: block + "\r\n" + block)
        #expect(ders.count == 2)
        #expect(ders.first == Data([0, 1, 2]))
    }

    @Test func wheelRotationIsNineBitTwosComplement() {
        #expect(FreeRDPCanvas.wheelFlags(120, horizontal: false) == 0x0200 | 120)
        #expect(FreeRDPCanvas.wheelFlags(-120, horizontal: false) == 0x0200 | 0x0100 | UInt16(0x100 - 120))
        #expect(FreeRDPCanvas.wheelFlags(-1, horizontal: true) & 0x0400 != 0)
    }

    @Test func domainBackslashUserIsSplit() {
        #expect(RemoteSession.splitDomain(username: "CONTOSO\\admin", domain: "") == ("admin", "CONTOSO"))
        #expect(RemoteSession.splitDomain(username: "admin@contoso.com", domain: "") == ("admin@contoso.com", ""))
        #expect(RemoteSession.splitDomain(username: "CONTOSO\\admin", domain: "OTHER") == ("CONTOSO\\admin", "OTHER"))
    }
}
