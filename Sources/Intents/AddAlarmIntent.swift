import AppIntents

enum DayOfWeekOption: String, AppEnum, CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Day of Week"
    static let caseDisplayRepresentations: [DayOfWeekOption: DisplayRepresentation] = [
        .sunday: "Sunday", .monday: "Monday", .tuesday: "Tuesday", .wednesday: "Wednesday",
        .thursday: "Thursday", .friday: "Friday", .saturday: "Saturday",
    ]

    /// Bit index in WatchAlarm.daysMask (Sun=0 Mon=1 Tue=2 Thu=3 Wed=4 Fri=5 Sat=6).
    var bitIndex: Int {
        switch self {
        case .sunday: return 0
        case .monday: return 1
        case .tuesday: return 2
        case .thursday: return 3
        case .wednesday: return 4
        case .friday: return 5
        case .saturday: return 6
        }
    }
}

/// "Add a watch alarm" — appends to the same store AlarmsView edits, then
/// pushes the whole alarm list like a manual add would. Saves locally even
/// when the watch is unreachable; the next connect/init/foreground pushes it.
struct AddAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Watch Alarm"
    static let description = IntentDescription("Adds an alarm to your Fossil watch.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Time")
    var time: Date

    @Parameter(title: "Repeat On", default: [])
    var days: [DayOfWeekOption]

    @Parameter(title: "Label", default: "Alarm")
    var label: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let intendedWatchID = WatchRegistry.activeWatchIDSync() else {
            return .result(dialog: "No watch is selected.")
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        var mask: UInt8 = 0
        for day in days { mask |= 1 << day.bitIndex }
        // The legacy (non-TLV) alarm file the Q watches use has no room for
        // labels — matches AlarmsView's supportsLabels rule.
        let alarmLabel = WatchRegistry.activeKindSync().hasDisplay ? label : ""
        let alarm = WatchAlarm(hour: components.hour ?? 8, minute: components.minute ?? 0,
                               daysMask: mask, repeats: !days.isEmpty, label: alarmLabel)

        var alarms = AlarmStorage.load()
        alarms.append(alarm)
        AlarmStorage.save(alarms)

        let watch = WatchManager.shared
        guard await watch.waitUntilReady(timeout: 15) else {
            return .result(dialog: "Alarm saved — will apply once your watch reconnects.")
        }
        _ = await watch.waitUntilIdle(timeout: 5)
        guard WatchRegistry.activeWatchIDSync() == intendedWatchID else {
            return .result(dialog: "Alarm saved, but the selected watch changed before delivery.")
        }
        do {
            try await watch.setAlarms(alarms)
            return .result(dialog: "Alarm added.")
        } catch {
            return .result(dialog: "Alarm saved, but couldn't reach your watch: \(error.localizedDescription)")
        }
    }
}
