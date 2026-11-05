import Foundation
import RDPKit

/// The server certificates the user explicitly trusted, one per host and port, kept as
/// RDPKit's storage identifiers in a JSON file next to the inventory (or only in memory). Read
/// from the session thread during the TLS handshake, so it is lock-protected.
final class CertificateTrustStore: @unchecked Sendable {
    /// nil keeps everything in memory (sample mode).
    private let fileURL: URL?
    private let lock = NSLock()
    private var identifiers: [String]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        identifiers = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    var trusted: RDPTrustedServerCertificates {
        lock.withLock { RDPTrustedServerCertificates(storageIdentifiers: identifiers) }
    }

    /// Why the certificate must be refused before any credential is sent, or nil to go ahead.
    ///
    /// A certificate the user trusted for this host and port is a pin: a different one is
    /// refused as changed even when macOS trusts it, so a CA-valid replacement still needs the
    /// user's review. (RDPKit's own check skips system-trusted certificates.) Everything else
    /// follows RDPKit's rule: system trust, or the user's.
    func refusal(of certificate: RDPServerCertificateInfo, port: UInt16) -> RDPServerCertificateRefusal? {
        let trusted = trusted
        if Self.pinnedFingerprints(in: trusted.storageIdentifiers, host: certificate.host, port: port).isEmpty == false,
           trusted.isTrusted(host: certificate.host, port: port, sha256: certificate.sha256) == false {
            return .changed
        }
        return trusted.refusal(of: certificate, port: port, acceptsUntrusted: false)
    }

    /// The fingerprints the user trusted for `host` and `port`.
    static func pinnedFingerprints(in identifiers: some Sequence<String>, host: String, port: UInt16) -> [String] {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return identifiers.compactMap(RDPServerCertificateTrustKey.init(storageIdentifier:))
            .filter { $0.host == host && $0.port == port }
            .map(\.sha256)
    }

    /// Trusts `key`, replacing whatever was trusted for its host and port.
    func trust(_ key: RDPServerCertificateTrustKey) {
        lock.withLock {
            var certificates = RDPTrustedServerCertificates(storageIdentifiers: identifiers)
            certificates.trust(key)
            identifiers = certificates.storageIdentifiers.sorted()
            save()
        }
    }

    func removeAll() {
        lock.withLock {
            identifiers = []
            save()
        }
    }

    var count: Int {
        lock.withLock { identifiers.count }
    }

    /// Owner-only, like the inventory: 0700 folder, 0600 file.
    private func save() {
        guard let fileURL else { return }
        let manager = FileManager.default
        do {
            let folder = fileURL.deletingLastPathComponent()
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try JSONEncoder().encode(identifiers).write(to: fileURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("RDP Manager: could not save trusted certificates: %@", error.localizedDescription)
        }
    }
}
