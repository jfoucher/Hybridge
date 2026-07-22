import AppIntents

struct FossilShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncWatchIntent(),
            phrases: [
                "Sync my \(.applicationName) watch",
                "Sync \(.applicationName)",
            ],
            shortTitle: "Sync Watch",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: FindWatchIntent(),
            phrases: [
                "Vibrate my \(.applicationName) watch",
                "Find my \(.applicationName) watch",
            ],
            shortTitle: "Vibrate Watch",
            systemImageName: "applewatch.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: SetQuietModeIntent(),
            phrases: [
                "Set \(.applicationName) quiet mode",
            ],
            shortTitle: "Quiet Mode",
            systemImageName: "moon.fill"
        )
        AppShortcut(
            intent: AddAlarmIntent(),
            phrases: [
                "Add a \(.applicationName) alarm",
            ],
            shortTitle: "Add Alarm",
            systemImageName: "alarm"
        )
    }
}
