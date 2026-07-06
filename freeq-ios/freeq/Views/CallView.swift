import SwiftUI

/// Voice/video call overlay — shown when the user is in an AV session.
/// Camera is off by default (audio only). Tap the camera button to enable video.
struct CallView: View {
    @EnvironmentObject var appState: AppState
    let channel: String

    var body: some View {
        VStack(spacing: 0) {
            // Participant grid — a compact strip, or a full-screen
            // layout when the call has been expanded.
            if appState.isInCall {
                if appState.isCallExpanded {
                    expandedGrid
                } else {
                    participantGrid
                }
            }

            // Controls bar
            if appState.isInCall {
                controlsBar
            }
        }
        .background(Theme.bgPrimary.opacity(0.95))
    }

    private var participantGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Local tile — shows live camera preview when on, avatar when off.
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.bgSecondary)
                            .frame(width: 100, height: 75)

                        if appState.isCameraOn, let cap = appState.localPreviewCapture {
                            LocalPreviewView(capture: cap)
                                .frame(width: 100, height: 75)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text(String(appState.currentNick?.prefix(2).uppercased() ?? "Me"))
                                .font(.fqTitle)
                                .fontWeight(.bold)
                                .foregroundColor(Theme.accent)
                        }
                    }

                    Text("You")
                        .font(.fqCaption2)
                        .foregroundColor(Theme.textSecondary)
                }

                // Remote participants — video tile when frames are arriving,
                // avatar otherwise. The tile always registers a display sink so
                // the next inbound frame can drive it.
                ForEach(appState.callParticipants, id: \.self) { nick in
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.bgSecondary)
                                .frame(width: 100, height: 75)

                            RemoteVideoTile(appState: appState, nick: nick)
                                .frame(width: 100, height: 75)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .opacity(appState.participantsWithVideo.contains(nick) ? 1 : 0)

                            if !appState.participantsWithVideo.contains(nick) {
                                Text(String(nick.prefix(2).uppercased()))
                                    .font(.fqTitle)
                                    .fontWeight(.bold)
                                    .foregroundColor(Theme.accent)
                            }
                        }

                        Text(nick)
                            .font(.fqCaption2)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                // Screen-share tiles — a separate tile per sharer, keyed
                // distinctly from the camera tile above so a participant can
                // share screen and camera at the same time. Letterboxed via
                // RemoteScreenTile (.resizeAspect).
                ForEach(screenSharers, id: \.self) { nick in
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black)
                                .frame(width: 100, height: 75)

                            RemoteScreenTile(appState: appState, nick: nick)
                                .frame(width: 100, height: 75)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        Label(nick, systemImage: "rectangle.on.rectangle")
                            .font(.fqCaption2)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Nicks currently sharing their screen, ordered stably for the grid.
    private var screenSharers: [String] {
        appState.callParticipants.filter {
            appState.participantsWithScreen.contains($0)
        }
    }

    /// Full-screen layout — every tile fills the screen, stacked
    /// vertically, so the call is big enough to actually use on a phone.
    private var expandedGrid: some View {
        VStack(spacing: 6) {
            // Screen shares get top billing — they're the reason you expand.
            ForEach(screenSharers, id: \.self) { nick in
                expandedScreenTile(nick: nick)
            }
            ForEach(appState.callParticipants, id: \.self) { nick in
                expandedTile(nick: nick, isLocal: false)
            }
            expandedTile(nick: appState.currentNick ?? "You", isLocal: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One large letterboxed screen-share tile in the expanded layout.
    @ViewBuilder
    private func expandedScreenTile(nick: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)

            RemoteScreenTile(appState: appState, nick: nick)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                Spacer()
                HStack {
                    Label("\(nick) — screen", systemImage: "rectangle.on.rectangle")
                        .font(.fqCaption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// One large tile in the expanded layout — live video when it's
    /// arriving, an initials avatar otherwise, with a name label.
    @ViewBuilder
    private func expandedTile(nick: String, isLocal: Bool) -> some View {
        let hasVideo =
            isLocal
            ? (appState.isCameraOn && appState.localPreviewCapture != nil)
            : appState.participantsWithVideo.contains(nick)
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.bgSecondary)

            if isLocal, appState.isCameraOn, let cap = appState.localPreviewCapture {
                LocalPreviewView(capture: cap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isLocal {
                RemoteVideoTile(appState: appState, nick: nick)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(hasVideo ? 1 : 0)
            }

            if !hasVideo {
                Text(String(nick.prefix(2).uppercased()))
                    .font(.fqLargeTitle.weight(.bold))
                    .foregroundColor(Theme.accent)
            }

            // Name label, bottom-left.
            VStack {
                Spacer()
                HStack {
                    Text(isLocal ? "You" : nick)
                        .font(.fqCaption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var controlsBar: some View {
        HStack(spacing: 16) {
            // Status — green while healthy, amber "Reconnecting…" inline
            // while the transport is recovering (never a modal alert).
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.callTransportStatus == nil ? Theme.success : Theme.warning)
                    .frame(width: 8, height: 8)

                Text(appState.callTransportStatus
                    ?? "Voice (\(appState.callParticipants.count + 1))")
                    .font(.fqSubheadline)
                    .fontWeight(.medium)
                    .foregroundColor(appState.callTransportStatus == nil ? .green : .orange)
                    .lineLimit(1)
            }

            Spacer()

            // Expand / collapse the call to fill the screen
            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                appState.isCallExpanded.toggle()
            }) {
                Image(systemName: appState.isCallExpanded
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.bgTertiary)
                    .clipShape(Circle())
            }
            .accessibilityLabel(appState.isCallExpanded ? "Collapse call" : "Expand call")

            // Speaker — loud speaker vs handset receiver
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                appState.toggleSpeaker()
            }) {
                Image(systemName: appState.isSpeakerOn ? "speaker.wave.2.fill" : "ear")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(appState.isSpeakerOn ? Theme.accent : Theme.bgTertiary)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Speaker")
            .accessibilityValue(appState.isSpeakerOn ? "On" : "Off")

            // Mute
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                appState.toggleMute()
            }) {
                Image(systemName: appState.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(appState.isMuted ? Theme.danger : Theme.bgTertiary)
                    .clipShape(Circle())
            }
            .accessibilityLabel(appState.isMuted ? "Unmute microphone" : "Mute microphone")

            // Camera
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                appState.toggleCamera()
            }) {
                Image(systemName: appState.isCameraOn ? "video.fill" : "video.slash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(appState.isCameraOn ? Theme.accent : Theme.bgTertiary)
                    .clipShape(Circle())
            }
            .accessibilityLabel(appState.isCameraOn ? "Turn camera off" : "Turn camera on")

            // Leave
            Button(action: {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                appState.leaveCall()
            }) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.danger)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Leave call")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bgSecondary)
    }
}
