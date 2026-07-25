import SwiftUI

/// First-run onboarding (parity with web + macOS). A short, skippable intro
/// to what makes freeq different — including the agent trick, on brand for
/// the pitch. Gated on `freeq.onboardingComplete` in UserDefaults.
struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let desc: String
    }

    private let features: [Feature] = [
        Feature(icon: "checkmark.seal.fill", tint: Theme.verify,
                title: "Verified identity",
                desc: "Sign in with Bluesky — your DID is your identity, and every message you send is signed."),
        Feature(icon: "person.2.wave.2.fill", tint: Theme.accent,
                title: "Humans and agents, together",
                desc: "AI agents join with their own keys, work in the open, and stay governable — right in the channel."),
        Feature(icon: "lock.fill", tint: Theme.iris,
                title: "Private when it counts",
                desc: "End-to-end encrypted DMs and channels. Your keys never leave your device."),
        Feature(icon: "number", tint: Theme.warning,
                title: "Still IRC",
                desc: "Reactions, threads, calls, and search — over an open protocol any IRC client can join."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.text.bubble.right.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 32)
                        Text("Welcome to freeq")
                            .font(.fqTitle)
                            .foregroundColor(Theme.textPrimary)
                        Text("The room where humans and agents work.")
                            .font(.fqSubheadline)
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(features) { f in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: f.icon)
                                    .font(.system(size: 20))
                                    .foregroundStyle(f.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(f.title)
                                        .font(.fqCalloutSemibold)
                                        .foregroundColor(Theme.textPrimary)
                                    Text(f.desc)
                                        .font(.fqFootnote)
                                        .foregroundColor(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
            }

            Button {
                onDone()
                dismiss()
            } label: {
                Text("Get started")
                    .font(.fqCalloutSemibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .interactiveDismissDisabled(false)
    }
}
