import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey via Carbon `RegisterEventHotKey`. Chosen over an
/// `NSEvent` global monitor because Carbon hotkeys need NO Accessibility
/// permission and work under App Sandbox — the user gets the shortcut with
/// zero setup. One shared application-level Carbon event handler dispatches
/// to registered instances by id.
final class GlobalHotKey {
    private let id: UInt32
    private var ref: EventHotKeyRef?
    private let onFire: () -> Void

    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// `keyCode` is a Carbon virtual key (e.g. `kVK_Space`); `modifiers` is a
    /// Carbon mask (`cmdKey | optionKey | …`).
    init?(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.id = Self.nextID
        Self.nextID += 1

        Self.installHandlerIfNeeded()

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("[hotkey] RegisterEventHotKey failed: \(status)")
            return nil
        }
        self.ref = ref
        Self.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.registry[id] = nil
    }

    private static let signature: OSType = {
        // Four-char code 'FREQ'.
        let chars = "FREQ".utf8.prefix(4)
        return chars.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                DispatchQueue.main.async {
                    GlobalHotKey.registry[hkID.id]?.onFire()
                }
                return noErr
            },
            1, &spec, nil, nil)
    }
}
