import RDPManagerCore
import SwiftUI

/// Overview plus one tab per session, each showing the session's real state. Tabs reorder by
/// dragging; the context menu moves one into its own window.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let workspace = model.workspace
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                TabButton(
                    isSelected: workspace.selectedTab == .overview,
                    action: { workspace.selectedTab = .overview }
                ) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                    Text("Overview")
                }
                .keyboardShortcutHint("⌘0")

                ForEach(workspace.tabbedSessions) { session in
                    TabButton(
                        isSelected: workspace.selectedTab == .session(session.id),
                        action: { workspace.selectedTab = .session(session.id) },
                        onClose: { workspace.close(session) }
                    ) {
                        StatusDot(phase: session.phase)
                        Text(session.title)
                            .lineLimit(1)
                    }
                    .help("\(session.hostLabel) — \(session.phase.shortLabel)")
                    .draggable("tab:\(session.id.uuidString)")
                    .dropDestination(for: String.self) { items, _ in
                        guard let payload = items.first, payload.hasPrefix("tab:"),
                              let id = UUID(uuidString: String(payload.dropFirst(4))), id != session.id
                        else { return false }
                        withAnimation(.snappy) { workspace.moveTab(id, before: session.id) }
                        return true
                    }
                    .contextMenu {
                        SessionControlMenuItems(session: session, showsShowSession: false)
                        Divider()
                        Button("Move to New Window") {
                            workspace.markDetached(session.id)
                            openWindow(id: "session", value: session.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(height: 36)
        .background(.bar)
    }
}

private struct TabButton<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    var onClose: (() -> Void)?
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            label()
                .font(.callout.weight(isSelected ? .semibold : .regular))
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovering || isSelected ? 1 : 0)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, onClose == nil ? 10 : 5)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.background.opacity(0.9)) : (isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear)))
                .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1.5, y: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", action)
    }
}

private extension View {
    func keyboardShortcutHint(_ hint: String) -> some View {
        help("Overview (\(hint))")
    }
}
