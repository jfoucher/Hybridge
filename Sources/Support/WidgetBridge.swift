import Foundation
import Combine
import WidgetKit

/// One-way mirror from the app's live stores into the app-group snapshot the
/// widget extension reads. Subscribes to the already-`@Published` sources
/// instead of touching every mutation site, so all three battery write sites
/// (readConfiguration, the Q equivalent, and the GATT battery notification)
/// are covered for free.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    /// Debounces bursts of publisher activity (e.g. a sync writing many
    /// samples) into a single snapshot write.
    private static let coalesceInterval: TimeInterval = 2

    private var cancellables: Set<AnyCancellable> = []
    private var pendingFlush: DispatchWorkItem?
    /// Last snapshot actually written, for the reload gate.
    private var lastWritten: WidgetSnapshot?

    private init() {}

    func start() {
        guard cancellables.isEmpty else { return }
        changePublisher()
            .sink { [weak self] in self?.schedule() }
            .store(in: &cancellables)
        flush()
    }

    /// Merges every source that can move a value the widget renders.
    private func changePublisher() -> AnyPublisher<Void, Never> {
        let watch = WatchManager.shared
        let fitness = FitnessStore.shared
        let registry = WatchRegistry.shared
        let publishers: [AnyPublisher<Void, Never>] = [
            watch.$connectionState.map { _ in () }.eraseToAnyPublisher(),
            watch.$batteryLevel.map { _ in () }.eraseToAnyPublisher(),
            watch.$watchStepCount.map { _ in () }.eraseToAnyPublisher(),
            fitness.$samples.map { _ in () }.eraseToAnyPublisher(),
            fitness.$liveStepCountsByWatch.map { _ in () }.eraseToAnyPublisher(),
            fitness.$lastSyncByWatch.map { _ in () }.eraseToAnyPublisher(),
            registry.$watches.map { _ in () }.eraseToAnyPublisher(),
            registry.$activeWatchID.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .map { _ in () }.eraseToAnyPublisher(),
        ]
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }

    private func schedule() {
        pendingFlush?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: item)
    }

    /// Flushes immediately, bypassing the coalescing delay — for scene-phase
    /// transitions where the moment matters (final state before suspension,
    /// fresh state on foreground return).
    func flushNow() {
        pendingFlush?.cancel()
        pendingFlush = nil
        flush()
    }

    private func flush() {
        let snapshot = buildSnapshot()
        WidgetStore.save(snapshot)
        // Always write (keeps updatedAt/batteryDate fresh for the widget's
        // own staleness math), but only spend reload budget when something
        // visibly changed — connection-state flaps below .ready never do.
        if lastWritten == nil || !lastWritten!.rendersSameAs(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        lastWritten = snapshot
    }

    private func buildSnapshot() -> WidgetSnapshot {
        let watch = WatchManager.shared
        let active = WatchRegistry.shared.activeWatch
        let now = Date()
        // Same user-wide total as DashboardView: all watches' synced samples,
        // with each device's latest counter used only to top up its own share.
        let todaySteps = FitnessStore.shared.stepsIncludingLive(onDay: now)
        let stepGoal = UserDefaults.standard.object(forKey: "stepGoal") as? Int ?? 10000
        return WidgetSnapshot(
            updatedAt: now,
            watchName: active?.name,
            hasDisplay: (active?.kind ?? .hybridHR).hasDisplay,
            todaySteps: todaySteps,
            stepsDate: now,
            stepsAreLive: FitnessStore.shared.hasLiveStepCount(onDay: now),
            stepGoal: stepGoal,
            batteryPercent: watch.batteryLevel,
            batteryDate: watch.batteryLevel != nil ? now : nil,
            isConnected: watch.connectionState == .ready,
            lastSyncDate: FitnessStore.shared.lastSync(for: active?.id)
        )
    }
}
