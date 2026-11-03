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

/// The monitor glyph for a host, tinted with its color label.
struct HostIcon: View {
    var color: TagColor?
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color?.color ?? .accentColor)
            .symbolRenderingMode(.hierarchical)
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
