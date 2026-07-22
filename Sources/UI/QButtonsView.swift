import SwiftUI

/// Button assignment for the non-HR Q hybrids: each of the three pushers
/// gets one precompiled firmware function (file 0x0600).
struct QButtonsView: View {
    @EnvironmentObject var watch: WatchManager

    @State private var functions: [QButtonFunction] = QButtonStore.functions ?? QButtonStore.defaults
    @State private var multiPress: [QMultiPressAction] = QMultiPressStore.actions
    @State private var pushTask: Task<Void, Never>?

    private static let buttonNames: [LocalizedStringResource] = ["Top", "Middle", "Bottom"]
    private static let pressNames: [LocalizedStringResource] = [
        "Single press", "Double press", "Long press",
    ]

    var body: some View {
        Form {
            Section {
                ForEach(0..<3, id: \.self) { index in
                    Picker(Self.buttonNames[index], selection: $functions[index]) {
                        ForEach(QButtonFunction.allCases, id: \.self) { function in
                            Text(function.displayName).tag(function)
                        }
                    }
                }
            } footer: {
                Text("Changes are saved and sent automatically. On-watch functions (date, stopwatch, time zone, step goal) show their result with the hands. Music control and volume drive the phone; \"Find my phone\" rings it.")
            }

            if functions.contains(.forwardToPhoneMulti) {
                Section {
                    ForEach(0..<3, id: \.self) { index in
                        Picker(Self.pressNames[index], selection: $multiPress[index]) {
                            ForEach(QMultiPressAction.allCases, id: \.self) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                    }
                } header: {
                    Text("Multi-press actions")
                } footer: {
                    Text("For buttons set to \"Forward to phone (multi-press)\". These run on the phone, so changes apply immediately — no upload needed. Volume only works while the app is in the foreground (iOS limitation). If another button is set to Music control, that takes over single/double/long presses.")
                }
            }

        }
        .navigationTitle("Buttons")
        .themedList()
        .onChange(of: functions) { _, newValue in
            QButtonStore.functions = newValue
            schedulePush()
        }
        .onChange(of: multiPress) { _, newValue in
            QMultiPressStore.actions = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeWatchChanged)) { _ in
            functions = QButtonStore.functions ?? QButtonStore.defaults
            multiPress = QMultiPressStore.actions
        }
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasButtonConfigFile,
                  watch.connectionState == .ready else { return }
            do {
                try await watch.setQButtons()
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}
