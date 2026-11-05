import Foundation
import RDPKit
@testable import RDPManager
import Testing

@Suite("Certificate pins")
struct CertificatePinTests {
    private let pinned = "aa:bb:cc"
    private let replacement = "dd:ee:ff"

    private func store() throws -> CertificateTrustStore {
        let store = CertificateTrustStore(fileURL: nil)
        store.trust(try #require(RDPServerCertificateTrustKey(host: "Server.Example.com", port: 3389, sha256: pinned)))
        return store
    }

    @Test func systemTrustedReplacementOfAPinIsRefusedAsChanged() throws {
        let info = RDPServerCertificateInfo(trusted: true, sha256: replacement, warnings: [], host: "server.example.com")
        #expect(try store().refusal(of: info, port: 3389) == .changed)
    }

    @Test func untrustedReplacementIsRefusedAsChanged() throws {
        let info = RDPServerCertificateInfo(trusted: false, sha256: replacement, warnings: [], host: "server.example.com")
        #expect(try store().refusal(of: info, port: 3389) == .changed)
    }

    @Test func pinnedCertificateIsAccepted() throws {
        for systemTrusted in [true, false] {
            let info = RDPServerCertificateInfo(trusted: systemTrusted, sha256: pinned, warnings: [], host: "SERVER.example.com")
            #expect(try store().refusal(of: info, port: 3389) == nil)
        }
    }

    @Test func otherHostsAndPortsFollowSystemTrust() throws {
        let store = try store()
        #expect(store.refusal(of: RDPServerCertificateInfo(trusted: true, sha256: replacement, warnings: [], host: "server.example.com"), port: 3390) == nil)
        #expect(store.refusal(of: RDPServerCertificateInfo(trusted: true, sha256: replacement, warnings: [], host: "other"), port: 3389) == nil)
        #expect(store.refusal(of: RDPServerCertificateInfo(trusted: false, sha256: replacement, warnings: [], host: "other"), port: 3389) == .untrusted)
    }

    @Test func savedTrustFileIsOwnerOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rdpm-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "trusted-certificates.json")
        let store = CertificateTrustStore(fileURL: file)
        store.trust(try #require(RDPServerCertificateTrustKey(host: "h", port: 3389, sha256: pinned)))
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
        #expect(CertificateTrustStore(fileURL: file).count == 1)
    }
}
