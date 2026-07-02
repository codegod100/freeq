import Foundation

/// A capture device as shown in pickers. `id` is the platform unique ID
/// (AVCaptureDevice.uniqueID / CoreAudio UID), stable across replug.
struct MediaDevice: Equatable, Identifiable {
    let id: String
    let name: String
}

/// Pure policy for mic/camera pickers: resolve the user's sticky preference
/// against currently-present hardware, and normalize discovery lists.
enum MediaDeviceSelection {
    /// The device to use: the preferred one when present, else nil meaning
    /// "system default" (also the answer when there's no preference, or the
    /// preferred device was unplugged).
    static func resolve(preferredId: String?, devices: [MediaDevice]) -> MediaDevice? {
        guard let preferredId else { return nil }
        return devices.first { $0.id == preferredId }
    }

    /// Picker-ready list: discovery order, deduped by ID, no blank IDs
    /// (devices mid-initialization enumerate with empty UIDs).
    static func displayList(_ devices: [MediaDevice]) -> [MediaDevice] {
        var seen = Set<String>()
        return devices.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
}
