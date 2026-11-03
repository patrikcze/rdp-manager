import RDPManagerCore
import SwiftUI

/// Toolbar field: type `host`, `host:port` or an IP and press Return to connect without saving.
struct QuickConnectField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
            TextField("Quick Connect — host or host:port", text: $text)
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
        if let message = model.quickConnect(text) {
            error = message
            NSSound.beep()
        } else {
            text = ""
            isFocused = false
        }
    }
}
