import SwiftUI

/// Enter/replace the 16-byte auth key of one specific watch.
struct KeyEntryView: View {
    let watchID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var keyText: String
    @State private var errorText: String?
    @State private var showHelp = false
    @State private var hasStoredKey: Bool

    init(watchID: UUID) {
        self.watchID = watchID
        // Never pull an existing secret back into ordinary view state. The
        // screen can replace it without displaying the stored value.
        _keyText = State(initialValue: "")
        _hasStoredKey = State(initialValue: KeychainStore.loadKey(for: watchID) != nil)
    }

    private var watchName: String {
        WatchRegistry.shared.watch(watchID)?.name ?? String(localized: "this watch")
    }

    private var parsedKey: Data? {
        guard let data = Data(hexString: keyText), data.count == 16 else { return nil }
        return data
    }

    /// A 32-hex-character run in the given string, ignoring spaces/`0x` —
    /// same tolerance `Data(hexString:)` applies to the text field itself.
    private static func extractHexKey(from text: String) -> String? {
        guard let data = Data(hexString: text), data.count == 16 else { return nil }
        return data.hexString
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DisclosureGroup("Where do I find my key?", isExpanded: $showHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Every watch has a secret 16-byte authentication key. Without Fossil's servers it can't be fetched automatically — you have to bring your own:")
                            Text("• Fetched from the Fossil API with your account login — run scripts/fetch_keys.py from the project repo (see the README's \"Getting your authentication key\" section)\n• Captured from the official app\n• From a backup of either app")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    SecureField("32-character hexadecimal key", text: $keyText)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)

                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first,
                              let hex = Self.extractHexKey(from: pasted) else {
                            errorText = String(localized: "No 32-character hex key found on the clipboard.")
                            return
                        }
                        keyText = hex
                        errorText = nil
                    }
                } header: {
                    Text("Authentication key for \(watchName)")
                } footer: {
                    Text(hasStoredKey
                         ? "A key is already stored. Enter a new 32-character key only to replace it."
                         : "The 16-byte key (32 hex characters) extracted from your watch — each watch has its own. Spaces and a 0x prefix are ignored. Stored in the iOS Keychain.")
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Save key") {
                        guard let key = parsedKey else {
                            errorText = String(
                                localized: "The key must be exactly 32 hex characters (16 bytes).")
                            return
                        }
                        guard KeychainStore.saveKey(key, for: watchID) else {
                            // Don't dismiss on a failed write — the user would
                            // believe the key is stored and only find out when
                            // the next connect fails to authenticate.
                            errorText = String(localized: "The key could not be saved to the iOS Keychain. Unlock the device and try again.")
                            return
                        }
                        hasStoredKey = true
                        dismiss()
                    }
                    .disabled(keyText.isEmpty)

                    if hasStoredKey {
                        Button("Remove stored key", role: .destructive) {
                            KeychainStore.deleteKey(for: watchID)
                            keyText = ""
                            hasStoredKey = false
                        }
                    }
                }
            }
            .navigationTitle("Auth key")
            .themedList()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
