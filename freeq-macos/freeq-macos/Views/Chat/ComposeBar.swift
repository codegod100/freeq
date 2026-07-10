import AVFoundation
@preconcurrency import Speech
import SwiftUI

struct ComposeBar: View {
    @Environment(AppState.self) private var appState
    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    /// Bumped on .onAppear and whenever `activeChannel` changes — the
    /// ComposeTextView watches this token and grabs first-responder
    /// status so the user can start typing immediately.
    @State private var focusToken: Int = 0
    @State private var pendingUpload: PendingUpload?
    @State private var isUploading = false
    @State private var autocompleteIndex: Int = 0
    /// Set when the user presses Esc while the autocomplete popup is open —
    /// hides it until the draft changes again (so Esc dismisses the menu
    /// instead of clearing the whole message).
    @State private var autocompleteDismissed = false
    @State private var voiceRecorder: AVAudioRecorder?
    @State private var voiceRecordingURL: URL?
    @State private var voiceRecordingTime: TimeInterval = 0
    @State private var voiceTimer: Timer?
    @State private var isRecordingVoice = false
    @State private var isUploadingVoice = false
    @State private var isTranscribingVoice = false
    @State private var voiceError: String?
    @AppStorage("freeq.crossPostBluesky") private var crossPostBluesky = false

    private var isEditing: Bool { appState.editingMessageId != nil }
    private var isReplying: Bool { appState.replyingToMessage != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Reply/Edit banner
            if let reply = appState.replyingToMessage {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundColor(Theme.accent)
                    Text("Replying to **\(reply.from)**")
                        .font(.caption)
                    Text(reply.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button { appState.replyingToMessage = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Theme.accentSoft)
            }

            if isEditing {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    Text("Editing message")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    Spacer()
                    Button {
                        appState.editingMessageId = nil
                        appState.editingText = nil
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Theme.warning.opacity(0.08))
            }

            // Upload preview
            if let upload = pendingUpload {
                HStack(spacing: 8) {
                    if let preview = upload.preview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(upload.filename)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if isUploading {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        if let error = upload.error {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Button { pendingUpload = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Theme.surfaceSoft)
            }

            if isRecordingVoice || isUploadingVoice || voiceError != nil {
                HStack(spacing: 8) {
                    Image(systemName: isRecordingVoice ? "record.circle.fill" : (voiceError == nil ? "waveform" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(isRecordingVoice ? Theme.danger : (voiceError == nil ? Theme.blue : Theme.warning))
                    if isRecordingVoice {
                        Text("Recording \(formatDuration(voiceRecordingTime))")
                            .font(.caption.weight(.medium))
                    } else if isUploadingVoice {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(isTranscribingVoice ? "Transcribing and sending voice message..." : "Sending voice message...")
                            .font(.caption)
                    } else if let voiceError {
                        Text(voiceError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if isRecordingVoice {
                        Button("Cancel") { cancelVoiceRecording() }
                            .font(.caption)
                    } else if voiceError != nil {
                        Button {
                            self.voiceError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Theme.surfaceSoft)
            }

            // Autocomplete popup
            AutocompletePopup(text: $text, selectedIndex: $autocompleteIndex,
                              suppressed: autocompleteDismissed)

            // Two-row composer: the text field spans the full width on its own
            // row, and the action buttons sit on a compact row below it.
            // (Previously everything shared one row, so the file/mic/format/
            // emoji/send controls ate the width and the typing area was squeezed
            // to a thin strip in a narrow window.)
            VStack(spacing: 6) {
                // Text editor — full width
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message \(appState.activeChannel ?? "")…")
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                    }
                    ComposeTextView(
                        text: $text,
                        onSubmit: send,
                        onUpArrow: editLastMessage,
                        onHistoryPrev: recallHistoryPrevious,
                        onHistoryNext: recallHistoryNext,
                        members: appState.activeChannelState?.members.map(\.nick) ?? [],
                        focusToken: focusToken,
                        autocompleteActive: { !currentSuggestions.isEmpty },
                        autocompleteAccept: acceptAutocomplete,
                        autocompleteMove: moveAutocomplete,
                        autocompleteCancel: { autocompleteDismissed = true }
                    )
                    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: text) { autocompleteDismissed = false }
                }
                // Establish full width BEFORE the rounded background/border are
                // drawn — otherwise the box sizes to the placeholder's intrinsic
                // width and renders as a narrow strip.
                .frame(maxWidth: .infinity)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.surfaceSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isFocused ? Theme.accent.opacity(0.35) : Theme.borderSoft, lineWidth: 1)
                )

                // Action row: attachments + formatting on the left, send on the right.
                HStack(spacing: 8) {
                    // File picker button
                    Button { pickFile() } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(appState.authenticatedDID == nil ? Theme.textTertiary.opacity(0.45) : Theme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Attach file (images)")
                    .disabled(appState.authenticatedDID == nil)

                    Button {
                        toggleVoiceRecording()
                    } label: {
                        Image(systemName: isRecordingVoice ? "stop.circle.fill" : "mic.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isRecordingVoice ? Theme.danger : Theme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(isRecordingVoice ? "Stop and send voice message" : "Record voice message")
                    .disabled(appState.authenticatedDID == nil || isUploadingVoice || pendingUpload != nil)

                    // Format toolbar
                    FormatToolbar(text: $text)

                    // Emoji button (system picker)
                    Button {
                        NSApp.orderFrontCharacterPalette(nil)
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Emoji (⌘⌃Space)")

                    Spacer()

                    // Cross-post toggle
                    if appState.authenticatedDID != nil {
                        Button {
                            crossPostBluesky.toggle()
                        } label: {
                            Image(systemName: crossPostBluesky ? "cloud.fill" : "cloud")
                                .font(.caption)
                                .foregroundStyle(crossPostBluesky ? Theme.blue : Theme.textSecondary)
                                .frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help(crossPostBluesky ? "Cross-posting to Bluesky (click to disable)" : "Cross-post to Bluesky")
                    }

                    // Send button
                    Button { send() } label: {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(text.isEmpty && pendingUpload == nil ? Theme.textTertiary.opacity(0.55) : (isEditing ? Theme.warning : Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty && pendingUpload == nil)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.surfaceElevated)
                    .shadow(color: .black.opacity(0.06), radius: 14, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.borderSoft, lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Theme.chatBackground)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .onChange(of: text) { _, newValue in
            if !newValue.isEmpty, let target = appState.activeChannel {
                appState.sendTyping(target: target)
            }
        }
        .onChange(of: appState.editingText) { _, newValue in
            if let newValue {
                text = newValue
            }
        }
        // Focus the compose bar on first appear and on every channel
        // change so the user can start typing immediately after a
        // sidebar selection — no extra click into the input required.
        .onAppear { focusToken &+= 1 }
        .onChange(of: appState.activeChannel) { _, _ in
            focusToken &+= 1
            composeHistory.cancelRecall()
        }
        .onDisappear {
            voiceTimer?.invalidate()
            voiceRecorder?.stop()
        }
    }

    // Input history (⌘↑/⌘↓ recall — plain ↑ stays edit-last)
    @State private var composeHistory = ComposeHistory()

    // MARK: - Autocomplete keyboard handling

    /// The suggestions currently shown in the popup (empty when dismissed) —
    /// the composer's key handling accepts/navigates exactly these.
    private var currentSuggestions: [ComposeAutocomplete.Suggestion] {
        guard !autocompleteDismissed else { return [] }
        let members = ComposeAutocomplete.members(from: appState.activeChannelState?.members ?? [])
        return ComposeAutocomplete.suggestions(text: text, members: members)
    }

    /// Accept the highlighted suggestion (Tab/Return). Returns false when there
    /// is nothing to accept, so the caller can fall through to its default.
    private func acceptAutocomplete() -> Bool {
        let items = currentSuggestions
        guard !items.isEmpty else { return false }
        let idx = min(max(0, autocompleteIndex), items.count - 1)
        text = ComposeAutocomplete.accept(items[idx], in: text)
        autocompleteIndex = 0
        return true
    }

    /// Move the highlight up (-1) or down (+1), wrapping around.
    private func moveAutocomplete(_ delta: Int) {
        let count = currentSuggestions.count
        guard count > 0 else { return }
        autocompleteIndex = ((autocompleteIndex + delta) % count + count) % count
    }

    private func send() {
        // Handle pending upload
        if pendingUpload != nil {
            uploadAndSend()
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let target = appState.activeChannel else { return }

        composeHistory.record(trimmed)

        // Convert :shortcode: emoji in plain messages (not slash-commands) so
        // typing ":wave:" sends 👋 like every other chat app.
        let outgoing = trimmed.hasPrefix("/")
            ? trimmed
            : ComposeAutocomplete.replacingShortcodes(trimmed)

        // All command/edit/reply/message handling lives in AppState so the UI
        // and the test-mode bridge share one code path.
        appState.onComposeMediaRequest = { pickFile() }
        appState.submitInput(outgoing, target: target)
        text = ""
    }

    private func recallHistoryPrevious() {
        if let recalled = composeHistory.recallPrevious(draft: text) {
            text = recalled
        }
    }

    private func recallHistoryNext() {
        if let next = composeHistory.recallNext() {
            text = next
        }
    }

    private func editLastMessage() {
        guard text.isEmpty, let target = appState.activeChannel else { return }
        if let lastMsg = appState.lastOwnMessage(in: target) {
            appState.editingMessageId = lastMsg.id
            appState.editingText = lastMsg.text
            text = lastMsg.text
        }
    }

    // MARK: - File Upload

    private func pickFile() {
        let panel = NSOpenPanel()
        // Media types stay first so the picker highlights them, but `.data`
        // (the root byte-data type) makes ANY file selectable — HTML, text,
        // archives, etc. Uploads of unknown/HTML types go up as
        // application/octet-stream (see loadFile), so they download rather than
        // render inline from the freeq origin.
        panel.allowedContentTypes = [
            .image, .png, .jpeg, .gif, .mpeg4Movie, .movie, .mp3, .wav, .mpeg4Audio, .pdf,
            .html, .plainText, .json, .data,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async { loadFile(url: url) }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { item, _ in
                    if let image = item as? NSImage {
                        DispatchQueue.main.async {
                            if let tiff = image.tiffRepresentation,
                               let rep = NSBitmapImageRep(data: tiff),
                               let png = rep.representation(using: .png, properties: [:]) {
                                pendingUpload = PendingUpload(
                                    data: png, filename: "paste.png",
                                    contentType: "image/png", preview: image
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadFile(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "png": contentType = "image/png"
        case "jpg", "jpeg": contentType = "image/jpeg"
        case "gif": contentType = "image/gif"
        case "webp": contentType = "image/webp"
        case "mp4", "m4v": contentType = "video/mp4"
        case "mov": contentType = "video/quicktime"
        case "mp3": contentType = "audio/mpeg"
        case "m4a": contentType = "audio/mp4"
        case "wav": contentType = "audio/wav"
        case "ogg": contentType = "audio/ogg"
        case "pdf": contentType = "application/pdf"
        case "txt", "log", "md": contentType = "text/plain"
        case "json": contentType = "application/json"
        case "csv": contentType = "text/csv"
        case "html", "htm":
            // Served as a download (octet-stream), never inline text/html —
            // serving user HTML from the freeq origin would be stored XSS.
            contentType = "application/octet-stream"
        default: contentType = "application/octet-stream"
        }
        let preview = NSImage(contentsOf: url)
        pendingUpload = PendingUpload(data: data, filename: filename, contentType: contentType, preview: preview)
    }

    private func uploadAndSend() {
        guard let upload = pendingUpload,
              let did = appState.authenticatedDID,
              let target = appState.activeChannel else { return }

        isUploading = true
        Task {
            do {
                let url = try await FileUploader.upload(
                    data: upload.data,
                    filename: upload.filename,
                    contentType: upload.contentType,
                    did: did,
                    channel: target.hasPrefix("#") ? target : nil
                )
                let msgText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalText = msgText.isEmpty ? url : "\(msgText) \(url)"
                await MainActor.run {
                    appState.sendMessage(to: target, text: finalText)
                    pendingUpload = nil
                    isUploading = false
                    text = ""
                }
            } catch let failure as UploadResponse.Failure {
                await MainActor.run {
                    if case .stepUpRequired(let purpose, let url) = failure {
                        FileUploader.beginStepUp(purpose: purpose, path: url, did: did)
                    }
                    pendingUpload?.error = failure.userMessage
                    isUploading = false
                }
            } catch {
                await MainActor.run {
                    pendingUpload?.error = error.localizedDescription
                    isUploading = false
                }
            }
        }
    }

    // MARK: - Voice Recording

    private func toggleVoiceRecording() {
        if isRecordingVoice {
            stopVoiceRecordingAndSend()
        } else {
            startVoiceRecording()
        }
    }

    private func startVoiceRecording() {
        guard appState.authenticatedDID != nil else {
            voiceError = "Voice messages require AT Protocol authentication."
            return
        }
        voiceError = nil
        let begin = {
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("freeq-voice-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.isMeteringEnabled = true
                recorder.record()
                voiceRecorder = recorder
                voiceRecordingURL = url
                voiceRecordingTime = 0
                isRecordingVoice = true
                voiceTimer?.invalidate()
                voiceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    voiceRecordingTime = recorder.currentTime
                    if voiceRecordingTime >= 300 {
                        stopVoiceRecordingAndSend()
                    }
                }
            } catch {
                voiceError = "Could not start recording: \(error.localizedDescription)"
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { begin() }
                    else { voiceError = "Microphone access is required to record voice messages." }
                }
            }
        default:
            voiceError = "Microphone access is required to record voice messages."
        }
    }

    private func stopVoiceRecordingAndSend() {
        voiceTimer?.invalidate()
        voiceTimer = nil
        guard let recorder = voiceRecorder, isRecordingVoice else { return }
        // Read the duration BEFORE stop(): AVAudioRecorder.currentTime is
        // only valid while recording and returns 0 afterwards — reading it
        // post-stop made every recording measure 0s and get rejected as
        // "too short". The timer-tracked time is the fallback in case the
        // recorder is already winding down.
        let duration = max(recorder.currentTime, voiceRecordingTime)
        recorder.stop()
        voiceRecorder = nil
        isRecordingVoice = false
        let url = recorder.url
        if duration < 0.5 {
            try? FileManager.default.removeItem(at: url)
            voiceRecordingURL = nil
            voiceRecordingTime = 0
            voiceError = "Voice message was too short."
            return
        }
        sendVoiceRecording(url: url, duration: duration)
    }

    private func cancelVoiceRecording() {
        voiceTimer?.invalidate()
        voiceTimer = nil
        voiceRecorder?.stop()
        if let url = voiceRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        voiceRecorder = nil
        voiceRecordingURL = nil
        voiceRecordingTime = 0
        isRecordingVoice = false
        voiceError = nil
    }

    private func sendVoiceRecording(url: URL, duration: TimeInterval) {
        guard let did = appState.authenticatedDID,
              let target = appState.activeChannel,
              let data = try? Data(contentsOf: url) else { return }
        let durationLabel = formatDuration(duration)
        isUploadingVoice = true
        isTranscribingVoice = true
        Task {
            async let transcript = MacVoiceTranscriber.transcribe(url)
            do {
                let uploaded = try await FileUploader.upload(
                    data: data,
                    filename: url.lastPathComponent,
                    contentType: "audio/mp4",
                    did: did,
                    channel: target.hasPrefix("#") ? target : nil
                )
                let cleanedTranscript = (await transcript)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let body: String
                if let cleanedTranscript, !cleanedTranscript.isEmpty {
                    body = "🎤 Voice message (\(durationLabel)) \(uploaded)\n💬 \(cleanedTranscript)"
                } else {
                    body = "🎤 Voice message (\(durationLabel)) \(uploaded)"
                }
                await MainActor.run {
                    appState.sendMessage(to: target, text: body)
                    isUploadingVoice = false
                    isTranscribingVoice = false
                    voiceRecordingURL = nil
                    voiceRecordingTime = 0
                    voiceError = nil
                }
            } catch {
                _ = await transcript
                await MainActor.run {
                    isUploadingVoice = false
                    isTranscribingVoice = false
                    voiceError = "Voice upload failed: \(error.localizedDescription)"
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

}

enum MacVoiceTranscriber {
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined {
            return SFSpeechRecognizer.authorizationStatus()
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func transcribe(_ url: URL) async -> String? {
        let status = await requestAuthorization()
        guard status == .authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { continuation in
            var resumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal, !resumed {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil, !resumed {
                    resumed = true
                    continuation.resume(returning: nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if !resumed {
                    resumed = true
                    task.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// NSTextView wrapper that handles Enter vs Shift+Enter, Up arrow, and Tab completion.
struct ComposeTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onUpArrow: () -> Void
    var onHistoryPrev: (() -> Void)? = nil
    var onHistoryNext: (() -> Void)? = nil
    var members: [String]  // For tab completion
    /// Monotonic token bumped by the parent when the input should grab
    /// keyboard focus — e.g. after the user switches channels or the
    /// view appears. The coordinator remembers the last value it acted
    /// on so re-renders that didn't change the token don't steal focus
    /// from the user mid-type.
    var focusToken: Int = 0
    /// Autocomplete popup wiring: whether the popup is showing, accept the
    /// highlighted item (returns true if handled), move the highlight
    /// (±1), and dismiss it. Lets ↑/↓ navigate and Tab/Return accept.
    var autocompleteActive: (() -> Bool)? = nil
    var autocompleteAccept: (() -> Bool)? = nil
    var autocompleteMove: ((Int) -> Void)? = nil
    var autocompleteCancel: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = ComposeNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.allowsUndo = true

        // Apple Intelligence Writing Tools in the composer (macOS 15+):
        // inline proofread / rewrite / tone on the drafted message. `.complete`
        // gives the inline experience; it operates on the plain text we send,
        // so no wire-format change is needed. (Genmoji-in-messages is a
        // separate, larger effort — it needs an adaptive-image-glyph wire
        // format across the server and all clients; the composer's sendable-
        // text extraction already strips stray glyph placeholders so nothing
        // breaks in the meantime.)
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
        }
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Track the scroll view's width. Without `.width` in the autoresizing
        // mask the text view keeps whatever (narrow) frame it had when
        // makeNSView ran — before SwiftUI had laid the scroll view out — so
        // the editable area renders as a thin column no matter how wide the
        // bar is. With it, the text container (widthTracksTextView) follows.
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.submitAction = onSubmit
        textView.upArrowAction = onUpArrow
        textView.historyPrevAction = onHistoryPrev
        textView.historyNextAction = onHistoryNext
        textView.autocompleteActive = autocompleteActive
        textView.autocompleteAccept = autocompleteAccept
        textView.autocompleteMove = autocompleteMove
        textView.autocompleteCancel = autocompleteCancel

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposeNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.submitAction = onSubmit
        textView.upArrowAction = onUpArrow
        textView.historyPrevAction = onHistoryPrev
        textView.historyNextAction = onHistoryNext
        textView.autocompleteActive = autocompleteActive
        textView.autocompleteAccept = autocompleteAccept
        textView.autocompleteMove = autocompleteMove
        textView.autocompleteCancel = autocompleteCancel
        textView.members = members

        // Honour focus-token bumps. Defer to the next runloop so the
        // window has finished mounting the new compose bar before we
        // ask it to make the text view first responder — otherwise on
        // a sidebar selection change we'd race the view installation.
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposeTextView
        /// Last focus-token we acted on. Starts at -1 so the first
        /// `focusToken=0` from the parent counts as a fresh request and
        /// the compose bar takes focus on initial mount.
        var lastFocusToken: Int = -1

        init(parent: ComposeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = ComposeTextExtraction.sendable(textView.string)
        }
    }
}

class ComposeNSTextView: NSTextView {
    /// The composer that most recently had keyboard focus — lets the
    /// format toolbar (plain SwiftUI buttons, which never become first
    /// responder) reach the real selection.
    static weak var activeInstance: ComposeNSTextView?

    var submitAction: (() -> Void)?
    var upArrowAction: (() -> Void)?
    var historyPrevAction: (() -> Void)?
    var historyNextAction: (() -> Void)?
    var autocompleteActive: (() -> Bool)?
    var autocompleteAccept: (() -> Bool)?
    var autocompleteMove: ((Int) -> Void)?
    var autocompleteCancel: (() -> Void)?
    var members: [String] = []
    private var tabCompletionCandidates: [String] = []
    private var tabCompletionIndex: Int = 0
    private var tabCompletionPrefix: String = ""

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { Self.activeInstance = self }
        return ok
    }

    /// Wrap the current selection in markdown markers and restore a
    /// useful selection (see ComposeFormatting for the rules).
    func applyFormat(prefix: String, suffix: String, placeholder: String? = nil) {
        let sel = selectedRange()
        let result = ComposeFormatting.wrap(
            text: string,
            selectionLocation: sel.location,
            selectionLength: sel.length,
            prefix: prefix, suffix: suffix, placeholder: placeholder)
        string = result.text
        setSelectedRange(NSRange(location: result.selectionLocation, length: result.selectionLength))
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // ⌘↑ / ⌘↓ = input history recall
        if event.modifierFlags.contains(.command) && event.keyCode == 126 {
            historyPrevAction?()
            return
        }
        if event.modifierFlags.contains(.command) && event.keyCode == 125 {
            historyNextAction?()
            return
        }

        // When the autocomplete popup is open it captures navigation + accept,
        // matching Slack/Discord: ↑/↓ move, Tab or Return accept, Esc dismiss.
        // (Before this, Return sent "@zap" and Tab silently no-op'd.)
        if autocompleteActive?() == true {
            switch event.keyCode {
            case 48:  // Tab
                if autocompleteAccept?() == true { return }
            case 36 where !event.modifierFlags.contains(.shift):  // Return
                if autocompleteAccept?() == true { return }
            case 125:  // Down
                autocompleteMove?(1); return
            case 126:  // Up
                autocompleteMove?(-1); return
            case 53:  // Esc — dismiss the menu, keep the draft
                autocompleteCancel?(); return
            default:
                break
            }
        }

        // Enter without Shift = send
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            resetTabCompletion()
            submitAction?()
            return
        }
        // Up arrow when text is empty = edit last
        if event.keyCode == 126 && string.isEmpty {
            upArrowAction?()
            return
        }
        // Escape = cancel edit
        if event.keyCode == 53 {
            string = ""
            resetTabCompletion()
            NotificationCenter.default.post(name: .cancelEdit, object: nil)
            return
        }
        // Tab = in-place nick completion (IRC-style cycle) when no popup is up.
        if event.keyCode == 48 {
            performTabCompletion()
            return
        }
        // Any other key resets tab completion
        if event.keyCode != 48 {
            resetTabCompletion()
        }
        super.keyDown(with: event)
    }

    private func performTabCompletion() {
        if tabCompletionCandidates.isEmpty {
            // Start new completion
            let text = string
            guard let lastWord = text.split(separator: " ").last else { return }
            let prefix = String(lastWord).lowercased()
            let candidates = members.filter { $0.lowercased().hasPrefix(prefix) }.sorted()
            guard !candidates.isEmpty else { return }

            tabCompletionPrefix = prefix
            tabCompletionCandidates = candidates
            tabCompletionIndex = 0
        } else {
            // Cycle through candidates
            tabCompletionIndex = (tabCompletionIndex + 1) % tabCompletionCandidates.count
        }

        // Replace the prefix with the candidate
        let candidate = tabCompletionCandidates[tabCompletionIndex]
        var text = string
        // Find and replace the last word
        if let range = text.range(of: tabCompletionPrefix, options: [.backwards, .caseInsensitive]) {
            let isStartOfLine = range.lowerBound == text.startIndex ||
                text[text.index(before: range.lowerBound)] == " "
            let suffix = isStartOfLine && text.distance(from: text.startIndex, to: range.lowerBound) == 0 ? ": " : " "
            text.replaceSubrange(range, with: candidate + suffix)
        } else if let prevCandidate = tabCompletionCandidates[safe: tabCompletionIndex == 0 ? tabCompletionCandidates.count - 1 : tabCompletionIndex - 1] {
            // Replace previous candidate
            let suffixes = [": ", " "]
            for suf in suffixes {
                if let range = text.range(of: prevCandidate + suf, options: [.backwards, .caseInsensitive]) {
                    let isStart = range.lowerBound == text.startIndex
                    let newSuf = isStart ? ": " : " "
                    text.replaceSubrange(range, with: candidate + newSuf)
                    break
                }
            }
        }
        string = text
        // Move cursor to end
        setSelectedRange(NSRange(location: string.count, length: 0))
        // Notify delegate of change
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
    }

    private func resetTabCompletion() {
        tabCompletionCandidates = []
        tabCompletionIndex = 0
        tabCompletionPrefix = ""
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Notification.Name {
    static let cancelEdit = Notification.Name("cancelEdit")
}
