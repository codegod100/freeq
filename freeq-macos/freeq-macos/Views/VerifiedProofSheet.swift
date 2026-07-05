import SwiftUI

/// The differentiator, made tangible. Click a verified/signed badge and see
/// the actual proof: the decentralized identifier that IS this person, and the
/// cryptographic key they sign every message with. When opened from a signed
/// message it also asks the server to actually verify that message's signature
/// and reports the CHECKED result — never an assertion.
struct VerifiedProofSheet: View {
    /// The sender's DID, when we've resolved one. nil = signed message from a
    /// sender whose identity hasn't hydrated yet (key card is skipped).
    let did: String?
    var handle: String? = nil
    var displayName: String? = nil
    var nick: String? = nil
    /// When set, prove this specific message was signed by this identity.
    var msgId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var key: SigningKeyInfo? = nil
    @State private var loadingKey = true
    @State private var copied = false
    @State private var verify: VerifyResult? = nil
    @State private var verifying = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    seal
                        .padding(.top, 20)

                    VStack(spacing: 4) {
                        Text(displayName ?? handle.map { "@\($0)" } ?? nick ?? "Verified identity")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                        Text("Verified via the AT Protocol")
                            .font(.caption)
                            .foregroundStyle(Theme.verified)
                    }

                    Text("This is a real, self-owned identity. Its owner holds the key below and signs everything they send — so no one can impersonate them, on freeq or anywhere else on the network.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)

                    if let did {
                        proofCard(
                            label: "Decentralized identifier",
                            icon: "person.text.rectangle",
                            value: did,
                            detail: handle.map { "resolves to @\($0)" },
                            copyable: true
                        )
                    } else {
                        Text("This sender's identity hasn't resolved yet.")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    if let key {
                        proofCard(
                            label: "Message signing key",
                            icon: "signature",
                            value: key.publicKey,
                            detail: "\(key.algorithm.uppercased()) · \(key.sourceLabel)",
                            copyable: false
                        )
                    } else if loadingKey && did != nil {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 8)
                    }

                    if msgId != nil {
                        messageVerdict
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 380, height: 480)
        .background(Theme.appBackground)
        .task { await loadKey() }
        .task { await loadVerification() }
    }

    /// The honest, checked result for a specific message — not an assertion.
    @ViewBuilder private var messageVerdict: some View {
        HStack(spacing: 8) {
            if verifying {
                ProgressView()
                    .controlSize(.small)
                Text("Checking this message's signature…")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else if let v = verify {
                Image(systemName: v.valid ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(v.valid ? Theme.verified : Theme.warning)
                Text(v.summary)
                    .font(.caption)
                    .foregroundStyle(v.valid ? Theme.textSecondary : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: "shield")
                    .foregroundStyle(Theme.textTertiary)
                Text("Signature status unavailable.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceSoft))
    }

    private var seal: some View {
        ZStack {
            Circle()
                .fill(Theme.verified.opacity(0.14))
                .frame(width: 88, height: 88)
                .blur(radius: 10)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Theme.verified)
                .shadow(color: Theme.verified.opacity(0.4), radius: 14)
        }
    }

    private func proofCard(label: String, icon: String, value: String,
                           detail: String?, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
                    .kerning(0.6)
                Spacer()
                if copyable {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Text(copied ? "Copied" : "Copy")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(copied ? Theme.verified : Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceSoft))
    }

    private func loadKey() async {
        guard let did else { loadingKey = false; return }
        defer { loadingKey = false }
        let base = ServerConfig.apiBaseUrl
        let enc = did.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? did
        guard let url = URL(string: "\(base)/api/v1/signing-keys/\(enc)") else { return }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        key = SigningKeyInfo.from(json: json)
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
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Leave verify nil → "unavailable" rather than claiming anything.
            return
        }
        verify = VerifyResult.from(json: json)
    }
}
