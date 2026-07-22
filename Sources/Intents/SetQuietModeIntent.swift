import AppIntents

enum QuietModeOption: String, AppEnum {
    case on, off, auto

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Quiet Mode"
    static var caseDisplayRepresentations: [QuietModeOption: DisplayRepresentation] = [
        .on: "On",
        .off: "Off",
        .auto: "Auto",
    ]
}

/// "Set quiet mode" — drives QuietHoursManager's override, so it works even
/// while the watch is disconnected (the override applies on next connect).
struct SetQuietModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Watch Quiet Mode"
    static var description = IntentDescription("Turns your watch's quiet hours on, off, or back to the schedule.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Mode")
    var mode: QuietModeOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard WatchRegistry.activeKindSync().hasQuietHours else {
            return .result(dialog: "Quiet hours are not available for this watch in this release.")
        }
        let watch = WatchManager.shared
        let becameReady = await watch.waitUntilReady(timeout: 15)
        if becameReady { _ = await watch.waitUntilIdle(timeout: 5) }

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
