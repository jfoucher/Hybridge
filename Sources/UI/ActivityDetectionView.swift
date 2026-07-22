import SwiftUI

/// Workout auto-detection + inactivity warning settings (encrypted config
/// items 0x14 and 0x09).
struct ActivityDetectionView: View {
    @EnvironmentObject var watch: WatchManager
    @AppStorage("workoutDetection") private var storedDetection = Data()
    @State private var settings = WorkoutDetectionSettings()

    @AppStorage("inactivityEnabled") private var inactivityEnabled = false
    @AppStorage("inactivityMinutes") private var inactivityMinutes = 60
    @AppStorage("inactivityStart") private var inactivityStart = 8 * 60    // minutes from midnight
    @AppStorage("inactivityEnd") private var inactivityEnd = 20 * 60

    @State private var pushTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                activityEditor("Running", \.running)
                activityEditor("Biking", \.biking)
                activityEditor("Walking", \.walking)
                activityEditor("Rowing", \.rowing)
            } header: {
                Text("Workout auto-detection")
            } footer: {
                Text("The watch detects the activity after the configured number of minutes; \"ask first\" shows a confirmation on the watch instead of starting silently.")
            }

            Section {
                Toggle("Warn when inactive", isOn: $inactivityEnabled)
                if inactivityEnabled {
                    Stepper("After \(inactivityMinutes) min", value: $inactivityMinutes, in: 15...240, step: 15)
                    DatePicker("From", selection: minuteBinding($inactivityStart), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minuteBinding($inactivityEnd), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Inactivity warning")
            } footer: {
                Text("Changes are saved and sent to compatible watches automatically.")
            }
        }
        .navigationTitle("Activity detection")
        .themedList()
        .onAppear(perform: loadStored)
        .onChange(of: settings) { _, newValue in
            storedDetection = (try? JSONEncoder().encode(newValue)) ?? Data()
            schedulePush()
        }
        .onChange(of: inactivityEnabled) { _, _ in schedulePush() }
        .onChange(of: inactivityMinutes) { _, _ in schedulePush() }
        .onChange(of: inactivityStart) { _, _ in schedulePush() }
        .onChange(of: inactivityEnd) { _, _ in schedulePush() }
    }

    private func loadStored() {
        if let decoded = try? JSONDecoder().decode(WorkoutDetectionSettings.self, from: storedDetection) {
            settings = decoded
        }
    }

    private func activityEditor(_ title: LocalizedStringResource,
                                _ keyPath: WritableKeyPath<WorkoutDetectionSettings, WorkoutDetectionSettings.Activity>) -> some View {
        DisclosureGroup(title) {
            Toggle("Detect automatically", isOn: Binding(
                get: { settings[keyPath: keyPath].recognize },
                set: { settings[keyPath: keyPath].recognize = $0 }))
            if settings[keyPath: keyPath].recognize {
                Toggle("Ask before starting", isOn: Binding(
                    get: { settings[keyPath: keyPath].askFirst },
                    set: { settings[keyPath: keyPath].askFirst = $0 }))
                Stepper("After \(settings[keyPath: keyPath].minutes) min", value: Binding(
                    get: { settings[keyPath: keyPath].minutes },
                    set: { settings[keyPath: keyPath].minutes = $0 }), in: 1...30)
            }
        }
    }

    private func minuteBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                let components = DateComponents(hour: minutes.wrappedValue / 60,
                                                minute: minutes.wrappedValue % 60)
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasWorkouts,
                  watch.connectionState == .ready, watch.isAuthenticated else { return }
            do {
                try await watch.writeConfig([
                    .fitnessDetection(settings),
                    .inactivityWarning(
                        from: (UInt8(inactivityStart / 60), UInt8(inactivityStart % 60)),
                        until: (UInt8(inactivityEnd / 60), UInt8(inactivityEnd % 60)),
                        minutes: UInt8(inactivityMinutes), enabled: inactivityEnabled),
                ])
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}
