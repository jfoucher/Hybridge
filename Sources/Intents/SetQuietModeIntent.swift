import AppIntents

enum QuietModeOption: String, AppEnum {
    case on, off, auto

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quiet Mode"
    static let caseDisplayRepresentations: [QuietModeOption: DisplayRepresentation] = [
        .on: "On",
        .off: "Off",
        .auto: "Auto",
    ]
}

/// "Set quiet mode" — drives QuietHoursManager's override, so it works even
/// while the watch is disconnected (the override applies on next connect).
struct SetQuietModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Watch Quiet Mode"
    static let description = IntentDescription("Turns your watch's quiet hours on, off, or back to the schedule.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Mode")
    var mode: QuietModeOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let intendedWatchID = WatchRegistry.activeWatchIDSync() else {
            return .result(dialog: "No watch is selected.")
        }
        guard WatchRegistry.activeKindSync().hasQuietHours else {
            return .result(dialog: "Quiet hours are not available for this watch in this release.")
        }
        let watch = WatchManager.shared
        let becameReady = await watch.waitUntilReady(timeout: 15)
        if becameReady { _ = await watch.waitUntilIdle(timeout: 5) }
        guard WatchRegistry.activeWatchIDSync() == intendedWatchID else {
            return .result(dialog: "The selected watch changed before quiet mode could be applied.")
        }

        let override: QuietMode?
        switch mode {
        case .on: override = .night
        case .off: override = .day
        case .auto: override = nil
        }
        // setOverride evaluates internally and only pushes when connected.
        await QuietHoursManager.shared.setOverride(override)

        let modeText = switch mode {
        case .on: String(localized: "Quiet mode on")
        case .off: String(localized: "Quiet mode off")
        case .auto: String(localized: "Back to the quiet-hours schedule")
        }
        return .result(dialog: becameReady ? "\(modeText)."
                                           : "\(modeText) — will apply once your watch reconnects.")
    }
}
