import RDPManagerCore
import SwiftUI

/// App settings: certificate trust and Keychain housekeeping. Connection defaults live on
/// groups, where they apply to the connections inside.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var trustedCount = 0
    @State private var cleanupResult: String?

    var body: some View {
        Form {
            Section("Certificates") {
                LabeledContent("Trusted server certificates", value: "\(trustedCount)")
                Button("Forget All Trusted Certificates…", role: .destructive) {
                    model.trustStore.removeAll()
                    trustedCount = model.trustStore.count
                }
                .disabled(trustedCount == 0)
                Text("Certificates you trusted are remembered per host and port. A changed certificate is always shown for review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Keychain") {
                Button("Remove Unused Passwords") {
                    let inventory = model.inventory
                    let credentialIDs = Set(inventory.credentials.map(\.id))
                    let connectionIDs = Set(inventory.connections.map(\.id))
                    Task {
                        do {
                            let removed = try await model.credentials.removeOrphans { account in
                                switch account {
                                case let .credential(id): credentialIDs.contains(id)
                                case let .connection(id): connectionIDs.contains(id)
                                }
                            }
                            cleanupResult = removed == 0 ? "Nothing to remove." : "Removed \(removed) unused password\(removed == 1 ? "" : "s")."
                        } catch {
                            cleanupResult = error.localizedDescription
                        }
                    }
                }
                if let cleanupResult {
                    Text(cleanupResult).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Text("RDP Manager sends no analytics or telemetry and makes no network connections except to the hosts you connect to.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 380)
        .onAppear { trustedCount = model.trustStore.count }
    }
}
