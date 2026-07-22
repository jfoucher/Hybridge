import AppIntents

/// "Sync my watch" — downloads new activity data. Launched by Shortcuts with
/// the app not running still gets the central-restoration auto-connect chain
/// (waitUntilReady), identical to the BG-refresh path.
struct SyncWatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Watch"
    static var description = IntentDescription("Downloads new activity data from your Fossil watch.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let watch = WatchManager.shared
        guard await watch.waitUntilReady(timeout: 20) else {
            return .result(dialog: "Couldn't reach your watch — make sure it's nearby and Bluetooth is on.")
        }
        _ = await watch.waitUntilIdle(timeout: 5)
        do {
            let count = try await watch.syncActivity()
            return .result(dialog: count > 0 ? "Synced \(count) new samples." : "Already up to date.")
        } catch {
            return .result(dialog: "Sync failed: \(error.localizedDescription)")
        }
    }
}
