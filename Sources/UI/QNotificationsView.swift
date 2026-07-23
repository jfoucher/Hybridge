import SwiftUI
import ContactsUI

/// Notification config for the hands-only Q watches: each alert points the
/// hands at a clock position and vibrates. Apps are matched by bundle id
/// (ANCS CRC), contacts by the display name of their call/text
/// notifications — mirroring the official app's "contacts on the dial".
struct QNotificationsView: View {
    @EnvironmentObject var watch: WatchManager

    @State private var alerts: [QNotificationAlert] = QNotificationStore.alerts
    @State private var editing: QNotificationAlert?
    @State private var addingApp = false
    @State private var pickingContacts = false
    @State private var addingContactByName = false
    @State private var newContactName = ""
    @State private var pushTask: Task<Void, Never>?
    @State private var quietEffective = QuietHoursManager.shared.effectiveMode

    var body: some View {
        List {
            Section {
                NavigationLink {
                    QuietHoursSettingsView(onChange: {
                        quietEffective = QuietHoursManager.shared.effectiveMode })
                } label: {
                    HStack {
                        Image(systemName: "moon").foregroundStyle(.tint)
                        Text("Quiet hours").foregroundStyle(.primary)
                        Spacer()
                        if quietEffective == .night {
                            Text("Quiet now")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("Blocks every notification on the watch during the scheduled window, regardless of the alerts below.")
            }

            Section {
                if alerts.isEmpty {
                    Text("No alerts yet. Add an app or a contact with +.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(alerts) { alert in
                    Button {
                        editing = alert
                    } label: {
                        HStack {
                            Image(systemName: alert.kind == .app ? "app.badge.fill" : "person.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(alert.displayName)
                                    .foregroundStyle(.primary)
                                Text(alert.kind == .app
                                     ? String(localized: "\(Self.positionLabel(alert.degrees)) · \(alert.vibration.label) vibration")
                                     : String(localized: "\(Self.positionLabel(alert.degrees)) · calls & texts"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .onDelete { indexSet in
                    alerts.remove(atOffsets: indexSet)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Changes are sent automatically. When a matching notification arrives, the hands point at the position and the watch vibrates; anything not listed is ignored.")
            }

        }
        .navigationTitle("Notifications")
        .themedList()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { addingApp = true } label: { Label("Add app…", systemImage: "app.badge") }
                    Button { pickingContacts = true } label: { Label("Add contacts…", systemImage: "person.badge.plus") }
                    Button { addingContactByName = true } label: { Label("Add contact by name…", systemImage: "keyboard") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onChange(of: alerts) { _, newValue in
            QNotificationStore.alerts = newValue
            schedulePush()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeWatchChanged)) { _ in
            alerts = QNotificationStore.alerts
            quietEffective = QuietHoursManager.shared.effectiveMode
        }
        .sheet(item: $editing) { alert in
            QAlertEditView(alert: alert, onSave: { updated in
                if let index = alerts.firstIndex(where: { $0.id == updated.id }) {
                    alerts[index] = updated
                }
            }, onTest: { updated in
                test(updated)
            })
        }
        .sheet(isPresented: $addingApp) {
            QAddAppView { bundleId, name in
                alerts.removeAll {
                    $0.kind == .app
                        && $0.identifier.caseInsensitiveCompare(bundleId) == .orderedSame
                }
                alerts.append(QNotificationAlert(kind: .app, identifier: bundleId,
                                                 displayName: name,
                                                 degrees: nextFreePosition()))
            }
        }
        .sheet(isPresented: $pickingContacts) {
            ContactPicker { names in
                for name in names {
                    addContact(named: name)
                }
            }
            .ignoresSafeArea()
        }
        .alert("Add contact", isPresented: $addingContactByName) {
            TextField("Name as shown in notifications", text: $newContactName)
            Button("Add") {
                addContact(named: newContactName)
                newContactName = ""
            }
            Button("Cancel", role: .cancel) { newContactName = "" }
        } message: {
            Text("Enter the contact's name exactly as iOS shows it in call and message notifications.")
        }
    }

    private func addContact(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              !alerts.contains(where: { $0.kind == .contact && $0.identifier == name })
        else { return }
        alerts.append(QNotificationAlert(kind: .contact, identifier: name,
                                         displayName: name,
                                         degrees: nextFreePosition()))
    }

    /// "1 o'clock" … "12 o'clock" for the official position angles, plain
    /// degrees otherwise.
    static func positionLabel(_ degrees: Int) -> String {
        if degrees == 359 { return String(localized: "12 o'clock") }
        if degrees % 30 == 0 && degrees > 0 {
            return String(localized: "\(degrees / 30) o'clock")
        }
        return String(localized: "\(degrees)°")
    }

    /// First clock position not taken yet, so new alerts spread over the dial.
    private func nextFreePosition() -> Int {
        let taken = Set(alerts.map(\.degrees))
        for position in 1...12 {
            let degrees = QNotificationAlert.degrees(forClockPosition: position)
            if !taken.contains(degrees) { return degrees }
        }
        return 359
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasHandNotificationConfig,
                  watch.connectionState == .ready else { return }
            do {
                try await watch.setQNotificationFilter()
                await QuietHoursManager.shared.evaluate()
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

    private func test(_ alert: QNotificationAlert) {
        Task {
            do {
                try await watch.playQTestNotification(for: alert)
                await MainActor.run {
                    ToastCenter.shared.success(
                        String(localized: "Test sent — watch hands should move"))
                }
            } catch {
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

}

private struct QAlertEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var alert: QNotificationAlert
    let onSave: (QNotificationAlert) -> Void
    let onTest: (QNotificationAlert) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Hands point at", selection: $alert.degrees) {
                        ForEach(1...12, id: \.self) { position in
                            let degrees = QNotificationAlert.degrees(forClockPosition: position)
                            Text("\(position) o'clock").tag(degrees)
                        }
                    }
                } footer: {
                    Text("Both hands move to this position for 10 seconds, then return to the time.")
                }

                if alert.kind == .app {
                    Section {
                        Picker("Vibration", selection: $alert.vibration) {
                            ForEach(QVibrationPattern.allCases, id: \.self) { pattern in
                                Text(pattern.label).tag(pattern)
                            }
                        }
                    }
                } else {
                    Section {
                        LabeledContent(
                            "Vibration",
                            value: String(localized: "Triple (calls) · Double (texts)"))
                    } footer: {
                        Text("Contact alerts use the official app's fixed patterns.")
                    }
                }

                Section {
                    Button {
                        onTest(alert)
                    } label: {
                        Label("Test on watch", systemImage: "dot.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Sends a fake notification matching this alert. Apply the list to the watch first.")
                }
            }
            .navigationTitle(alert.displayName)
            .themedList()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(alert)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// System contact picker. Runs out-of-process, so it needs no Contacts
/// permission or usage description. Implementing only the plural delegate
/// method turns on multi-selection; returns the contacts' full display
/// names — the same string iOS puts on their call/text notifications.
private struct ContactPicker: UIViewControllerRepresentable {
    let onSelect: ([String]) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: ([String]) -> Void

        init(onSelect: @escaping ([String]) -> Void) {
            self.onSelect = onSelect
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onSelect(contacts.compactMap {
                CNContactFormatter.string(from: $0, style: .fullName)
            })
        }
    }
}

/// App picker: App Store search resolves the bundle id (same flow as the HR
/// notification screen, minus the icon choice — the Q has no display).
private struct QAddAppView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String, String) -> Void

    @State private var query = ""
    @State private var results: [AppStoreSearch.Result] = []
    @State private var searching = false
    @State private var searchFailed = false
    @State private var bundleId = ""
    @State private var displayName = ""

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
                         : String(localized: "Looks up the bundle ID for you."))
                }

                Section("App") {
                    TextField("Bundle ID (e.g. com.example.app)", text: $bundleId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                    TextField("Display name", text: $displayName)
                }
            }
            .navigationTitle("Add app")
            .themedList()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let normalized = ProtocolInputValidation.normalizedBundleID(bundleId) else {
                            ToastCenter.shared.error(String(localized: "Enter a valid bundle ID"))
                            return
                        }
                        onAdd(normalized, ProtocolInputValidation.displayName(
                            displayName, fallback: normalized))
                        dismiss()
                    }
                    .disabled(ProtocolInputValidation.normalizedBundleID(bundleId) == nil)
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
