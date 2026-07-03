import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Voice/video call panel — shown when the user is in an AV session.
///
/// Collapsed: a horizontal strip of small tiles above the composer.
/// Expanded: an adaptive grid (unit-tested `CallGridLayout` picks the column
/// count that maximizes tile area) with a spotlight row for screen shares.
/// Controls include mic/camera device pickers, a screen-source picker
/// (display or window), a live mic meter, and a "talking while muted" hint.
struct CallView: View {
    @Environment(AppState.self) private var appState
    let channel: String

    var body: some View {
        VStack(spacing: 0) {
            if appState.isInCall {
                if !appState.participantsWithScreen.isEmpty {
                    screenSpotlight
                }
                if appState.isCallExpanded { expandedGrid } else { participantStrip }
                if appState.isMuted && appState.isLocalSpeaking {
                    mutedHint
                }
                controlsBar
            }
        }
        .background(.bar)
    }

    // MARK: - Screen-share spotlight (remote /screen broadcasts)

    /// Shared screens get a large letterboxed row above the participant
    /// tiles — `resizeAspect`, never cropped, mirroring the web client's
    /// spotlight treatment.
    private var screenSpotlight: some View {
        HStack(spacing: 8) {
            ForEach(appState.participantsWithScreen.sorted(), id: \.self) { nick in
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.85))
                    RemoteScreenTile(appState: appState, nick: nick)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle.fill").font(.caption2)
                        Text("\(nick)'s screen").font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(8)
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxHeight: appState.isCallExpanded ? .infinity : 260)
    }

    // MARK: - Collapsed strip

    private var participantStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tile(nick: appState.nick.isEmpty ? "You" : appState.nick, label: "You", isLocal: true)
                ForEach(appState.callParticipants, id: \.self) { nick in
                    tile(nick: nick, label: nick, isLocal: false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func tile(nick: String, label: String, isLocal: Bool) -> some View {
        let hasVideo = isLocal
            ? ((appState.isCameraOn && appState.localPreviewCapture != nil) || appState.isScreenSharing)
            : appState.participantsWithVideo.contains(nick)
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 110, height: 80)
                if isLocal, appState.isCameraOn, let cap = appState.localPreviewCapture {
                    LocalSelfView(capture: cap, effectActive: appState.cameraBackgroundEffect.isActive)
                        .frame(width: 110, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .scaleEffect(x: -1)  // mirror self-view, like every meeting app
                } else if isLocal, appState.isScreenSharing {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.title2.weight(.semibold))
                        Text("Sharing screen")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(Theme.accent)
                } else if !isLocal {
                    RemoteVideoTile(appState: appState, nick: nick)
                        .frame(width: 110, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .opacity(hasVideo ? 1 : 0)
                }
                if !hasVideo && !(isLocal && appState.isScreenSharing) {
                    Text(String(nick.prefix(2).uppercased()))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSpeaking(nick: nick, isLocal: isLocal) ? Theme.success : Color.clear,
                        lineWidth: 2
                    )
            )
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Expanded grid

    private var expandedGrid: some View {
        GeometryReader { geo in
            let tiles = gridTiles
            let cols = CallGridLayout.columns(for: tiles.count, in: geo.size)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols),
                spacing: 8
            ) {
                ForEach(tiles) { entry in
                    expandedTile(nick: entry.nick, isLocal: entry.isLocal)
                        .aspectRatio(CallGridLayout.tileAspect, contentMode: .fit)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 280, maxHeight: .infinity)
    }

    private struct GridTile: Identifiable {
        let nick: String
        let isLocal: Bool
        var id: String { (isLocal ? "local-" : "remote-") + nick.lowercased() }
    }

    /// Remote participants first, self last (meeting-app convention).
    private var gridTiles: [GridTile] {
        appState.callParticipants.map { GridTile(nick: $0, isLocal: false) }
            + [GridTile(nick: appState.nick.isEmpty ? "You" : appState.nick, isLocal: true)]
    }

    @ViewBuilder
    private func expandedTile(nick: String, isLocal: Bool) -> some View {
        let hasVideo = isLocal
            ? ((appState.isCameraOn && appState.localPreviewCapture != nil) || appState.isScreenSharing)
            : appState.participantsWithVideo.contains(nick)
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
            if isLocal, appState.isCameraOn, let cap = appState.localPreviewCapture {
                LocalSelfView(capture: cap, effectActive: appState.cameraBackgroundEffect.isActive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(x: -1)
            } else if isLocal, appState.isScreenSharing {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 52, weight: .semibold))
                    Text("Sharing your screen")
                        .font(.headline.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            } else if !isLocal {
                RemoteVideoTile(appState: appState, nick: nick)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(hasVideo ? 1 : 0)
            }
            if !hasVideo && !(isLocal && appState.isScreenSharing) {
                Text(String(nick.prefix(2).uppercased()))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack {
                Spacer()
                HStack {
                    HStack(spacing: 4) {
                        if isLocal && appState.isMuted {
                            Image(systemName: "mic.slash.fill").font(.caption2)
                        }
                        Text(isLocal ? "You" : nick)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    Spacer()
                }
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isSpeaking(nick: nick, isLocal: isLocal) ? Theme.success : Color.clear,
                    lineWidth: 2.5
                )
        )
    }

    /// Speaking ring: local uses the mic meter's debounced flag; remote uses
    /// the SDK's playout levels (AvEvent.audioLevel, R1).
    private func isSpeaking(nick: String, isLocal: Bool) -> Bool {
        if isLocal {
            return appState.isLocalSpeaking && !appState.isMuted
        }
        return (appState.remoteAudioLevels[nick.lowercased()] ?? 0) > 0.05
    }

    // MARK: - Muted-while-talking hint

    private var mutedHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.slash.fill")
            Text("You're talking, but your mic is muted")
            Button("Unmute") { appState.toggleMute() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.warning)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.warning.opacity(0.10))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Controls

    private var controlsBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                if let status = appState.callTransportStatus {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(appState.isScreenSharing ? "Screen" : (appState.isCameraOn ? "Video" : "Voice"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
                if !channel.isEmpty {
                    Text(channel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("· \(appState.callParticipants.count + 1)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            MicLevelBar(level: appState.localMicLevel, muted: appState.isMuted)
                .frame(width: 52, height: 5)

            Spacer()

            controlButton(systemName: appState.isCallExpanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right", active: false,
                help: "Expand or collapse the call") {
                appState.isCallExpanded.toggle()
            }

            // Mute + mic picker
            splitControl(
                systemName: appState.isMuted ? "mic.slash.fill" : "mic.fill",
                active: appState.isMuted, activeColor: .red,
                help: "Mute (⇧⌘M)",
                action: { appState.toggleMute() }
            ) {
                MicPickerMenu()
            }

            // Camera + camera picker
            splitControl(
                systemName: appState.isCameraOn ? "video.fill" : "video.slash.fill",
                active: appState.isCameraOn, activeColor: .accentColor,
                help: "Camera (⇧⌘V)",
                action: { appState.toggleCamera() }
            ) {
                CameraPickerMenu()
            }

            // Screen share + source picker
            splitControl(
                systemName: appState.isScreenSharing ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle",
                active: appState.isScreenSharing, activeColor: Theme.accent,
                help: "Share screen (⇧⌘S)",
                action: { appState.toggleScreenShare() }
            ) {
                ScreenSourcePickerMenu()
            }

            controlButton(systemName: "phone.down.fill", active: true, activeColor: .red,
                          help: "Leave call") {
                appState.leaveCall()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func controlButton(systemName: String, active: Bool,
                               activeColor: Color = .accentColor,
                               help: String = "",
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(active ? activeColor : Color.gray.opacity(0.4))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// A round control with a small chevron menu attached (device pickers),
    /// mirroring the split mute/camera buttons in Zoom/Meet.
    @ViewBuilder
    private func splitControl<M: View>(
        systemName: String, active: Bool, activeColor: Color, help: String,
        action: @escaping () -> Void, @ViewBuilder menu: () -> M
    ) -> some View {
        HStack(spacing: 1) {
            controlButton(systemName: systemName, active: active,
                          activeColor: activeColor, help: help, action: action)
            Menu {
                menu()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 14)
        }
    }
}

// MARK: - Mic level meter

struct MicLevelBar: View {
    let level: Float
    let muted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.25))
                Capsule()
                    .fill(muted ? Color.gray.opacity(0.6) : Theme.success)
                    .frame(width: max(0, geo.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .help(muted ? "Mic level (muted — not transmitting)" : "Mic level")
    }
}

// MARK: - Device picker menus

struct MicPickerMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let devices = AudioInputDevices.list()
        Section("Microphone") {
            Button {
                appState.setMicDevice(uid: nil)
            } label: {
                menuRow("System Default", checked: appState.preferredMicUID == nil)
            }
            ForEach(devices) { device in
                Button {
                    appState.setMicDevice(uid: device.id)
                } label: {
                    menuRow(device.name, checked: appState.preferredMicUID == device.id)
                }
            }
        }
        let outputs = appState.availableOutputDevices()
        if !outputs.isEmpty {
            Section("Speaker") {
                Button {
                    appState.setOutputDevice(id: nil)
                } label: {
                    menuRow("System Default", checked: appState.preferredOutputDeviceId == nil)
                }
                ForEach(outputs) { device in
                    Button {
                        appState.setOutputDevice(id: device.id)
                    } label: {
                        menuRow(device.name, checked: appState.preferredOutputDeviceId == device.id)
                    }
                }
            }
        }
    }
}

struct CameraPickerMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let devices = CallCameraCapture.availableCameras()
        Section("Camera") {
            Button {
                appState.setCameraDevice(uid: nil)
            } label: {
                menuRow("System Default", checked: appState.preferredCameraUID == nil)
            }
            ForEach(devices) { device in
                Button {
                    appState.setCameraDevice(uid: device.id)
                } label: {
                    menuRow(device.name, checked: appState.preferredCameraUID == device.id)
                }
            }
        }
        Section("Background") {
            Button {
                appState.cameraBackgroundEffect = .none
            } label: {
                menuRow("None", checked: appState.cameraBackgroundEffect == .none)
            }
            Button {
                appState.cameraBackgroundEffect = .blur
            } label: {
                menuRow("Blur", checked: appState.cameraBackgroundEffect == .blur)
            }
            Button {
                chooseBackgroundImage()
            } label: {
                if case .image = appState.cameraBackgroundEffect {
                    Label("Image…", systemImage: "checkmark")
                } else {
                    Text("Image…")
                }
            }
        }
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image for your camera"
        if panel.runModal() == .OK, let url = panel.url {
            appState.cameraBackgroundEffect = .image(url)
        }
    }
}

struct ScreenSourcePickerMenu: View {
    @Environment(AppState.self) private var appState
    @State private var targets: [ScreenShareTarget] = []

    var body: some View {
        Group {
            if targets.isEmpty {
                Text("Loading sources…")
            } else {
                let displays = targets.filter { if case .display = $0.kind { return true }; return false }
                let windows = targets.filter { if case .window = $0.kind { return true }; return false }
                Section("Share a Display") {
                    ForEach(displays) { target in
                        Button(target.title) { appState.startScreenShare(target: target) }
                    }
                }
                Section("Share a Window") {
                    ForEach(windows) { target in
                        Button(target.title) { appState.startScreenShare(target: target) }
                    }
                }
                if appState.isScreenSharing {
                    Divider()
                    Button("Stop Sharing") { appState.toggleScreenShare() }
                }
            }
        }
        .task {
            targets = await CallScreenCapture.availableTargets()
        }
    }
}

@ViewBuilder
private func menuRow(_ title: String, checked: Bool) -> some View {
    if checked {
        Label(title, systemImage: "checkmark")
    } else {
        Text(title)
    }
}

// MARK: - Local self-view

/// Chooses the honest self-view: the raw low-latency preview layer normally,
/// or the processed (background-effect) frames — what peers actually see —
/// when an effect is active.
struct LocalSelfView: View {
    let capture: CallCameraCapture
    let effectActive: Bool

    var body: some View {
        if effectActive {
            AttachedLayerView(layer: capture.processedPreviewLayer)
        } else {
            LocalPreviewView(capture: capture)
        }
    }
}

/// Hosts an externally-owned CALayer, resized to the view's bounds.
struct AttachedLayerView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> HostView {
        let v = HostView()
        v.attach(layer)
        return v
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        nsView.attach(layer)
    }

    final class HostView: NSView {
        private weak var hosted: CALayer?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        func attach(_ layer: CALayer) {
            guard hosted !== layer else { return }
            hosted?.removeFromSuperlayer()
            self.layer?.addSublayer(layer)
            hosted = layer
            layer.frame = bounds
        }
        override func layout() {
            super.layout()
            hosted?.frame = bounds
        }
    }
}

// MARK: - Raw preview self-view (AVCaptureVideoPreviewLayer)

struct LocalPreviewView: NSViewRepresentable {
    let capture: CallCameraCapture

    func makeNSView(context: Context) -> PreviewContainer {
        let v = PreviewContainer()
        v.attach(capture.previewLayer)
        return v
    }

    func updateNSView(_ nsView: PreviewContainer, context: Context) {
        nsView.attach(capture.previewLayer)
    }

    final class PreviewContainer: NSView {
        private weak var preview: AVCaptureVideoPreviewLayer?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        func attach(_ layer: AVCaptureVideoPreviewLayer) {
            guard preview !== layer else { return }
            preview?.removeFromSuperlayer()
            self.layer?.addSublayer(layer)
            preview = layer
            layoutPreview()
        }
        override func layout() {
            super.layout()
            layoutPreview()
        }
        private func layoutPreview() {
            preview?.frame = bounds
        }
    }
}

// MARK: - Remote screen-share tile (AVSampleBufferDisplayLayer, letterboxed)

struct RemoteScreenTile: NSViewRepresentable {
    let appState: AppState
    let nick: String

    func makeNSView(context: Context) -> RemoteVideoTile.SampleBufferView {
        let v = RemoteVideoTile.SampleBufferView()
        // Screens must never be cropped — text lives at the edges.
        v.displayLayer.videoGravity = .resizeAspect
        appState.bindScreenSink(nick: nick, to: v.displayLayer)
        return v
    }

    func updateNSView(_ nsView: RemoteVideoTile.SampleBufferView, context: Context) {
        appState.bindScreenSink(nick: nick, to: nsView.displayLayer)
    }
}

// MARK: - Remote participant tile (AVSampleBufferDisplayLayer)

struct RemoteVideoTile: NSViewRepresentable {
    let appState: AppState
    let nick: String

    func makeNSView(context: Context) -> SampleBufferView {
        let v = SampleBufferView()
        appState.bindVideoSink(nick: nick, to: v.displayLayer)
        return v
    }

    func updateNSView(_ nsView: SampleBufferView, context: Context) {
        appState.bindVideoSink(nick: nick, to: nsView.displayLayer)
    }

    final class SampleBufferView: NSView {
        let displayLayer = AVSampleBufferDisplayLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            displayLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(displayLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
        override func layout() {
            super.layout()
            displayLayer.frame = bounds
        }
    }
}

// MARK: - BGRA → CMSampleBuffer

/// Converts tightly-packed BGRA frames into `CMSampleBuffer`s and enqueues
/// them on display layers — off the main thread, from a pooled allocator.
///
/// The old path did the CVPixelBuffer alloc + two memcpys on the MAIN thread
/// per frame per participant (jank at 30 fps × N tiles) with no buffer pool
/// (allocator churn) and no failure recovery (a decode error froze the tile
/// forever).
enum VideoSampleBuffer {
    /// Serial render queue: keeps frame order per call and keeps all pixel
    /// work off the main thread. `AVSampleBufferDisplayLayer.enqueue` is
    /// thread-safe.
    private static let renderQueue = DispatchQueue(
        label: "at.freeq.macos.video-render", qos: .userInteractive)

    /// One pixel-buffer pool per frame size (participants can differ).
    private static var pools: [String: CVPixelBufferPool] = [:]

    /// Async render entrypoint used by the AV callback handler.
    static func renderAsync(bgra: [UInt8], width: Int, height: Int,
                            on layer: AVSampleBufferDisplayLayer) {
        renderQueue.async {
            // A failed layer never recovers on its own — flush to restart.
            if layer.status == .failed {
                layer.flush()
            }
            enqueue(bgra: bgra, width: width, height: height, on: layer)
        }
    }

    private static func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        let key = "\(width)x\(height)"
        if let cached = pools[key] { return cached }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        if let pool {
            if pools.count > 8 { pools.removeAll() }  // size-churn safety valve
            pools[key] = pool
        }
        return pool
    }

    @discardableResult
    static func enqueue(bgra: [UInt8], width: Int, height: Int,
                        on layer: AVSampleBufferDisplayLayer) -> Bool {
        guard bgra.count == width * height * 4 else {
            print("[av] BGRA size mismatch: got \(bgra.count), expected \(width * height * 4)")
            return false
        }

        var pixelBuffer: CVPixelBuffer?
        if let pool = pool(width: width, height: height) {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        }
        guard let pb = pixelBuffer else {
            print("[av] pixel buffer allocation failed")
            return false
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return false }
        let expectedRow = width * 4

        bgra.withUnsafeBufferPointer { src in
            if rowBytes == expectedRow {
                memcpy(dst, src.baseAddress!, width * height * 4)
            } else {
                for y in 0..<height {
                    let srcRow = src.baseAddress!.advanced(by: y * expectedRow)
                    let dstRow = dst.advanced(by: y * rowBytes)
                    memcpy(dstRow, srcRow, expectedRow)
                }
            }
        }

        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let desc = formatDesc else { return false }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb,
            formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return false }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
            let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            CFDictionarySetValue(first, key, value)
        }

        layer.enqueue(sb)
        return true
    }
}
