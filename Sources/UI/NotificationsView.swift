import SwiftUI

/// The watch-side notification filter: which apps reach the watch, whether
/// unlisted apps get through, and which icon each app shows. Notifications
/// themselves are delivered natively by iOS via ANCS once the watch is
/// bonded — this screen only configures the watch's filter.
struct NotificationsView: View {
    @EnvironmentObject var watch: WatchManager
    @ObservedObject private var store = NotificationIconStore.shared
    @State private var adding = false
    @State private var pushTask: Task<Void, Never>?

    var body: some View {
        ThemedScreen("Notifications") {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Filter")
                ThemedCard {
                    SettingsRow(icon: "bell.badge", title: "Manage watch notifications") {
                        Toggle(isOn: $store.isEnabled) { EmptyView() }.labelsHidden().brassToggle()
                            .accessibilityLabel("Manage watch notifications")
                    }
                    Hairline(leading: 59)
                    SettingsRow(icon: "envelope.badge", title: "Allow apps not listed") {
                        Toggle(isOn: $store.allowAllApps) { EmptyView() }.labelsHidden().brassToggle()
                            .accessibilityLabel("Allow apps not listed")
                    }
                }
                Footer("Changes are sent automatically and restored on every connect. On: Hybridge manages the watch filter. Off: the watch's existing filter is left alone.")
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Apps").padding(.top, 26)
                if store.entries.isEmpty {
                    ThemedCard {
                        Text("No apps yet. Tap Add app to add one.")
                            .font(Theme.sans(15, relativeTo: .body))
                            .foregroundStyle(Theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else {
                    ThemedCard {
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { i, entry in
                            SwipeToDelete(onDelete: {
                                store.entries.removeAll { $0.id == entry.id }
                            }) {
                                appRow(entry)
                            }
                            if i < store.entries.count - 1 { Hairline(leading: 59) }
                        }
                    }
                }
                Button {
                    adding = true
                } label: {
                    brassRow("plus", "Add app")
                }.buttonStyle(PressableRow())
                    .padding(.top, 10)
                Footer("On = sent to the watch with this icon. Off = blocked on the watch, even when unlisted apps are allowed. Swipe to remove an entry entirely (the app then counts as unlisted).")
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Actions").padding(.top, 26)
                ThemedCard {
                    Button { testNotification() } label: {
                        SettingsRow(icon: "bell.badge", title: "Send test notification",
                                    titleColor: Theme.accent)
                    }
                    .buttonStyle(PressableRow())
                    .disabled(!watch.isAuthenticated)
                }
                Footer("The test notification goes through the watch protocol directly, so it works even before Bluetooth pairing.")
            }
        }
        .sheet(isPresented: $adding) {
            AddNotificationAppView { entry in
                store.entries.append(entry)
            }
        }
        .onChange(of: store.entries) { _, _ in schedulePush() }
        .onChange(of: store.allowAllApps) { _, _ in schedulePush() }
        .onChange(of: store.isEnabled) { _, enabled in
            if enabled { schedulePush() } else { pushTask?.cancel() }
        }
    }

    private func appRow(_ entry: NotificationIconStore.Entry) -> some View {
        HStack(spacing: 13) {
            IconTile(symbol: entry.symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(Theme.sans(16, relativeTo: .body))
                    .foregroundStyle(Theme.ink)
                Text(entry.bundleId)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.sub)
            }
            Spacer(minLength: 8)
            Toggle(isOn: entryEnabledBinding(entry)) { EmptyView() }.labelsHidden().brassToggle()
                .accessibilityLabel("\(entry.displayName) notifications")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Theme.card)
        .opacity(entry.enabled ? 1 : 0.5)
    }

    private func entryEnabledBinding(_ entry: NotificationIconStore.Entry) -> Binding<Bool> {
        Binding(
            get: { store.entries.first { $0.id == entry.id }?.enabled ?? false },
            set: { newValue in
                if let index = store.entries.firstIndex(where: { $0.id == entry.id }) {
                    store.entries[index].enabled = newValue
                }
            }
        )
    }

    private func brassRow(_ symbol: String, _ title: LocalizedStringResource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
            Text(title).font(Theme.sans(15, weight: .semibold, relativeTo: .body))
            Spacer()
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func schedulePush() {
        pushTask?.cancel()
        guard store.isEnabled else { return }
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasApps,
                  watch.connectionState == .ready, watch.isAuthenticated else { return }
            do {
                try await watch.setNotificationConfigurations()
                await QuietHoursManager.shared.evaluate()
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

    private func testNotification() {
        Task {
            do {
                try await watch.playNotification(sender: "Hybridge",
                                                 message: String(localized: "Test notification from the app"))
                await MainActor.run {
                    ToastCenter.shared.success(String(localized: "Test notification sent"))
                }
            } catch {
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}

private struct AddNotificationAppView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (NotificationIconStore.Entry) -> Void

    @State private var query = ""
    @State private var results: [AppStoreSearch.Result] = []
    @State private var searching = false
    @State private var searchFailed = false
    @State private var bundleId = ""
    @State private var displayName = ""
    @State private var symbol = "app.badge.fill"

    /// A small pick list keeps this usable; the field below accepts any name.
    private static let suggestedSymbols = [
        "app.badge.fill", "message.fill", "envelope.fill", "phone.fill",
        "paperplane.fill", "bubble.left.fill", "camera.fill", "calendar",
        "cart.fill", "creditcard.fill", "gamecontroller.fill", "music.note",
        "newspaper.fill", "airplane", "car.fill", "house.fill",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("App name", text: $query)
                            .autocorrectionDisabled()
                            .onSubmit { search() }
                        if searching {
                            ProgressView()
                        } else {
                            Button("Search") { search() }
                                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    ForEach(results) { result in
                        Button {
                            bundleId = result.bundleId
                            displayName = result.trackName
                            results = []
                        } label: {
                            HStack {
                                AsyncImage(url: result.artworkUrl60.flatMap(URL.init)) { image in
                                    image.resizable()
                                } placeholder: {
                                    Color.gray.opacity(0.2)
                                }
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(result.trackName).foregroundStyle(.primary)
                                    Text(result.bundleId)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Search the App Store")
                } footer: {
                    Text(searchFailed
                         ? String(localized: "Search failed — check the internet connection, or enter the bundle ID manually below.")
                         : String(localized: "Looks up the bundle ID for you. Pick a result, then choose an icon below."))
                }

                Section("App") {
                    TextField("Bundle ID (e.g. com.example.app)", text: $bundleId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                    TextField("Display name", text: $displayName)
                }

                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8)) {
                        ForEach(Self.suggestedSymbols, id: \.self) { name in
                            Image(systemName: name)
                                .padding(6)
                                .background(symbol == name ? Color.accentColor.opacity(0.25) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onTapGesture { symbol = name }
                        }
                    }
                    TextField("SF Symbol name", text: $symbol)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                } header: {
                    Text("Icon")
                } footer: {
                    Text("The watch display is monochrome, so icons are SF Symbol glyphs rather than the app's real artwork. Any SF Symbol name works.")
                }
            }
            .navigationTitle("Add app")
            .themedList()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(NotificationIconStore.Entry(
                            bundleId: bundleId.trimmingCharacters(in: .whitespaces),
                            displayName: displayName.isEmpty ? bundleId : displayName,
                            symbol: UIImage(systemName: symbol) != nil ? symbol : "app.badge.fill"))
                        dismiss()
                    }
                    .disabled(bundleId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !searching else { return }
        searching = true
        searchFailed = false
        Task {
            do {
                let found = try await AppStoreSearch.search(term)
                await MainActor.run {
                    results = found
                    searching = false
                }
            } catch {
                await MainActor.run {
                    searchFailed = true
                    searching = false
                }
            }
        }
    }
}
