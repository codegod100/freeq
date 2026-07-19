import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A floating "quick send" panel the global hotkey (⌥⌘Space) summons from
/// anywhere — jot a line to a channel without switching to freeq. Appears
/// over other apps and full-screen spaces, takes keyboard focus for the
/// field, sends on Return, dismisses on Escape or send.
@MainActor
final class QuickSendController {
    static let shared = QuickSendController()

    private var panel: NSPanel?
    private var hotKey: GlobalHotKey?

    /// Register the global hotkey. Called once on app launch.
    func installHotKey() {
        guard hotKey == nil else { return }
        // ⌥⌘Space — distinct from Spotlight (⌘Space). Sandbox-safe Carbon key.
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.toggle()
        }
    }

    /// Prefill for the next presentation (from a `freeq://share` open).
    private var prefill: ShareURL.Payload?

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            prefill = nil
            present()
        }
    }

    /// Summon the panel pre-filled from a Share Extension / share URL.
    func presentShare(_ payload: ShareURL.Payload) {
        prefill = payload
        // Rebuild content so the SwiftUI view picks up the new initial values.
        panel?.orderOut(nil)
        panel = nil
        present()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if let screen = NSScreen.main {
            let size = panel.frame.size
            let origin = NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY + screen.frame.height * 0.12)
            panel.setFrameOrigin(origin)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 128),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let view = QuickSendView(
            initialText: prefill?.body ?? "",
            initialTarget: prefill?.target,
            onSend: { [weak self] in self?.dismiss() },
            onCancel: { [weak self] in self?.dismiss() })
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }
}

/// NSPanel that can become key (default panels with .nonactivating don't),
/// so the text field accepts input, and closes on Escape.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// The panel's content: target picker + message field.
private struct QuickSendView: View {
    var initialText: String = ""
    var initialTarget: String? = nil
    let onSend: () -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var target = ""
    @FocusState private var fieldFocused: Bool

    private var targets: [String] {
        guard let app = AppState.current else { return [] }
        return app.channels.map(\.name) + app.dmBuffers.map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.secondary)
                Text("Quick send")
                    .font(.headline)
                Spacer()
                if !targets.isEmpty {
                    Picker("", selection: $target) {
                        // Tag by the buffer key; show the display name so a
                        // DID-keyed DM lists as its peer's nick.
                        ForEach(targets, id: \.self) {
                            Text(AppState.current?.displayNameForKey($0) ?? $0).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }

            if AppState.current?.connectionState == .registered || AppState.current?.connectionState == .connected {
                TextField("Message \(target.isEmpty ? "" : (AppState.current?.displayNameForKey(target) ?? target))…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Text("↩ send   ·   esc cancel")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Not connected — open freeq to sign in.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear {
            if text.isEmpty { text = initialText }
            if target.isEmpty {
                target = initialTarget ?? AppState.current?.activeChannel ?? targets.first ?? ""
            }
            fieldFocused = true
        }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !target.isEmpty, let app = AppState.current else {
            onCancel(); return
        }
        app.submitInput(trimmed, target: target)
        text = ""
        onSend()
    }
}
