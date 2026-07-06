import SwiftUI

/// A member's live presence, one consistent indicator across DM rows, member
/// lists, and profiles. Online is the verify green (a real, resolved presence),
/// away the warning amber, offline a quiet neutral.
struct PresenceDot: View {
    enum Presence { case online, away, offline }

    let presence: Presence
    var size: CGFloat = 10
    /// A ring in the surrounding surface color, so the dot reads as a status
    /// pip riveted onto an avatar rather than floating.
    var ringColor: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var color: Color {
        switch presence {
        case .online: return Theme.verify
        case .away: return Theme.warning
        case .offline: return Theme.textMuted.opacity(0.55)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if let ringColor {
                    Circle().strokeBorder(ringColor, lineWidth: size * 0.22)
                }
            }
            // A slow, quiet halo pulse for a genuinely-present person — makes
            // "online" feel alive rather than a static pip. Online only, and
            // never under Reduce Motion.
            .background {
                if presence == .online && !reduceMotion {
                    Circle()
                        .fill(Theme.verify)
                        .frame(width: size, height: size)
                        .scaleEffect(pulse ? 2.4 : 1.0)
                        .opacity(pulse ? 0 : 0.5)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                }
            }
            .shadow(color: presence == .online ? Theme.verify.opacity(0.6) : .clear,
                    radius: size * 0.4)
            .accessibilityLabel(label)
    }

    private var label: String {
        switch presence {
        case .online: return "Online"
        case .away: return "Away"
        case .offline: return "Offline"
        }
    }
}
