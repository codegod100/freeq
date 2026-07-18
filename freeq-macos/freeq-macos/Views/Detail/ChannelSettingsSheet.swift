import SwiftUI

/// Channel settings: topic, modes, ops.
struct ChannelSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let channel: ChannelState
    @State private var newTopic: String = ""
    @State private var policyRules: String = "Be respectful. No harassment, spam, or hate speech."
    @State private var verifierType: String = "github_repo"
    @State private var verifierParam: String = ""
    @State private var verifierLabel: String = "GitHub"
    @State private var roleName: String = "voice"
    @State private var roleCredentialType: String = "github_repo"
    @State private var policyStatus: String?

    // Current (server-side) policy — read-only view so ops can SEE the join
    // gate, roles, and verifiers, not just blindly write them.
    @State private var currentPolicy: ChannelPolicyDoc?
    @State private var currentRules: String?
    @State private var policyLoading = false
    @State private var policyLoadError: String?
    @State private var policyLoadedOnce = false
    @State private var rulesPrefilled = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Channel Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Topic
                    GroupBox("Topic") {
                        VStack(alignment: .leading, spacing: 8) {
                            if !channel.topic.isEmpty {
                                Text(channel.topic)
                                    .font(.body)
                                if let setBy = channel.topicSetBy {
                                    Text("Set by \(setBy)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            HStack {
                                TextField("New topic…", text: $newTopic)
                                    .textFieldStyle(.roundedBorder)
                                Button("Set") {
                                    appState.sendRaw("TOPIC \(channel.name) :\(newTopic)")
                                    newTopic = ""
                                }
                                .disabled(newTopic.isEmpty)
                            }
                        }
                        .padding(4)
                    }

                    // Members
                    GroupBox("Members (\(channel.uniqueMemberCount(resolveDid: { ProfileCache.shared.did(for: $0) })))") {
                        VStack(alignment: .leading, spacing: 4) {
                            let ops = channel.members.filter(\.isOp)
                            let voiced = channel.members.filter { $0.isVoiced && !$0.isOp }

                            if !ops.isEmpty {
                                Text("Operators: \(ops.map(\.nick).joined(separator: ", "))")
                                    .font(.caption)
                            }
                            if !voiced.isEmpty {
                                Text("Voiced: \(voiced.map(\.nick).joined(separator: ", "))")
                                    .font(.caption)
                            }
                        }
                        .padding(4)
                    }

                    // Current policy (read-only view)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Current Policy")
                                    .font(.caption.weight(.semibold))
                                if let v = currentPolicy?.version {
                                    Text("v\(v)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if policyLoading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button {
                                        Task { await loadPolicy() }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Refresh")
                                }
                            }

                            currentPolicyBody
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Policy / join gates
                    GroupBox("Policy & Join Gates") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Set rules, add credential verifiers, accept gates, and assign roles using the server's POLICY protocol.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Rules")
                                    .font(.caption.weight(.semibold))
                                TextEditor(text: $policyRules)
                                    .font(.body)
                                    .frame(minHeight: 70)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                    )
                                HStack {
                                    Button {
                                        sendPolicy("SET \(policyRules.trimmingCharacters(in: .whitespacesAndNewlines))")
                                    } label: {
                                        Label("Set Rules", systemImage: "doc.badge.gearshape")
                                    }
                                    .disabled(policyRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                    Button {
                                        sendPolicy("INFO")
                                    } label: {
                                        Label("Info", systemImage: "info.circle")
                                    }

                                    Button {
                                        sendPolicy("ACCEPT")
                                    } label: {
                                        Label("Accept Gate", systemImage: "checkmark.seal")
                                    }
                                }
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Credential Verifier")
                                    .font(.caption.weight(.semibold))
                                Picker("Type", selection: $verifierType) {
                                    Text("GitHub repo").tag("github_repo")
                                    Text("GitHub org").tag("github_membership")
                                    Text("Bluesky follower").tag("bluesky_follower")
                                    Text("Moderator").tag("channel_moderator")
                                }
                                .pickerStyle(.segmented)

                                HStack {
                                    TextField(verifierPlaceholder, text: $verifierParam)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Label", text: $verifierLabel)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 110)
                                    Button {
                                        addVerifier()
                                    } label: {
                                        Label("Require", systemImage: "person.badge.shield.checkmark")
                                    }
                                    .disabled(verifierParam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && verifierType != "channel_moderator")
                                }
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Role by Credential")
                                    .font(.caption.weight(.semibold))
                                HStack {
                                    Picker("Role", selection: $roleName) {
                                        Text("Op").tag("op")
                                        Text("Half-op").tag("halfop")
                                        Text("Voice").tag("voice")
                                    }
                                    .frame(width: 120)
                                    TextField("Credential type", text: $roleCredentialType)
                                        .textFieldStyle(.roundedBorder)
                                    Button {
                                        setRolePolicy()
                                    } label: {
                                        Label("Set Role", systemImage: "person.crop.circle.badge.checkmark")
                                    }
                                    .disabled(roleCredentialType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }

                            HStack {
                                Button(role: .destructive) {
                                    sendPolicy("CLEAR")
                                } label: {
                                    Label("Clear Policy", systemImage: "trash")
                                }
                                Spacer()
                                Button {
                                    if verifierType == "github_repo", !verifierParam.isEmpty {
                                        sendPolicy("VERIFY github \(verifierParam.trimmingCharacters(in: .whitespacesAndNewlines))")
                                    }
                                } label: {
                                    Label("Verify GitHub", systemImage: "checkmark.shield")
                                }
                                .disabled(verifierType != "github_repo" || verifierParam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            if let policyStatus {
                                Text(policyStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(4)
                    }

                    // Actions
                    GroupBox("Actions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Request PINS") {
                                appState.sendRaw("PINS \(channel.name)")
                            }
                            Button("Leave Channel", role: .destructive) {
                                appState.partChannel(channel.name)
                                dismiss()
                            }
                        }
                        .padding(4)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 540, height: 700)
        .onAppear { newTopic = "" }
        .task { await loadPolicy() }
    }

    /// The body of the read-only "Current Policy" box: loading / error / none /
    /// details (join gate, rules text, role gating, verifiers).
    @ViewBuilder
    private var currentPolicyBody: some View {
        if let err = policyLoadError {
            Label("Couldn't load policy: \(err)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if currentPolicy == nil {
            if policyLoadedOnce {
                Label("No policy set — this channel is open to join.", systemImage: "lock.open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let policy = currentPolicy {
            VStack(alignment: .leading, spacing: 10) {
                // Join gate
                VStack(alignment: .leading, spacing: 2) {
                    Text("Join gate")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(policy.requirements.describe())
                        .font(.caption)
                    Text(policy.requirements.technical())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                // Rules text (the thing you actually want to read)
                if let rules = currentRules, !rules.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rules")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(rules)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if case .accept = policy.requirements {
                    Text("Rules text not stored for this policy (set before rules storage, or received over S2S).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Role gating (e.g. op → github credential)
                if !policy.roleRequirements.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Role requirements")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(policy.roleRequirements.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                            Text("\(entry.key): \(entry.value.describe())")
                                .font(.caption)
                        }
                    }
                }

                // Verifiers / credential endpoints
                if !policy.credentialEndpoints.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verifiers")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(policy.credentialEndpoints.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                            Text("\(entry.value.label) (\(entry.key))")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var verifierPlaceholder: String {
        switch verifierType {
        case "github_repo": return "owner/repo"
        case "github_membership": return "org-name"
        case "bluesky_follower": return "handle.bsky.social"
        default: return "optional"
        }
    }

    private func sendPolicy(_ command: String) {
        appState.sendRaw("POLICY \(channel.name) \(command)")
        policyStatus = "Sent: POLICY \(channel.name) \(command)"
        // Re-read after the server has had a moment to persist the new version.
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await loadPolicy()
        }
    }

    /// Fetch the channel's current policy (and rules text) from the REST API so
    /// the sheet can display what's actually in effect. Read-only.
    @MainActor
    private func loadPolicy() async {
        policyLoading = true
        policyLoadError = nil
        defer { policyLoading = false; policyLoadedOnce = true }

        let base = ServerConfig.apiBaseUrl
        let enc = channel.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? channel.name

        // Policy document.
        if let url = URL(string: "\(base)/api/v1/policy/\(enc)") {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 {
                    currentPolicy = nil
                } else if code == 200 {
                    currentPolicy = try JSONDecoder().decode(ChannelPolicyDoc.self, from: data)
                } else {
                    policyLoadError = "HTTP \(code)"
                }
            } catch {
                policyLoadError = error.localizedDescription
            }
        }

        // Human-readable rules text (may 404 even when a policy exists, if the
        // policy predates rules-text storage or arrived over S2S).
        currentRules = nil
        if let url = URL(string: "\(base)/api/v1/policy/\(enc)/rules") {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let rules = try? JSONDecoder().decode(ChannelPolicyRules.self, from: data) {
                currentRules = rules.text
            }
        }

        // Seed the editable Rules field with the real text once (don't clobber
        // in-progress edits on later refreshes).
        if !rulesPrefilled, let text = currentRules, !text.isEmpty {
            policyRules = text
            rulesPrefilled = true
        }
    }

    private func addVerifier() {
        let param = verifierParam.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: String
        switch verifierType {
        case "github_repo":
            url = "/verify/github/start?repo=\(param.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? param)"
        case "github_membership":
            url = "/verify/github/start?org=\(param.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? param)"
        case "bluesky_follower":
            url = "/verify/bluesky/start?target=\(param.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? param)"
        default:
            url = "/verify/mod/start"
        }
        let label = verifierLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        sendPolicy("REQUIRE \(verifierType) issuer=\(policyIssuer) url=\(url) label=\(label.isEmpty ? verifierType : label)")
    }

    private func setRolePolicy() {
        let type = roleCredentialType.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = #"{"type":"PRESENT","credential_type":"\#(type)","issuer":"\#(policyIssuer)"}"#
        sendPolicy("SET-ROLE \(roleName) \(json)")
    }

    private var policyIssuer: String {
        "did:web:irc.freeq.at:verify"
    }
}
