import Foundation
import BackgroundTasks
import os.log

protocol BackgroundTaskCompleting: AnyObject {
    func setTaskCompleted(success: Bool)
}

extension BGAppRefreshTask: BackgroundTaskCompleting {}

/// Drives a periodic `BGAppRefreshTask` so activity/battery data (and the
/// low-battery alert, and the home-screen widgets that read it) stay fresh
/// without the user opening the app. Reuses the exact machinery a foreground
/// reconnect already goes through — CoreBluetooth state restoration wakes the
/// process, `WatchManager` auto-reconnects and re-runs the family init to
/// `.ready` on its own, and `periodicMaintenance`/`syncActivityIfDue` are
/// idempotent and error-swallowing — so this file only needs to wait for that
/// to happen and nudge it along.
///
/// Platform limitation: if the user swipe-kills the app, iOS launches it for
/// neither BLE restoration events nor a `BGAppRefreshTask` until the next
/// manual launch. There is no workaround.
final class BackgroundRefresher: @unchecked Sendable {
    static let shared = BackgroundRefresher()

    static let identifier = "eu.sixpixels.hybridge.refresh"

    private let logger = Logger(subsystem: "eu.sixpixels.hybridge", category: "bgrefresh")

    private init() {}

    /// Must be called before app launch finishes (from `HybridgeApp.init()`).
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self.handle(refreshTask)
        }
    }

    /// Submits (replacing any pending request) the next refresh, aligned with
    /// the sync throttle so wakes rarely find nothing due. Safe to call on
    /// every backgrounding.
    func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        let syncDate = Date(timeIntervalSinceNow: WatchManager.autoSyncInterval)
        // Opportunistic wake near the next quiet-hours boundary too, so the
        // filter swap lands within minutes rather than waiting for the next
        // sync-driven wake (which can be up to autoSyncInterval late).
        // `nextBoundary` folds in the calendar-busy signal (if enabled) on
        // top of the fixed schedule, reading whatever's cached rather than
        // refreshing — a stale cache just falls back to `syncDate`.
        if WatchRegistry.activeKindSync().hasQuietHours,
           let boundary = QuietHoursManager.shared.nextBoundary(now: Date()) {
            request.earliestBeginDate = min(syncDate, boundary)
        } else {
            request.earliestBeginDate = syncDate
        }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator throws "unavailable" (code 1) on every submit —
            // debug-only so it doesn't spam the in-app log.
            logger.debug("scheduleNext submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        let completion = CompletionGuard(task: task)
        let work = BackgroundWorkGuard()
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
        }
        // First thing, per Apple's recommended pattern — keeps the chain
        // alive even across expired runs.
        scheduleNext()
        work.set(Task {
            let success = await self.run()
            guard !Task.isCancelled else { return }
            await MainActor.run { WidgetBridge.shared.flushNow() }
            completion.complete(success: success)
        })
    }

    /// Budget ~30s of background execution.
    private func run() async -> Bool {
        guard !Task.isCancelled else { return false }
        // On a fresh BG launch this creates the CBCentralManager and kicks
        // off state restoration → reconnect → family init on its own.
        let watch = WatchManager.shared
        guard let watchID = WatchRegistry.activeWatchIDSync() else { return true }

        func currentlyDue() async -> Bool {
            let last = await MainActor.run { FitnessStore.shared.lastSync(for: watchID) }
            return Self.syncIsDue(lastSync: last, now: Date())
        }

        let isReady = await MainActor.run { watch.connectionState == .ready }
        guard await currentlyDue() || !isReady else { return true }

        if !isReady {
            guard await watch.waitUntilReady(timeout: 20) else { return false }
        }
        guard !Task.isCancelled,
              WatchRegistry.activeWatchIDSync() == watchID else { return false }
        _ = await watch.waitUntilIdle(timeout: 15)
        guard !Task.isCancelled,
              WatchRegistry.activeWatchIDSync() == watchID else { return false }

        await watch.periodicMaintenance()
        await watch.syncActivityIfDue()
        await exportToHealthIfEnabled()

        return await !currentlyDue()
    }

    private func exportToHealthIfEnabled() async {
        guard UserDefaults.standard.bool(forKey: "healthAutoExportEnabled") else { return }
        let health = await MainActor.run { HealthKitExporter.shared }
        let canExport = await MainActor.run {
            health.isAvailable && health.canExportWithoutPrompt
        }
        guard canExport else { return }
        _ = try? await health.exportNewSamples(from: FitnessStore.shared, requestingAuthorization: false)
    }

    /// Pure and unit-testable: nil `lastSync` (never synced) counts as due.
    static func syncIsDue(lastSync: Date?, now: Date,
                         interval: TimeInterval = WatchManager.autoSyncInterval) -> Bool {
        guard let lastSync else { return true }
        return now.timeIntervalSince(lastSync) >= interval
    }
}

private final class BackgroundWorkGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var expired = false

    func set(_ task: Task<Void, Never>) {
        lock.withLock {
            if expired { task.cancel() } else { self.task = task }
        }
    }

    func cancel() {
        lock.withLock {
            expired = true
            task?.cancel()
            task = nil
        }
    }
}

/// Arbitrates a single call to `setTaskCompleted` — the expiration handler and
/// the normal completion path can race.
final class CompletionGuard: @unchecked Sendable {
    private let task: BackgroundTaskCompleting
    private let lock = NSLock()
    private var completed = false

    init(task: BackgroundTaskCompleting) { self.task = task }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        task.setTaskCompleted(success: success)
    }
}
