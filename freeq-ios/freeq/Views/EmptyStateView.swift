import SwiftUI

/// A polished, reusable empty state — an icon haloed in glass, a balanced
/// title, a supporting line, and an optional call to action. Replaces the
/// app's icon-plus-two-lines empties with one considered treatment.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 88, height: 88)
                Circle()
                    .strokeBorder(Theme.border, lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Theme.accent)
            }
            .shadow(color: Theme.accent.opacity(0.18), radius: 24, y: 8)

            VStack(spacing: Theme.Space.sm) {
                Text(title)
                    .font(.fqTitle3)
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.fqSubheadline)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.fqCalloutSemibold)
                        .foregroundColor(Color(hex: "04121a"))
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.vertical, Theme.Space.md)
                        .background(Theme.signalGradient, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 4)
                }
                .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}
