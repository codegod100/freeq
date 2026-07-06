import AVFoundation
import CoreAudio
import SwiftUI

/// Zoom-style local speaker + microphone test. Purely local — no MoQ/SFU
/// session — so it's meaningful even when a call wouldn't connect. Reuses the
/// in-call `CallMicCapture` + `AudioLevelMeter` + `MicLevelBar` for the mic and
/// a standalone `AVAudioEngine` tone (routed to the chosen output device) for
/// the speaker.
@Observable
final class AudioTestModel {
    var micLevel: Float = 0
    var micTesting = false
    var speakerPlaying = false
    var inputDevices: [MediaDevice] = []
    var outputDevices: [MediaDevice] = []
    var selectedInput: String = ""   // device UID
    var selectedOutput: String = ""  // device UID

    @ObservationIgnored private var mic: CallMicCapture?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var toneReady = false

    func refreshDevices() {
        inputDevices = AudioInputDevices.list()
        outputDevices = AudioOutputDevices.list()
    }

    // MARK: - Microphone

    func toggleMic() { micTesting ? stopMic() : startMic() }

    private func startMic() {
        let cap = CallMicCapture()
        cap.setPreferredDevice(uid: selectedInput.isEmpty ? nil : selectedInput)
        cap.onLevel = { [weak self] update in
            Task { @MainActor in self?.micLevel = update.level }
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
    }

    // MARK: - Speaker

    func toggleSpeaker() { speakerPlaying ? stopTone() : playTone() }

    private func playTone() {
        // Best-effort: route the engine's output to the selected device. If it
        // fails, the tone still plays through the default output — a valid test.
        engine.prepare()
        if !selectedOutput.isEmpty,
           let devID = AudioInputDevices.deviceID(forUID: selectedOutput),
           let unit = engine.outputNode.audioUnit {
            var dev = devID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if !toneReady {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            toneReady = true
        }
        do { try engine.start() } catch { return }
        player.scheduleBuffer(Self.chimeBuffer(), at: nil, options: .loops)
        player.play()
        speakerPlaying = true
    }

    private func stopTone() {
        player.stop()
        engine.pause()
        speakerPlaying = false
    }

    /// A gentle C5–E5–G5 arpeggio that loops — clearly audible, not a beep.
    private static func chimeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let sr = 48_000.0
        let frames = AVAudioFrameCount(sr * 1.3)
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

    func teardown() {
        stopTone()
        stopMic()
    }
}

struct AudioSettings: View {
    @State private var model = AudioTestModel()

    var body: some View {
        Form {
            Section("Speaker") {
                Picker("Output", selection: $model.selectedOutput) {
                    Text("System default").tag("")
                    ForEach(model.outputDevices) { d in Text(d.name).tag(d.id) }
                }
                MicLevelBar(level: model.speakerPlaying ? 0.7 : 0, muted: false)
                    .frame(height: 8)
                HStack {
                    Button(model.speakerPlaying ? "Stop" : "Play Test Sound") {
                        model.toggleSpeaker()
                    }
                    if model.speakerPlaying {
                        Text("Hear the chime? Your speaker works.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Microphone") {
                Picker("Input", selection: $model.selectedInput) {
                    Text("System default").tag("")
                    ForEach(model.inputDevices) { d in Text(d.name).tag(d.id) }
                }
                MicLevelBar(level: model.micLevel, muted: false)
                    .frame(height: 8)
                HStack {
                    Button(model.micTesting ? "Stop" : "Test Microphone") {
                        model.toggleMic()
                    }
                    if model.micTesting {
                        Text("Speak — the bar should move.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshDevices() }
        .onDisappear { model.teardown() }
    }
}
