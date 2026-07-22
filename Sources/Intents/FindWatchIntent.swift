import AppIntents

/// "Vibrate my watch" — HR uses the firmware confirm-on-device vibration
/// (findWatch, needs fw ≥ 2.22), Q has no equivalent so it just vibrates for
/// a few seconds via the plain vibration request.
struct FindWatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Vibrate My Watch"
    static var description = IntentDescription("Makes your Fossil watch vibrate so you can find it.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let watch = WatchManager.shared
        guard await watch.waitUntilReady(timeout: 20) else {
            return .result(dialog: "Couldn't reach your watch — make sure it's nearby and Bluetooth is on.")
        }
        _ = await watch.waitUntilIdle(timeout: 5)
        do {
            if WatchRegistry.activeKindSync() == .fossilQ {
                try await watch.vibrateWatch(true)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                try await watch.vibrateWatch(false)
            } else {
                _ = try await watch.findWatch()
            }
            return .result(dialog: "Vibrating your watch.")
        } catch {
            return .result(dialog: "Couldn't vibrate the watch: \(error.localizedDescription)")
        }
    }
}
