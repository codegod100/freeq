import AVFoundation
import Foundation
import QuartzCore

/// Drives the macOS microphone and pumps mono 48 kHz float samples to the
/// Rust AV pipeline via `pushAudioFrame`.
///
/// Capture is Swift-driven (the iroh-live audio input backend is stubbed on
/// Apple platforms — we capture from `AVAudioEngine` and push frames in).
/// Unlike iOS there is no `AVAudioSession` on macOS; the input node is used
/// directly.
///
/// Quality features:
/// - **Voice processing** (`setVoiceProcessingEnabled`): Apple's AEC +
///   noise suppression + AGC, referenced against system output — without
///   this, speaker playback from the Rust audio device echoes straight back.
/// - **Device selection**: sticky per-UID preference applied to the input
///   node's audio unit; resolution policy is the unit-tested
///   `MediaDeviceSelection`.
/// - **Hotplug recovery**: `AVAudioEngineConfigurationChange` rebuilds the
///   tap/converter, so unplugging the selected mic falls back cleanly.
/// - **Metering**: every buffer runs through the unit-tested
///   `AudioLevelMeter` (RMS → dBFS → speaking hysteresis) and fires
///   `onLevel` on the main thread. Metering continues while muted so the UI
///   can show "you're talking but muted".
/// - **Mute**: when muted, frames are metered but NOT delivered to
///   `onSamples`, so no audio crosses the FFI at all.
final class CallMicCapture {
    /// Fires on the audio engine's render thread — keep the handler fast.
    var onSamples: (([Float]) -> Void)?
    /// Level/speaking updates, throttled to capture-buffer cadence (~40 ms),
    /// delivered on the main thread.
    var onLevel: ((AudioLevelMeter.Update) -> Void)?
    /// Mic permission was denied — surface UI guidance.
    var onPermissionDenied: (() -> Void)?
    /// Unrecoverable capture failure with a user-presentable message.
    var onError: ((String) -> Void)?

    /// While true, buffers are metered but not delivered to `onSamples`.
    var muted = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var running = false
    private var meter = AudioLevelMeter()
    private var preferredDeviceUID: String?
    private var configObserver: NSObjectProtocol?

    /// What the Rust `PushAudioSource` expects: mono 48 kHz float32.
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    /// Request microphone permission, then start capture. Idempotent.
    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                print("[mic] permission denied — others won't hear you")
                DispatchQueue.main.async { self.onPermissionDenied?() }
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
    }

    /// Switch to a specific input device (nil = system default). Applies
    /// immediately when running; sticky for later starts either way.
    func setPreferredDevice(uid: String?) {
        preferredDeviceUID = uid
        guard running else { return }
        rebuildCapture()
    }

    private func begin() {
        guard !running else { return }

        applyPreferredDevice()
        enableVoiceProcessing()

        guard installTap() else { return }
        do {
            engine.prepare()
            try engine.start()
            running = true
            observeConfigurationChanges()
            print("[mic] capture started (voice processing: \(engine.inputNode.isVoiceProcessingEnabled))")
        } catch {
            print("[mic] engine start failed: \(error)")
            engine.inputNode.removeTap(onBus: 0)
            onError?("Microphone capture failed to start: \(error.localizedDescription)")
        }
    }

    /// Apple's voice-processing unit on the input node: AEC (referenced
    /// against device output, so remote audio played by the Rust side is
    /// cancelled), noise suppression, and AGC. Best-effort — some aggregate
    /// devices refuse; raw capture still works, just without AEC.
    private func enableVoiceProcessing() {
        let input = engine.inputNode
        guard !input.isVoiceProcessingEnabled else { return }
        do {
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                input.isVoiceProcessingAGCEnabled = true
            }
        } catch {
            print("[mic] voice processing unavailable (\(error)) — using raw input")
        }
    }

    /// Point the input audio unit at the preferred CoreAudio device.
    private func applyPreferredDevice() {
        let resolved = MediaDeviceSelection.resolve(
            preferredId: preferredDeviceUID, devices: AudioInputDevices.list())
        guard let uid = resolved?.id,
              var deviceId = AudioInputDevices.deviceID(forUID: uid),
              let unit = engine.inputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceId, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            print("[mic] failed to select device \(uid): OSStatus \(status)")
        }
    }

    private func installTap() -> Bool {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        print("[mic] input \(inFormat.sampleRate)Hz x\(inFormat.channelCount)ch")
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            print("[mic] input route unavailable — capture aborted")
            onError?("No microphone input route is available.")
            return false
        }
        converter = AVAudioConverter(from: inFormat, to: target)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        return true
    }

    /// Default-device change or unplug of the selected mic: rebuild the
    /// tap + converter against the new input format. Without this the stale
    /// converter silently produces garbage/no audio for the rest of the call.
    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.running else { return }
            print("[mic] engine configuration changed — rebuilding capture")
            self.rebuildCapture()
        }
    }

    private func rebuildCapture() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        applyPreferredDevice()
        guard installTap() else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            print("[mic] restart after device change failed: \(error)")
            onError?("Microphone stopped after a device change: \(error.localizedDescription)")
            running = false
        }
    }

    /// Convert one captured buffer to mono 48 kHz, meter it, and (unless
    /// muted) hand it to `onSamples`.
    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var convErr: NSError?
        let status = converter.convert(to: out, error: &convErr) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            print("[mic] convert error: \(convErr?.localizedDescription ?? "unknown")")
            return
        }
        let frames = Int(out.frameLength)
        guard frames > 0, let channel = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: frames))

        if let onLevel {
            let update = meter.process(samples: samples, at: CACurrentMediaTime())
            DispatchQueue.main.async { onLevel(update) }
        }
        guard !muted else { return }
        onSamples?(samples)
    }

    /// Stop capture and release the engine. Idempotent.
    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        running = false
        meter = AudioLevelMeter()
        print("[mic] capture stopped")
    }
}
