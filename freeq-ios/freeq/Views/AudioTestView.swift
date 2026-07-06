import SwiftUI
import AVFoundation

/// Zoom-style local speaker + microphone test. Purely local — it never opens a
/// MoQ/SFU session, so it's meaningful even when a call wouldn't connect. Plays
/// a test chime through the current output route and shows a live mic level
/// meter (with optional record-and-play-back) from `CallMicCapture`.
@MainActor
final class AudioTestModel: ObservableObject {
    @Published var micLevel: Float = 0
    @Published var micTesting = false
    @Published var speakerPlaying = false
    @Published var micError: String?
    @Published var recording = false
    @Published var hasRecording = false

    private var mic: CallMicCapture?
    private let toneEngine = AVAudioEngine()
    private let tonePlayer = AVAudioPlayerNode()
    private var toneReady = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingURL: URL?

    // Level smoothing so the meter glides instead of jittering.
    private var smoothed: Float = 0

    private func configureSession(record: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(record ? .playAndRecord : .playback,
                                 mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    // MARK: - Speaker

    func toggleSpeaker() { speakerPlaying ? stopTone() : playTone() }

    private func playTone() {
        configureSession(record: micTesting)
        if !toneReady {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            toneEngine.attach(tonePlayer)
            toneEngine.connect(tonePlayer, to: toneEngine.mainMixerNode, format: format)
            toneReady = true
        }
        do {
            try toneEngine.start()
        } catch {
            return
        }
        let buf = Self.chimeBuffer()
        tonePlayer.scheduleBuffer(buf, at: nil, options: .loops)
        tonePlayer.play()
        speakerPlaying = true
    }

    private func stopTone() {
        tonePlayer.stop()
        toneEngine.pause()
        speakerPlaying = false
    }

    /// A gentle C5–E5–G5 arpeggio buffer that loops — clearly audible, not a beep.
    private static func chimeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let sr = 48_000.0
        let duration = 1.3
        let frames = AVAudioFrameCount(sr * duration)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let notes = [523.25, 659.25, 783.99]
        let ch = buf.floatChannelData![0]
        for n in 0..<Int(frames) {
            let t = Double(n) / sr
            var s = 0.0
            for (i, f) in notes.enumerated() {
                let local = t - Double(i) * 0.18
                if local >= 0, local < 0.6 {
                    s += sin(2 * .pi * f * local) * exp(-local * 4) * 0.2
                }
            }
            ch[n] = Float(s)
        }
        return buf
    }

    // MARK: - Microphone

    func toggleMic() { micTesting ? stopMic() : startMic() }

    private func startMic() {
        micError = nil
        configureSession(record: true)
        let cap = CallMicCapture()
        cap.onSamples = { [weak self] samples in
            guard let self else { return }
            var sum: Float = 0
            for v in samples { sum += v * v }
            let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
            Task { @MainActor in
                // Attack fast, release slow.
                let target = min(1, rms * 4.5)
                self.smoothed = target > self.smoothed ? target : self.smoothed * 0.82 + target * 0.18
                self.micLevel = self.smoothed
            }
        }
        cap.start()
        mic = cap
        micTesting = true
    }

    private func stopMic() {
        mic?.stop()
        mic = nil
        micTesting = false
        micLevel = 0
        smoothed = 0
    }

    // MARK: - Record & play back

    func startRecording() {
        guard micTesting else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeq-mictest.m4a")
        recordingURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.record()
            recorder = rec
            recording = true
            hasRecording = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.stopRecording()
            }
        } catch {
            micError = "Couldn't start recording."
        }
    }

    func stopRecording() {
        guard recording else { return }
        recorder?.stop()
        recorder = nil
        recording = false
        hasRecording = recordingURL != nil
    }

    func playRecording() {
        guard let url = recordingURL else { return }
        configureSession(record: micTesting)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    // MARK: - Teardown

    func teardown() {
        stopTone()
        stopMic()
        recorder?.stop()
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct AudioTestView: View {
    @StateObject private var model = AudioTestModel()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Test speaker", systemImage: "speaker.wave.3.fill")
                        .font(.fqSubheadline.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    LevelMeterBar(level: model.speakerPlaying ? 0.7 : 0, active: model.speakerPlaying, tint: Theme.accent)
                    Button(action: model.toggleSpeaker) {
                        Label(model.speakerPlaying ? "Stop" : "Play test sound",
                              systemImage: model.speakerPlaying ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.speakerPlaying ? Theme.danger : Theme.accent)
                    if model.speakerPlaying {
                        Text("Hear the chime? Your speaker works.")
                            .font(.fqCaption).foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.bgSecondary)

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Test microphone", systemImage: "mic.fill")
                        .font(.fqSubheadline.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    LevelMeterBar(level: model.micLevel, active: model.micTesting, tint: Theme.verify)
                    if let err = model.micError {
                        Text(err).font(.fqCaption).foregroundColor(Theme.danger)
                    }
                    HStack(spacing: 10) {
                        Button(action: model.toggleMic) {
                            Label(model.micTesting ? "Stop" : "Test mic",
                                  systemImage: model.micTesting ? "stop.fill" : "waveform")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(model.micTesting ? Theme.danger : Theme.accent)

                        if model.micTesting && !model.recording {
                            Button(action: model.startRecording) {
                                Label("Record", systemImage: "record.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                        if model.recording {
                            Text("● Recording…").font(.fqCaption)
                                .foregroundColor(Theme.danger)
                        }
                        if model.hasRecording && !model.recording {
                            Button(action: model.playRecording) {
                                Label("Play back", systemImage: "play.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if model.micTesting && !model.recording && !model.hasRecording {
                        Text("Speak — the bars should move.")
                            .font(.fqCaption).foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.bgSecondary)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bgPrimary)
        .navigationTitle("Speaker & Mic")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.teardown() }
    }
}

/// A segmented level meter that lights up with the audio level.
struct LevelMeterBar: View {
    let level: Float
    let active: Bool
    let tint: Color
    private let count = 18

    var body: some View {
        let lit = Int((level.clamped01()) * Float(count))
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                let on = active && i < lit
                let hot = i > Int(Double(count) * 0.8)
                RoundedRectangle(cornerRadius: 2)
                    .fill(on ? (hot ? Theme.danger : tint) : Theme.textMuted.opacity(0.18))
                    .frame(maxWidth: .infinity)
                    .frame(height: on ? 22 : 8)
                    .animation(.easeOut(duration: 0.08), value: on)
            }
        }
        .frame(height: 22)
    }
}

private extension Float {
    func clamped01() -> Float { Swift.max(0, Swift.min(1, self)) }
}
