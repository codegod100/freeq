import SwiftUI

/// ⌘N — start a direct message by nick/handle. Autofocuses so a
/// hardware-keyboard user can type and press Return.
struct NewDMSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var nick = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Start a direct message") {
                    TextField("Nick or handle…", text: $nick)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(open)
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { open() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(nick.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func open() {
        let target = nick.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        appState.pendingDMNick = target
        appState.activeChannel = target
        dismiss()
    }
}
