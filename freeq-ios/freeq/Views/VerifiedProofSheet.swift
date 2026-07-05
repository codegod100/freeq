import SwiftUI

/// The differentiator, made tangible. Tap a verified seal anywhere and see the
/// actual proof: the decentralized identifier that IS this person, and the
/// cryptographic key they sign every message with. No other chat app can show
/// this, because no other chat app's identities are real.
struct VerifiedProofSheet: View {
    let did: String
    var handle: String? = nil
    var displayName: String? = nil
    /// When set, prove this specific message was signed by this identity.
    var msgId: String? = nil

    @Environment(\.dismiss) var dismiss
    @State private var key: SigningKeyInfo? = nil
    @State private var loading = true
    @State private var copied = false
    @State private var verify: VerifyResult? = nil
    @State private var verifying = false

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            RadialGradient(colors: [Theme.verify.opacity(0.14), .clear],
                           center: .top, startRadius: 0, endRadius: 320)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    seal
                    VStack(spacing: 4) {
                        Text(displayName ?? handle.map { "@\($0)" } ?? "Verified identity")
                            .font(.fqTitle3.weight(.bold))
                            .foregroundColor(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                        Text("Verified via the AT Protocol")
                            .font(.fqFootnote)
                            .foregroundColor(Theme.verify)
                    }

                    Text("This is a real, self-owned identity. Its owner holds the key below and signs everything they send — so no one can impersonate them, on freeq or anywhere else on the network.")
                        .font(.fqSubheadline)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)

                    proofCard(
                        label: "Decentralized identifier",
                        icon: "person.text.rectangle",
                        value: did,
                        detail: handle.map { "resolves to @\($0)" },
                        copyable: true
                    )

                    if let key {
                        proofCard(
                            label: "Message signing key",
                            icon: "signature",
                            value: key.publicKey,
                            detail: "\(key.algorithm.uppercased()) · \(key.sourceLabel)",
                            copyable: false
                        )
                    } else if loading {
                        ProgressView().tint(Theme.textMuted).padding(.vertical, 8)
                    }

                    if msgId != nil {
                        messageVerdict
                    }

                    Spacer(minLength: 8)
                }
                .padding(Theme.Space.xl)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
        .task { await loadKey() }
        .task { await loadVerification() }
    }

    /// The honest, checked result for a specific message — not an assertion.
    @ViewBuilder private var messageVerdict: some View {
        HStack(spacing: 8) {
            if verifying {
                ProgressView().scaleEffect(0.7).tint(Theme.textMuted)
                Text("Checking this message's signature…")
                    .font(.fqCaption).foregroundColor(Theme.textMuted)
            } else if let v = verify {
                Image(systemName: v.valid ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundColor(v.valid ? Theme.verify : Theme.warning)
                Text(v.summary)
                    .font(.fqCaption)
                    .foregroundColor(v.valid ? Theme.textSecondary : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: "shield").foregroundColor(Theme.textMuted)
                Text("Signature status unavailable.")
                    .font(.fqCaption).foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(.thin)
    }

    private var seal: some View {
        ZStack {
            Circle()
                .fill(Theme.verify.opacity(0.14))
                .frame(width: 96, height: 96)
                .blur(radius: 10)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Theme.verify)
                .shadow(color: Theme.verify.opacity(0.5), radius: 16)
        }
        .padding(.top, 8)
    }

    private func proofCard(label: String, icon: String, value: String,
                           detail: String?, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text(label.uppercased())
                    .font(.fqCaption2.weight(.bold))
                    .foregroundColor(Theme.textMuted)
                    .kerning(0.6)
                Spacer()
                if copyable {
                    Button {
                        UIPasteboard.general.string = value
                        withAnimation { copied = true }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Text(copied ? "Copied" : "Copy")
                            .font(.fqCaption2.weight(.semibold))
                            .foregroundColor(copied ? Theme.verify : Theme.accent)
                    }
                }
            }
            Text(value)
                .font(.fqMonoCaption)
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.fqCaption2)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(.thin)
    }

    /// Ask the server to actually verify the message's ed25519 signature over
    /// its canonical form, and report exactly what came back.
    private func loadVerification() async {
        guard let msgId else { return }
        verifying = true
        defer { verifying = false }
        let base = ServerConfig.apiBaseUrl
        let enc = msgId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? msgId
        guard let url = URL(string: "\(base)/api/v1/verify/\(enc)") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // The server returns a `verification` object (or null if unsigned).
            let v = json["verification"] as? [String: Any]
            verify = VerifyResult(
                valid: v?["valid"] as? Bool ?? false,
                verifiedBy: v?["verified_by"] as? String ?? "none"
            )
        } catch {
            // Leave verify nil → "unavailable" rather than claiming anything.
        }
    }

    private func loadKey() async {
        let base = ServerConfig.apiBaseUrl
        let enc = did.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? did
        guard let url = URL(string: "\(base)/api/v1/signing-keys/\(enc)") else { loading = false; return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pk = json["public_key"] as? String else { loading = false; return }
            key = SigningKeyInfo(
                publicKey: pk,
                algorithm: json["algorithm"] as? String ?? "ed25519",
                source: json["source"] as? String ?? ""
            )
            loading = false
        } catch {
            loading = false
        }
    }
}

/// The checked outcome of verifying a specific message's signature.
struct VerifyResult {
    let valid: Bool
    let verifiedBy: String   // "client-session-key" | "server-key" | "none"

    var summary: String {
        switch (valid, verifiedBy) {
        case (true, "client-session-key"):
            return "Verified — this message was signed on the sender's own device."
        case (true, "server-key"):
            return "Verified — signed by the server on the sender's behalf."
        case (true, _):
            return "Verified — the signature checks out."
        default:
            return "This message's signature could not be verified."
        }
    }
}

struct SigningKeyInfo {
    let publicKey: String
    let algorithm: String
    let source: String

    /// Client-session keys mean the message was signed on the sender's own
    /// device — true non-repudiation, not the server vouching.
    var sourceLabel: String {
        source == "client-session" ? "signed on their device" : "server-attested"
    }
}
