import Foundation
import RDPKit

/// The server certificates the user explicitly trusted, one per host and port. RDPKit's
/// `RDPTrustedServerCertificates` decides what they trust and detects a changed certificate;
/// this keeps its storage identifiers in a JSON file next to the inventory. Read from the
/// session thread during the TLS handshake, so it is lock-protected.
final class CertificateTrustStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var identifiers: [String]

    init(fileURL: URL) {
        self.fileURL = fileURL
        identifiers = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    var trusted: RDPTrustedServerCertificates {
        lock.withLock { RDPTrustedServerCertificates(storageIdentifiers: identifiers) }
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

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(identifiers).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("RDP Manager: could not save trusted certificates: %@", error.localizedDescription)
        }
    }
}
