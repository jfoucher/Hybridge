import SwiftUI
import PhotosUI

/// Lets the user import their own case + hand artwork for the dashboard
/// watch mockup. Images are stored per-device (Documents/watch_skin) and
/// override anything bundled with the app.
struct WatchSkinView: View {
    @ObservedObject private var skin = WatchSkinStore.shared
    @State private var picking: WatchSkinStore.Slot?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingPicker = false

    private var recommended: String {
        let s = WatchSkinStore.recommendedSize
        return String(localized: "\(Int(s.width)) × \(Int(s.height)) px")
    }

    var body: some View {
        Form {
            Section {
                ForEach(WatchSkinStore.Slot.allCases) { slot in
                    row(slot)
                }
            } header: {
                Text("Images")
            } footer: {
                Text(String(localized: "PNG with transparency, portrait, all three the same aspect ratio. Recommended \(recommended). Each hand must point to 12 o'clock with its rotation pivot at the exact centre of the image; the case dial must be centred. The live watchface is drawn in the dial and the hands rotate to the current time."))
            }

            if skin.hasCase {
                Section("Preview") {
                    SkinPreview(skin: skin)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section {
                    Button("Remove all images", role: .destructive) {
                        Task {
                            for slot in WatchSkinStore.Slot.allCases {
                                _ = await skin.setUserImage(nil, for: slot)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Watch appearance")
        .themedList()
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $showingPicker,
                      selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let slot = picking, let item else { return }
            Task {
                do {
                    guard let transfer = try await item.loadTransferable(
                        type: BoundedPhotoTransfer.self) else {
                        throw BoundedImageImportError.invalidImage
                    }
                    if !(await skin.setUserImage(transfer.pngData, for: slot)) {
                        ToastCenter.shared.error(String(localized: "Could not save the watch image"))
                    }
                    await MainActor.run {
                        pickerItem = nil
                        picking = nil
                    }
                } catch {
                    await MainActor.run {
                        ToastCenter.shared.error(error.localizedDescription)
                        pickerItem = nil
                        picking = nil
                    }
                }
            }
        }
    }

    private func row(_ slot: WatchSkinStore.Slot) -> some View {
        HStack(spacing: 12) {
            thumbnail(skin.image(for: slot))
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title).font(.body)
                Text(skin.image(for: slot) == nil ? slot.subtitle
                     : (skin.isUserProvided(slot) ? String(localized: "Your image")
                                                  : String(localized: "Bundled default")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(skin.image(for: slot) == nil ? String(localized: "Add")
                                                : String(localized: "Change")) {
                picking = slot
                showingPicker = true
            }
            
                .buttonStyle(.bordered)
            if skin.isUserProvided(slot) {
                Button {
                    Task { _ = await skin.setUserImage(nil, for: slot) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .tint(.red)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ image: UIImage?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
    }
}

/// Static (non-ticking) preview of the composite for the settings screen.
private struct SkinPreview: View {
    @ObservedObject var skin: WatchSkinStore

    var body: some View {
        WatchCompositeView(skin: skin, face: nil, hourAngle: 300, minuteAngle: 60)
    }
}
