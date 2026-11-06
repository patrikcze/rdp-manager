import AppKit
import RDPManagerCore
import SwiftUI

/// An SSH session's terminal, edge to edge. The terminal stays visible in every state, so a
/// server banner or the last output before a disconnect can be read; questions from OpenSSH
/// (host key, password, passphrase, codes) appear as cards over it.
struct SSHSessionView: View {
    let session: SSHSession
    var isVisible = true
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color(nsColor: session.terminal.nativeBackgroundColor)
            SurfaceHost(surface: session.surface)
                .padding(.leading, 6)
                .padding(.top, 4)
            switch session.phase {
            case let .awaitingHostKeyDecision(prompt):
                cardBackdrop { SSHHostKeyCard(session: session, prompt: prompt) }
            case let .awaitingInput(request):
                cardBackdrop { SSHInputCard(session: session, request: request) }
                    .id(request.id)
            case .idle, .connecting, .verifyingHostKey, .authenticating, .reconnecting:
                VStack {
                    SSHProgressBar(session: session)
                    Spacer()
                }
            case let .ended(end):
                VStack {
                    Spacer()
                    SSHEndedBar(session: session, end: end)
                }
            case .connected:
                EmptyView()
            }
            VStack {
                Spacer()
                if let notice = session.securityKeyNotice {
                    noticeCapsule(notice, symbol: "key.radiowaves.forward")
                }
                if let notice = session.lastNotice {
                    noticeCapsule(notice, symbol: "info.circle")
                }
            }
            .padding(.bottom, session.phase.isEnded ? 90 : 16)
            .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: session.status)
        .onChange(of: isVisible) { _, visible in
            if visible { session.focusInput() }
        }
        .onChange(of: session.phase == .connected) { _, connected in
            if connected, isVisible { session.focusInput() }
        }
    }

    private func cardBackdrop(@ViewBuilder _ card: () -> some View) -> some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35))
            card()
                .frame(maxWidth: 480)
                .padding(32)
        }
    }

    private func noticeCapsule(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 24)
    }
}

/// Where the connection is, from OpenSSH's own log, and a way out.
private struct SSHProgressBar: View {
    let session: SSHSession

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(detail)
                .font(.callout)
            Spacer()
            Button("Cancel") { session.disconnect() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var detail: String {
        switch session.phase {
        case .verifyingHostKey: "Verifying the host key of \(session.hostLabel)…"
        case .authenticating: "Signing in to \(session.hostLabel)…"
        case let .reconnecting(attempt, total): "Connection lost. Reconnecting (attempt \(attempt) of \(total))…"
        default: "Connecting to \(session.hostLabel)…"
        }
    }
}

private struct SSHEndedBar: View {
    let session: SSHSession
    let end: SessionEnd
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(end.kind == .failed ? .red : .secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                Text(end.title).font(.headline)
                Text(end.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if session.connectionID == nil {
                Button("Save as Connection…") { model.saveQuickConnect(.ssh(session)) }
            }
            Button("Close") { model.workspace.close(.ssh(session)) }
            Button("Reconnect") { session.connect() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var symbol: String {
        switch end.category {
        case .network: "wifi.exclamationmark"
        case .authentication: "person.crop.circle.badge.exclamationmark"
        case .certificate: "lock.slash"
        case .server, .unsupported: "server.rack"
        case .client: "exclamationmark.triangle"
        case .none: "powerplug"
        }
    }
}

/// An unknown host key: the fingerprint, and the user's decision before anything is sent.
private struct SSHHostKeyCard: View {
    let session: SSHSession
    let prompt: SSHHostKeyPrompt

    var body: some View {
        VStack(spacing: 18) {
            CardHeader(
                symbol: "lock.trianglebadge.exclamationmark", tint: .orange,
                title: "Unknown Host Key",
                subtitle: "This Mac has not connected to \(prompt.host.isEmpty ? session.hostLabel : prompt.host) before. Compare the fingerprint with the one the server's administrator gives you before you trust it."
            )
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Host", value: session.hostLabel)
                if let type = prompt.keyType {
                    LabeledContent("Key type", value: type)
                }
                LabeledContent("Fingerprint") {
                    Text(prompt.fingerprint ?? "Not shown by OpenSSH")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                if prompt.fingerprint == nil {
                    Text(prompt.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("Nothing has been sent to the server yet. Trusting adds the key to ~/.ssh/known_hosts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Don't Connect") { session.rejectHostKey() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Trust and Connect") { session.trustHostKey() }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A password, passphrase, code or PIN OpenSSH asks for, or one of its yes/no questions.
private struct SSHInputCard: View {
    let session: SSHSession
    let request: SSHInputRequest
    @State private var answer = ""
    @State private var save = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            CardHeader(symbol: request.isConfirmation ? "questionmark.diamond" : "person.badge.key",
                       tint: request.isConfirmation ? .orange : .accentColor,
                       title: request.title, subtitle: session.hostLabel)
            if let message = request.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(request.promptText)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if request.isConfirmation {
                HStack {
                    Button("No") { session.confirm(false, for: request) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Yes") { session.confirm(true, for: request) }
                }
            } else {
                SecureField(fieldLabel, text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                if request.saveAccount != nil {
                    Toggle("Save in Keychain", isOn: $save)
                        .help("Saved only after OpenSSH reports that it worked.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Cancel") { session.cancelInput() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Continue", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { focused = true }
    }

    private var fieldLabel: String {
        switch request.kind {
        case .passphrase: "Passphrase"
        case .pin: "PIN"
        case .password: "Password"
        default: "Answer"
        }
    }

    private func submit() {
        session.submit(answer, for: request, save: save)
        answer = ""
    }
}
