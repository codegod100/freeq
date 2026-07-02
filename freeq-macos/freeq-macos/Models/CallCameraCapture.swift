import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Drives the macOS camera via `AVCaptureSession` and pumps tightly-packed
/// BGRA frames to the Rust AV pipeline via `pushVideoFrame`.
///
/// Capture is Swift-driven because iroh-live's `capture` backend is stubbed on
/// Apple platforms (the camera is owned by AVFoundation here, not Rust). A
/// low-latency `AVCaptureVideoPreviewLayer` is exposed for the local self-view
/// so the local tile never freezes if the encoder stalls.
///
/// Quality: captures 1280×720 (the SDK encodes a 720p H.264 track — the old
/// VGA preset was upscaled by the encoder) at ≤30 fps, supports selecting any
/// connected camera (sticky UID via `MediaDeviceSelection`), and recovers
/// when the active camera is unplugged by falling back to the default.
final class CallCameraCapture: NSObject {
    /// Fires on the capture queue with a tightly-packed BGRA frame. Keep fast.
    /// (pointer, byteLength, width, height, timestampUs)
    var onFrame: ((UnsafePointer<UInt8>, Int, Int, Int, UInt64) -> Void)?
    /// Camera permission was denied — surface UI guidance.
    var onPermissionDenied: (() -> Void)?

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "at.freeq.macos.camera")
    private var configured = false
    private var preferredUniqueID: String?
    private var currentInput: AVCaptureDeviceInput?
    private var disconnectObserver: NSObjectProtocol?

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    /// All connected cameras for the picker (built-in, USB, Continuity).
    static func availableCameras() -> [MediaDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return MediaDeviceSelection.displayList(
            discovery.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
        )
    }

    /// Switch camera (nil = default). Applies live when running; sticky
    /// either way.
    func setPreferredDevice(uniqueID: String?) {
        preferredUniqueID = uniqueID
        queue.async { [weak self] in
            guard let self, self.configured else { return }
            self.reconfigureInput()
        }
    }

    /// Configure (once) and start the capture session. Idempotent.
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                print("[cam] permission denied")
                DispatchQueue.main.async { self.onPermissionDenied?() }
                return
            }
            self.queue.async { self.configureAndRun() }
        }
    }

    private func resolveDevice() -> AVCaptureDevice? {
        if let preferredUniqueID,
           let preferred = AVCaptureDevice(uniqueID: preferredUniqueID) {
            return preferred
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }

    private func configureAndRun() {
        if !configured {
            session.beginConfiguration()
            // 720p matches the SDK's H.264 preset; fall back for cameras
            // that can't do it.
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720)
                ? .hd1280x720 : .vga640x480

            guard let device = resolveDevice(),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                print("[cam] no usable camera input")
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            currentInput = input
            capFrameRate(device)

            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            configured = true
            observeDisconnects()
        }
        if !session.isRunning {
            session.startRunning()
            print("[cam] capture started (\(currentInput?.device.localizedName ?? "?"))")
        }
    }

    /// 30 fps cap: sending faster than the encoder consumes just burns FFI
    /// copies. Best-effort — not all devices allow it.
    private func capFrameRate(_ device: AVCaptureDevice) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.first else { return }
        let fps = min(30, range.maxFrameRate)
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.unlockForConfiguration()
        } catch {
            print("[cam] frame-rate cap failed: \(error)")
        }
    }

    /// Swap the session input to the (re)resolved device.
    private func reconfigureInput() {
        session.beginConfiguration()
        if let currentInput { session.removeInput(currentInput) }
        currentInput = nil
        if let device = resolveDevice(),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            capFrameRate(device)
            print("[cam] switched to \(device.localizedName)")
        } else {
            print("[cam] no usable camera after reconfigure")
        }
        session.commitConfiguration()
    }

    /// Unplug of the active camera: fall back to the default device instead
    /// of freezing the outbound track.
    private func observeDisconnects() {
        guard disconnectObserver == nil else { return }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            guard let self,
                  let gone = note.object as? AVCaptureDevice,
                  gone.uniqueID == self.currentInput?.device.uniqueID else { return }
            print("[cam] active camera disconnected — falling back")
            self.queue.async { self.reconfigureInput() }
        }
    }

    /// Stop the capture session. Idempotent.
    func stop() {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
            self.disconnectObserver = nil
        }
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            print("[cam] capture stopped")
        }
    }
}

/// A shareable screen source for the picker: a whole display or one window.
struct ScreenShareTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }
    let kind: Kind
    let title: String

    var id: String {
        switch kind {
        case .display(let id): return "display-\(id)"
        case .window(let id): return "window-\(id)"
        }
    }
}

/// Captures a display or window through ScreenCaptureKit and emits tightly-
/// packed BGRA frames through the same closure shape as `CallCameraCapture`.
/// This lets macOS screen sharing use the existing native AV video path while
/// the SDK grows a dedicated `/screen` broadcast.
///
/// Quality: Retina-aware capture sized by the unit-tested `ScreenShareConfig`
/// (fit real pixel dimensions into 1920×1080, no upscale, even dims) at
/// 30 fps (the old path captured points at 15 fps — blurry AND choppy).
@available(macOS 12.3, *)
final class CallScreenCapture: NSObject {
    /// Fires on ScreenCaptureKit's sample queue with a tightly-packed BGRA frame.
    /// (pointer, byteLength, width, height, timestampUs)
    var onFrame: ((UnsafePointer<UInt8>, Int, Int, Int, UInt64) -> Void)?
    var onStopped: (() -> Void)?
    /// What to share; nil = primary display.
    var target: ScreenShareTarget?

    private let queue = DispatchQueue(label: "at.freeq.macos.screen")
    private var stream: SCStream?

    /// Enumerate pickable sources: every display, then on-screen windows
    /// (skipping tiny/untitled ones — palettes, tooltips, our own overlay).
    static func availableTargets() async -> [ScreenShareTarget] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [] }

        let displays = content.displays.enumerated().map { i, d in
            ScreenShareTarget(
                kind: .display(d.displayID),
                title: content.displays.count == 1 ? "Entire Screen" : "Display \(i + 1) (\(d.width)×\(d.height))"
            )
        }
        let windows = content.windows.compactMap { w -> ScreenShareTarget? in
            guard let title = w.title, !title.isEmpty,
                  w.frame.width >= 200, w.frame.height >= 150,
                  w.windowLayer == 0  // normal app windows only
            else { return nil }
            let app = w.owningApplication?.applicationName ?? ""
            return ScreenShareTarget(
                kind: .window(w.windowID),
                title: app.isEmpty ? title : "\(app) — \(title)"
            )
        }
        return displays + windows
    }

    func start() {
        Task { [weak self] in
            await self?.startAsync()
        }
    }

    @MainActor
    private func startAsync() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            let filter: SCContentFilter
            let sourcePixels: (width: Int, height: Int)

            switch target?.kind {
            case .window(let windowID):
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    print("[screen] window \(windowID) no longer shareable")
                    onStopped?()
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = Self.scaleFactor(forWindowFrame: window.frame)
                sourcePixels = (Int(window.frame.width * scale), Int(window.frame.height * scale))

            case .display(let displayID):
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    print("[screen] display \(displayID) no longer shareable")
                    onStopped?()
                    return
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
                let scale = Self.scaleFactor(forDisplay: displayID)
                sourcePixels = (Int(CGFloat(display.width) * scale), Int(CGFloat(display.height) * scale))

            case nil:
                guard let display = content.displays.first else {
                    print("[screen] no shareable display")
                    onStopped?()
                    return
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
                let scale = Self.scaleFactor(forDisplay: display.displayID)
                sourcePixels = (Int(CGFloat(display.width) * scale), Int(CGFloat(display.height) * scale))
            }

            let size = ScreenShareConfig.outputSize(
                sourceWidth: sourcePixels.width, sourceHeight: sourcePixels.height)

            let config = SCStreamConfiguration()
            config.width = size.width
            config.height = size.height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(
                value: 1, timescale: CMTimeScale(ScreenShareConfig.framesPerSecond))
            config.queueDepth = 4
            config.showsCursor = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            self.stream = stream
            try await stream.startCapture()
            print("[screen] capture started \(size.width)×\(size.height)@\(ScreenShareConfig.framesPerSecond)")
        } catch {
            print("[screen] capture failed: \(error)")
            onStopped?()
        }
    }

    private static func scaleFactor(forDisplay displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }?.backingScaleFactor ?? 2
    }

    private static func scaleFactor(forWindowFrame frame: CGRect) -> CGFloat {
        NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            do {
                try await stream.stopCapture()
                print("[screen] capture stopped")
            } catch {
                print("[screen] stop failed: \(error)")
            }
        }
    }
}

@available(macOS 12.3, *)
extension CallScreenCapture: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let onFrame,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let expectedRow = width * 4
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tsUs = pts.isValid
            ? UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000)
            : UInt64(Date().timeIntervalSince1970 * 1_000_000)

        var packed = [UInt8](repeating: 0, count: width * height * 4)
        packed.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            if rowBytes == expectedRow {
                memcpy(dstBase, base, width * height * 4)
            } else {
                for y in 0..<height {
                    let srcRow = base.advanced(by: y * rowBytes)
                    let dstRow = dstBase.advanced(by: y * expectedRow)
                    memcpy(dstRow, srcRow, expectedRow)
                }
            }
        }
        packed.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            onFrame(base, buf.count, width, height, tsUs)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[screen] capture stopped with error: \(error)")
        DispatchQueue.main.async { [weak self] in
            self?.onStopped?()
        }
    }
}

extension CallCameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let onFrame, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let expectedRow = width * 4
        let tsUs = UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000)

        // Tightly pack into width*height*4 (the SDK expects no row padding).
        var packed = [UInt8](repeating: 0, count: width * height * 4)
        packed.withUnsafeMutableBytes { dst in
            let dstBase = dst.baseAddress!
            if rowBytes == expectedRow {
                memcpy(dstBase, base, width * height * 4)
            } else {
                for y in 0..<height {
                    let srcRow = base.advanced(by: y * rowBytes)
                    let dstRow = dstBase.advanced(by: y * expectedRow)
                    memcpy(dstRow, srcRow, expectedRow)
                }
            }
        }
        packed.withUnsafeBufferPointer { buf in
            onFrame(buf.baseAddress!, buf.count, width, height, tsUs)
        }
    }
}
