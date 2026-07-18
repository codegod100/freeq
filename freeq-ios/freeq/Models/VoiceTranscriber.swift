import Foundation
import Speech

/// Transcribes a recorded voice message on-device. Audio bytes never leave
/// the phone — `requiresOnDeviceRecognition = true` is enforced.
///
/// Returns nil if speech recognition is unauthorized, unsupported by the
/// device's locale, or the recognizer can't produce a result. Callers fall
/// back to the audio-only path.
enum VoiceTranscriber {
    /// Ask the user once for speech-recognition permission. Subsequent calls
    /// short-circuit on the cached authorization status.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined {
            return SFSpeechRecognizer.authorizationStatus()
        }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    /// Transcribe an audio file at `url` on-device. Returns the recognised
    /// text or nil if transcription is unavailable.
    static func transcribe(_ url: URL) async -> String? {
        let status = await requestAuthorization()
        guard status == .authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { cont in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if !resumed {
                        resumed = true
                        cont.resume(returning: result.bestTranscription.formattedString)
                    }
                } else if error != nil {
                    if !resumed {
                        resumed = true
                        cont.resume(returning: nil)
                    }
                }
            }
        }
    }
}
