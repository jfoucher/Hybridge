import SwiftUI

/// Debug screen: download, share and delete files by handle
/// (GB: FileManagementActivity). The config/activity files are encrypted at
/// rest on HR watches; `downloadForExport` decrypts those so they download as
/// plaintext. Other errors just surface as toasts.
struct FileManagerView: View {
    @EnvironmentObject var watch: WatchManager
    @State private var busy = false
    @State private var downloaded: (name: String, url: URL)?
    @State private var customHandle = ""

    var body: some View {
        List {
            Section {
                ForEach(FossilFileHandle.allCases, id: \.rawValue) { handle in
                    row(for: handle)
                }
            } header: {
                Text("Known handles")
            } footer: {
                Text("Download resolves the concrete handle via lookup first, then falls back to the literal handle. Deleting system files can require a factory reset — use with care.")
            }

            Section("Custom handle (hex, e.g. 0x0B00)") {
                HStack {
                    TextField("0x0000", text: $customHandle)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Download") {
                        if let value = parseCustomHandle() {
                            download(handle: value, name: String(format: "file_%04X", value))
                        } else {
                            ToastCenter.shared.error(
                                String(localized: "Not a valid 16-bit hex handle"))
                        }
                    }
                    .disabled(busy)
                }
            }

            if let downloaded {
                Section("Last download") {
                    ShareLink(item: downloaded.url) {
                        Label("Share \(downloaded.name)", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if busy {
                Section { HStack { ProgressView(); Text("Working…") } }
            }
        }
        .navigationTitle("File manager")
        .themedList()
    }

    private func row(for handle: FossilFileHandle) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(String(describing: handle))
                Text(String(format: "0x%04X", handle.rawValue))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                download(handle: handle.rawValue, name: String(describing: handle))
            } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless)
                .disabled(busy)
        }
        .swipeActions {
            Button(role: .destructive) {
                delete(handle: handle)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func parseCustomHandle() -> UInt16? {
        let cleaned = customHandle
            .replacingOccurrences(of: "0x", with: "")
            .trimmingCharacters(in: .whitespaces)
        return UInt16(cleaned, radix: 16)
    }

    private func download(handle: UInt16, name: String) {
        busy = true
        Task {
            do {
                // Resolves the concrete handle via lookup and decrypts the
                // config/activity files (encrypted at rest on HR) so their
                // download doesn't CRC-mismatch.
                let data = try await watch.downloadForExport(handle: handle)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(name)_\(String(format: "%04X", handle)).bin")
                try data.write(to: url)
                await MainActor.run {
                    downloaded = (name, url)
                    busy = false
                    ToastCenter.shared.success(
                        String(localized: "\(name): \(data.count) bytes"))
                }
            } catch {
                await MainActor.run {
                    busy = false
                    ToastCenter.shared.error(error.localizedDescription)
                }
            }
        }
    }

    private func delete(handle: FossilFileHandle) {
        busy = true
        Task {
            do {
                try await watch.run(FileDeleteRequest(handle: handle.rawValue))
                await MainActor.run {
                    busy = false
                    ToastCenter.shared.success(
                        String(localized: "\(String(describing: handle)) deleted"))
                }
            } catch {
                await MainActor.run {
                    busy = false
                    ToastCenter.shared.error(error.localizedDescription)
                }
            }
        }
    }
}
