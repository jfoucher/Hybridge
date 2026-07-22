import SwiftUI

/// Alarms are kept locally (the watch file is write-only in this app) and
/// pushed as a whole file automatically on every add/edit/delete/toggle.
struct AlarmsView: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @State private var alarms: [WatchAlarm] = AlarmStorage.load()
    @State private var editing: WatchAlarm?

    /// The legacy (non-TLV) alarm file the Q watches use has no room for
    /// labels — they'd silently stay phone-only, so don't offer them.
    private var supportsLabels: Bool {
        (registry.activeWatch?.kind ?? .hybridHR).hasDisplay
    }

    var body: some View {
        NavigationStack {
            ThemedScreen("Alarms", action: (symbol: "plus", run: addAlarm)) {
                Footer("Alarms fire on the watch as a vibration. Up to 8 can be stored on the device.")
                    .padding(.top, -2)
                    .padding(.bottom, 16)

                if alarms.isEmpty {
                    ThemedCard {
                        Text("No alarms yet. Tap + to add one.")
                            .font(Theme.sans(15, relativeTo: .body))
                            .foregroundStyle(Theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }

                VStack(spacing: 14) {
                    ForEach($alarms) { $alarm in
                        alarmCard($alarm)
                    }
                }

                Footer("Because the watch has no speaker, alarms are silent — they vibrate the case. Repeat days are stored per alarm and applied on the next sync.")
                    .padding(.top, 8)
                if alarms.count >= 8 {
                    Footer("Maximum 8 alarms.").padding(.top, 2)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editing) { alarm in
                AlarmEditView(alarm: alarm, showsLabel: supportsLabels) { updated in
                    if let index = alarms.firstIndex(where: { $0.id == updated.id }) {
                        alarms[index] = updated
                    }
                }
            }
            .onChange(of: alarms) { _, newValue in
                AlarmStorage.save(newValue)
                push(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeWatchChanged)) { _ in
                alarms = AlarmStorage.load()
            }
        }
    }

    private func addAlarm() {
        guard alarms.count < 8 else {
            ToastCenter.shared.error(String(localized: "You can store up to 8 alarms."))
            return
        }
        let new = WatchAlarm(hour: 8, minute: 0, daysMask: 0b0111_1111,
                             repeats: true, label: String(localized: "Alarm"))
        alarms.append(new)
        editing = new
    }

    private func alarmCard(_ alarm: Binding<WatchAlarm>) -> some View {
        let a = alarm.wrappedValue
        return SwipeToDelete(cornerRadius: 22,
                             shadow: Theme.ShadowStyle(color: .black.opacity(0.04), radius: 9, y: 4),
                             onDelete: { alarms.removeAll { $0.id == a.id } }) {
            ThemedCard {
                HStack(alignment: .top) {
                    Button { editing = a } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            timeText(a)
                            Text(alarmSubtitle(a))
                                .font(Theme.sans(14, relativeTo: .subheadline))
                                .foregroundStyle(Theme.sub)
                            if a.repeats {
                                DayChips(daysMask: a.daysMask)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 12)

                    Toggle(isOn: alarm.enabled) { EmptyView() }.labelsHidden().brassToggle()
                        .accessibilityLabel("Alarm enabled")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .opacity(a.enabled ? 1 : 0.62)
        }
    }

    /// Large mono time with a brass colon.
    private func timeText(_ a: WatchAlarm) -> some View {
        let date = Calendar.current.date(from: DateComponents(hour: a.hour, minute: a.minute)) ?? Date()
        return Text(date.formatted(date: .omitted, time: .shortened))
            .font(Theme.mono(44, weight: .light))
            .tracking(-1)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .foregroundStyle(Theme.ink)
    }

    private func alarmSubtitle(_ alarm: WatchAlarm) -> String {
        let recurrence: String
        if !alarm.repeats {
            recurrence = String(localized: "Once")
        } else if alarm.daysMask == 0b0111_1111 {
            recurrence = String(localized: "Every day")
        } else if alarm.daysMask == 0b0011_1110 {
            recurrence = String(localized: "Weekdays")
        } else {
            let days = (0..<7).filter { alarm.daysMask & (1 << $0) != 0 }
                .map { WatchAlarm.dayNames[$0] }
            recurrence = ListFormatter.localizedString(byJoining: days)
        }
        guard supportsLabels, !alarm.label.isEmpty else { return recurrence }
        return String(localized: "\(alarm.label) · \(recurrence)")
    }

    private func push(_ alarms: [WatchAlarm]) {
        Task {
            do {
                try await watch.setAlarms(alarms)
            } catch {
                await MainActor.run {
                    ToastCenter.shared.error(
                        String(localized: "Alarms not sent: \(error.localizedDescription)"))
                }
            }
        }
    }
}

struct AlarmEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var alarm: WatchAlarm
    var showsLabel = true
    let onSave: (WatchAlarm) -> Void

    @State private var time = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)

                if showsLabel {
                    TextField("Label", text: $alarm.label)
                }

                Toggle("Repeat", isOn: $alarm.repeats)

                if alarm.repeats {
                    Section("Days") {
                        // Displayed Mon..Sun; mapped to the watch's bit order.
                        ForEach(displayOrder, id: \.self) { bit in
                            Toggle(WatchAlarm.dayNames[bit], isOn: dayBinding(bit))
                        }
                    }
                }
            }
            .navigationTitle("Edit alarm")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
                        alarm.hour = components.hour ?? 8
                        alarm.minute = components.minute ?? 0
                        onSave(alarm)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                var components = DateComponents()
                components.hour = alarm.hour
                components.minute = alarm.minute
                time = Calendar.current.date(from: components) ?? Date()
            }
        }
    }

    /// Bit indices in the order Mon, Tue, Wed, Thu, Fri, Sat, Sun (bit values
    /// follow WatchAlarm.dayNames: Sun=0 Mon=1 Tue=2 Thu=3 Wed=4 Fri=5 Sat=6).
    private var displayOrder: [Int] { [1, 2, 4, 3, 5, 6, 0] }

    private func dayBinding(_ bit: Int) -> Binding<Bool> {
        Binding(
            get: { alarm.daysMask & (1 << bit) != 0 },
            set: { on in
                if on { alarm.daysMask |= (1 << bit) }
                else { alarm.daysMask &= ~UInt8(1 << bit) }
            }
        )
    }
}

/// Scoped per watch: each watch keeps its own alarm list.
enum AlarmStorage {
    private static var key: String { WatchScoped.key(.storedAlarms) }

    static func load() -> [WatchAlarm] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let alarms = try? JSONDecoder().decode([WatchAlarm].self, from: data)
        else { return [] }
        return alarms
    }

    static func save(_ alarms: [WatchAlarm]) {
        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
