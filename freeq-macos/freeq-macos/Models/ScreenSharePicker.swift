import Foundation
import ScreenCaptureKit

/// Wraps the system `SCContentSharingPicker` — the same picker FaceTime and
/// Zoom present. Two properties make it the default share path:
///
/// 1. It forces an explicit "what am I sharing?" choice (display, window, or
///    app) instead of blind-starting on the primary display.
/// 2. Selection is user-mediated, so it works without a pre-granted Screen
///    Recording permission — the silent-failure mode of the old path.
@available(macOS 14.0, *)
final class ScreenSharePickerController: NSObject, SCContentSharingPickerObserver {
    static let shared = ScreenSharePickerController()

    /// One-shot callbacks armed by `present`.
    private var onPicked: ((SCContentFilter) -> Void)?
    private var onCancelled: (() -> Void)?
    private var onFailed: ((String) -> Void)?
    private var observing = false

    /// Present the system picker. Exactly one of the callbacks fires, on the
    /// main thread.
    func present(
        onPicked: @escaping (SCContentFilter) -> Void,
        onCancelled: @escaping () -> Void = {},
        onFailed: @escaping (String) -> Void = { _ in }
    ) {
        self.onPicked = onPicked
        self.onCancelled = onCancelled
        self.onFailed = onFailed

        let picker = SCContentSharingPicker.shared
        if !observing {
            picker.add(self)
            observing = true
        }
        picker.isActive = true
        picker.present()
    }

    private func finish(_ deliver: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            deliver()
            self?.onPicked = nil
            self?.onCancelled = nil
            self?.onFailed = nil
            SCContentSharingPicker.shared.isActive = false
        }
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let cb = onPicked
        finish { cb?(filter) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        let cb = onCancelled
        finish { cb?() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let cb = onFailed
        finish { cb?(error.localizedDescription) }
    }
}
