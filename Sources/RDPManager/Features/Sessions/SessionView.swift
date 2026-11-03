import AppKit
import RDPManagerCore
import SwiftUI

/// A session's remote desktop, edge to edge, with an overlay for every state that is not the
/// live desktop: connecting, sign-in, certificate review, ended.
struct SessionView: View {
    let session: RemoteSession
    var isVisible = true

    var body: some View {
        ZStack {
            Color.black
            RemoteDesktopHost(session: session)
                .opacity(session.phase.isActive ? 1 : 0)
            if session.phase.isActive == false {
                SessionOverlay(session: session)
                    .transition(.opacity)
            }
            if let notice = session.lastNotice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.phase.isActive)
        .onChange(of: isVisible) { _, visible in
            if visible { session.focusRemoteInput() }
        }
    }
}

/// Hosts the session's AppKit canvas. The canvas belongs to the session, not this view, so
/// a session moved to another window keeps its surface and its connection.
struct RemoteDesktopHost: NSViewRepresentable {
    let session: RemoteSession

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        if session.canvas.superview !== container {
            attach(to: container)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator _: ()) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }

    private func attach(to container: NSView) {
        let canvas = session.canvas
        canvas.removeFromSuperview()
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
    }
}

private struct SessionOverlay: View {
    let session: RemoteSession
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            content
                .frame(maxWidth: 460)
                .padding(32)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle, .resolvingCredentials, .connecting, .reconnecting:
            ConnectingCard(session: session)
        case let .awaitingCredentials(message):
            if let prompt = session.credentialPrompt {
                CredentialPromptCard(session: session, prompt: prompt, message: message)
            }
        case let .awaitingCertificateDecision(issue):
            CertificateCard(session: session, issue: issue)
        case let .ended(end):
            EndedCard(session: session, end: end)
        case .connected:
            EmptyView()
        }
    }
}

private struct CardHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct ConnectingCard: View {
    let session: RemoteSession

    var body: some View {
        VStack(spacing: 22) {
            CardHeader(symbol: "desktopcomputer", tint: .accentColor, title: session.title, subtitle: session.hostLabel)
            ProgressView()
                .controlSize(.small)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") { session.disconnect() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var detail: String {
        switch session.phase {
        case .resolvingCredentials: "Reading the saved password from the Keychain…"
        case let .connecting(detail): detail ?? "Connecting…"
        case let .reconnecting(attempt, total): "Connection lost. Reconnecting (attempt \(attempt) of \(total))…"
        default: "Preparing…"
        }
    }
}

private struct CredentialPromptCard: View {
    let session: RemoteSession
    let prompt: CredentialPrompt
    let message: String?
    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var save = true
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(spacing: 20) {
            CardHeader(symbol: "person.badge.key", tint: .accentColor, title: "Sign in to \(session.title)", subtitle: session.hostLabel)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Form {
                TextField("User name", text: $username, prompt: Text("user, DOMAIN\\user or user@domain"))
                    .focused($focus, equals: .username)
                    .textContentType(.username)
                TextField("Domain", text: $domain, prompt: Text("Optional"))
                SecureField("Password", text: $password)
                    .focused($focus, equals: .password)
                    .textContentType(.password)
                    .onSubmit(submit)
                if prompt.saveAccount != nil {
                    Toggle("Save password in Keychain", isOn: $save)
                        .help("Saved only after the server accepts it.")
                }
            }
            .formStyle(.columns)
            HStack {
                Button("Cancel") { session.cancelCredentialPrompt() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            username = prompt.username
            domain = prompt.domain
            focus = username.isEmpty ? .username : .password
        }
    }

    private func submit() {
        guard username.isEmpty == false, password.isEmpty == false else { return }
        session.submitCredentials(username: username, domain: domain, password: password, save: save && prompt.saveAccount != nil)
        password = ""
    }
}

private struct CertificateCard: View {
    let session: RemoteSession
    let issue: CertificateIssue

    var body: some View {
        VStack(spacing: 18) {
            CardHeader(
                symbol: issue.kind == .changed ? "exclamationmark.shield.fill" : "lock.trianglebadge.exclamationmark",
                tint: issue.kind == .changed ? .red : .orange,
                title: issue.kind == .changed ? "The Certificate Has Changed" : "Unverified Certificate",
                subtitle: issue.kind == .changed
                    ? "\(issue.host) presented a different certificate from the one you trusted before. This can mean the server was reinstalled or renewed — or that someone is intercepting the connection."
                    : "macOS can't verify the identity of \(issue.host). Servers often use self-signed certificates; compare the fingerprint with the server's before you trust it."
            )
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Host", value: "\(issue.host):\(issue.port)")
                LabeledContent("SHA-256") {
                    Text(Self.formatFingerprint(issue.sha256))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                if let detail = issue.systemTrustDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("No credentials were sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Don't Connect") { session.rejectCertificate() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(issue.kind == .changed ? "Trust New Certificate" : "Trust and Connect") {
                    session.trustCertificateAndConnect()
                }
                .disabled(issue.sha256 == nil)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    static func formatFingerprint(_ sha256: String?) -> String {
        guard let sha256 else { return "Unavailable" }
        let hex = sha256.replacingOccurrences(of: ":", with: "").uppercased()
        var groups: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[index ..< next]))
            index = next
        }
        // Two lines of sixteen bytes.
        let half = groups.count / 2
        return groups.count > 16
            ? groups[..<half].joined(separator: ":") + "\n" + groups[half...].joined(separator: ":")
            : groups.joined(separator: ":")
    }
}

private struct EndedCard: View {
    let session: RemoteSession
    let end: SessionEnd
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            CardHeader(symbol: symbol, tint: end.kind == .failed ? .red : .secondary, title: end.title, subtitle: end.message)
            HStack(spacing: 12) {
                Button("Close") { model.workspace.close(session) }
                Button("Reconnect") { session.connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            if session.connectionID == nil {
                Button("Save as Connection…") { model.saveQuickConnect(session) }
                    .buttonStyle(.link)
            }
        }
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

/// A session in a window of its own. Closing the window puts the session back into the main
/// window's tabs rather than disconnecting it.
struct DetachedSessionWindow: View {
    let session: RemoteSession
    @Environment(AppModel.self) private var model

    var body: some View {
        SessionView(session: session)
            .navigationTitle(session.title)
            .navigationSubtitle(session.phase.shortLabel)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        SessionMenuItems(model: model, session: session)
                    } label: {
                        Label("Session", systemImage: "display")
                    }
                }
            }
            .background(WindowIdentifier(identifier: Workspace.windowIdentifier(for: session.id)))
            .onDisappear {
                if model.workspace.session(session.id) != nil {
                    model.workspace.reattach(session.id)
                }
            }
            .frame(minWidth: 640, minHeight: 400)
    }
}

/// Tags the hosting window so the workspace can bring it forward.
private struct WindowIdentifier: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}
