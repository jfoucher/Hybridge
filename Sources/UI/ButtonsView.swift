import SwiftUI

/// Assign watch apps to the three physical buttons × short/long press
/// (`master._.config.buttons`).
struct ButtonsView: View {
    @EnvironmentObject var watch: WatchManager
    /// "<button>_<press>" → appName ("" = unassigned).
    @State private var selections: [String: String] = Self.storedSelections()
    @State private var pushTask: Task<Void, Never>?

    private let noneTag = ""

    private var appOptions: [String] {
        var names = Set(watch.installedApps.map(\.name))
        names.insert("workoutApp")
        // Keep current picks visible even if the app isn't currently installed.
        names.formUnion(selections.values.filter { !$0.isEmpty })
        return names.sorted { $0.lowercased() < $1.lowercased() }
    }

    var body: some View {
        ThemedScreen("Buttons") {
            ForEach(WatchButton.allCases, id: \.self) { button in
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("\(button.rawValue.capitalized) button")
                        .padding(.top, button == WatchButton.allCases.first ? 0 : 22)
                    ThemedCard {
                        pickerRow("Short press", button: button, press: .short)
                        Hairline(leading: 59)
                        pickerRow("Long press (hold)", button: button, press: .long)
                    }
                }
            }

            Footer("Changes are saved and sent automatically. A button left on \"None\" falls back to its default app (the middle short-press opens the launcher). Apps that aren't installed on the watch are skipped; workoutApp is always available.")
                .padding(.top, 12)
        }
        .onChange(of: selections) { _, _ in
            let picks = currentSelections()
            ButtonStore.selections = picks
            schedulePush(picks)
        }
    }

    private func pickerRow(_ title: LocalizedStringResource,
                           button: WatchButton, press: ButtonPress) -> some View {
        let key = "\(button.rawValue)_\(press.rawValue)"
        let binding = Binding(
            get: { selections[key] ?? noneTag },
            set: { selections[key] = $0 }
        )
        return SettingsRow(icon: press == .short ? "hand.tap" : "hand.tap.fill", title: title) {
            Menu {
                Picker(title, selection: binding) {
                    Text("None").tag(noneTag)
                    ForEach(appOptions, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(binding.wrappedValue.isEmpty ? String(localized: "None")
                                                      : binding.wrappedValue)
                        .font(Theme.sans(15, relativeTo: .body))
                        .foregroundStyle(Theme.sub)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.chevron)
                }
            }
            .accessibilityLabel(Text("\(String(localized: title)): \(binding.wrappedValue.isEmpty ? String(localized: "None") : binding.wrappedValue)"))
        }
    }

    private static func storedSelections() -> [String: String] {
        var map: [String: String] = [:]
        for selection in ButtonStore.selections {
            map["\(selection.button.rawValue)_\(selection.press.rawValue)"] = selection.appName
        }
        return map
    }

    private func currentSelections() -> [ButtonSelection] {
        var result: [ButtonSelection] = []
        for button in WatchButton.allCases {
            for press in ButtonPress.allCases {
                let app = selections["\(button.rawValue)_\(press.rawValue)"] ?? ""
                if !app.isEmpty {
                    result.append(ButtonSelection(button: button, press: press, appName: app))
                }
            }
        }
        return result
    }

    private func schedulePush(_ picks: [ButtonSelection]) {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasApps,
                  watch.connectionState == .ready, watch.isAuthenticated else { return }
            do {
                try await watch.setButtons(picks)
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}
