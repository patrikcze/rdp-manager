import AppKit
import RDPManagerCore
import SwiftUI

extension TagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }

    var name: String { rawValue.capitalized }

    /// A filled dot for menus. Menus draw SwiftUI symbols as monochrome templates and ignore
    /// tint, so the swatch is a non-template bitmap.
    var swatch: Image {
        Self.swatchImage(NSColor(color))
    }

    static func swatchImage(_ color: NSColor) -> Image {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

/// Picks a color label, with a checkmark on the current one. Used inside menus.
struct ColorLabelPicker: View {
    let current: TagColor?
    let apply: @MainActor @Sendable (TagColor?) -> Void

    var body: some View {
        // A closure literal, not `set: apply`: converting the @MainActor function value to
        // Binding's setter crashes Swift 6.3's IRGen (Xcode 26.x, as on the CI runners).
        Picker("Color", selection: Binding(get: { current }, set: { apply($0) })) {
            Text("None").tag(TagColor?.none)
            Divider()
            ForEach(TagColor.allCases, id: \.self) { color in
                Label { Text(color.name) } icon: { color.swatch }
                    .tag(TagColor?.some(color))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

extension SessionPhase {
    var tint: Color {
        switch self {
        case .connected: .green
        case .connecting, .resolvingCredentials, .reconnecting: .orange
        case .awaitingCredentials, .awaitingCertificateDecision: .yellow
        case let .ended(end): end.kind == .failed ? .red : .secondary
        case .idle: .secondary
        }
    }
}

/// A small dot showing a session's actual state: green only while the desktop shows.
struct StatusDot: View {
    let phase: SessionPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(phase.tint)
            .frame(width: 7, height: 7)
            .opacity(phase.isInProgress && reduceMotion == false ? (pulse ? 0.35 : 1) : 1)
            .animation(phase.isInProgress && reduceMotion == false
                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel(phase.shortLabel)
    }
}

/// A host's badge: a white monitor glyph on a rounded square in its color label (the accent
/// color when it has none). A filled shape keeps its color on a selected sidebar row, where
/// List restyles plain foreground colors.
struct HostIcon: View {
    var color: TagColor?
    var size: CGFloat = 15

    var body: some View {
        let fill = color?.color ?? .accentColor
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(fill.gradient)
            .frame(width: size + 3, height: size + 3)
            .overlay {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// A rounded capsule for tags.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

extension Duration {
    static func since(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60) : String(format: "%d:%02d", minutes, seconds % 60)
    }
}
