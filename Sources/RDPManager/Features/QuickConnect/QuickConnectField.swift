import RDPManagerCore
import SwiftUI

/// Toolbar field: type `host`, `host:port` or an IP and press Return to connect without
/// saving. RDP by default; `ssh://user@host[:port]`, `ssh user@host` or the protocol menu
/// connect over SSH.
struct QuickConnectField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var error: String?
    @State private var connectionProtocol: ConnectionProtocol = .rdp
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Protocol", selection: $connectionProtocol) {
                    ForEach(ConnectionProtocol.allCases, id: \.self) { item in
                        Label(item.label, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: connectionProtocol == .ssh ? "terminal" : "bolt.horizontal.circle")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Protocol for addresses without ssh:// (\(connectionProtocol.label))")
            TextField(connectionProtocol == .ssh ? "Quick Connect — user@host or host:port" : "Quick Connect — host, host:port or ssh://user@host", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(connect)
                .onChange(of: text) { error = nil }
                .frame(width: 240)
            if text.isEmpty == false {
                Button(action: connect) {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Connect")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(error ?? "Connect to a host without saving it (⌘K)")
        .background {
            Button("") { isFocused = true }
                .keyboardShortcut("k")
                .hidden()
        }
    }

    private func connect() {
        guard text.trimmingCharacters(in: .whitespaces).isEmpty == false else { return }
        if let message = model.quickConnect(text, preferring: connectionProtocol) {
            error = message
            NSSound.beep()
        } else {
            text = ""
            isFocused = false
        }
    }
}
