import Foundation
import HealthKit
import Combine

@MainActor
protocol HealthStoreWriting: AnyObject {
    var isHealthDataAvailable: Bool { get }
    func requestAuthorization() async throws
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
    func save(_ samples: [HKSample]) async throws
    func saveWorkout(_ workout: WorkoutSummary) async throws
}

@MainActor
private final class LiveHealthStoreWriter: HealthStoreWriting {
    private let store = HKHealthStore()
    private let caloriesType = HKQuantityType(.activeEnergyBurned)

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        let types: Set<HKSampleType> = [
            HKQuantityType(.stepCount), HKQuantityType(.heartRate), caloriesType,
            HKQuantityType(.oxygenSaturation), HKCategoryType(.sleepAnalysis),
            HKWorkoutType.workoutType(), HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
        ]
        try await store.requestAuthorization(toShare: types, read: [])
    }

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        store.authorizationStatus(for: type)
    }

    func save(_ samples: [HKSample]) async throws {
        try await store.save(samples)
    }

    func saveWorkout(_ workout: WorkoutSummary) async throws {
        let start = Date(timeIntervalSince1970: TimeInterval(workout.startTimestamp))
        let end = Date(timeIntervalSince1970: TimeInterval(workout.endTimestamp))
        let config = HKWorkoutConfiguration()
        config.activityType = Self.activityType(for: workout.kind)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        try await builder.beginCollection(at: start)
        try await builder.addMetadata(Self.metadata(
            workout: workout, timestamp: workout.startTimestamp, kind: "workout"))

        var samples: [HKSample] = []
        if let distance = workout.distanceMeters, distance > 0 {
            let distanceType = config.activityType == .cycling
                ? HKQuantityType(.distanceCycling)
                : HKQuantityType(.distanceWalkingRunning)
            if authorizationStatus(for: distanceType) == .sharingAuthorized {
                samples.append(HKQuantitySample(
                    type: distanceType,
                    quantity: HKQuantity(unit: .meter(), doubleValue: Double(distance)),
                    start: start, end: end,
                    metadata: Self.metadata(workout: workout,
                                            timestamp: workout.startTimestamp, kind: "wdist")))
            }
        }
        if authorizationStatus(for: caloriesType) == .sharingAuthorized,
           let calories = workout.calories, calories > 0 {
            samples.append(HKQuantitySample(
                type: caloriesType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(calories)),
                start: start, end: end,
                metadata: Self.metadata(workout: workout,
                                        timestamp: workout.startTimestamp, kind: "wkcal")))
        }
        if !samples.isEmpty { try await builder.addSamples(samples) }
        try await builder.endCollection(at: end)
        try await builder.finishWorkout()
    }

    private static func metadata(workout: WorkoutSummary, timestamp: Int,
                                 kind: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier:
            "hybridge.\(workout.watchID?.uuidString ?? "legacy").\(kind).\(timestamp)",
         HKMetadataKeySyncVersion: 1]
    }

    private static func activityType(for kind: String) -> HKWorkoutActivityType {
        switch kind {
        case "Running", "Treadmill": return .running
        case "Cycling", "Spinning": return .cycling
        case "Cross trainer": return .crossTraining
        case "Weightlifting": return .traditionalStrengthTraining
        case "Walking": return .walking
        case "Rowing machine": return .rowing
        case "Hiking": return .hiking
        default: return .other
        }
    }
}

/// Writes synced watch samples into Apple Health. Only samples newer than the
/// last export are written, so repeated exports don't duplicate.
@MainActor
final class HealthKitExporter: ObservableObject {
    static let shared = HealthKitExporter()

    @Published var lastExportDate: Date? {
        didSet { defaults.set(lastExportDate, forKey: Self.lastExportKey) }
    }
    @Published var isAvailable: Bool

    private let store: any HealthStoreWriting
    private let defaults: UserDefaults
    private static let lastExportKey = "healthLastExport"
    private static let exportedRangesKey = "healthExportedRanges"

    /// Per-watch timestamp intervals already exported, merged and sorted.
    ///
    /// This replaces the old "sample timestamp > lastExportDate" filter, which
    /// compared *sample* time against *wall-clock* export time and so skipped
    /// backfill forever: a second watch worn yesterday and synced today, or any
    /// watch that went a week without syncing, produced samples older than the
    /// last export that could never be written. An interval set records what
    /// was actually covered, so late-arriving older data still goes out.
    ///
    /// Keyed by watch UUID string ("legacy" for untagged pre-multi-watch rows).
    private var exportedRanges: [String: [ExportedRange]] = [:]

    struct ExportedRange: Codable {
        var start: Int
        var end: Int
        func covers(_ timestamp: Int) -> Bool { timestamp >= start && timestamp <= end }
    }

    private let stepsType = HKQuantityType(.stepCount)
    private let heartRateType = HKQuantityType(.heartRate)
    private let caloriesType = HKQuantityType(.activeEnergyBurned)
    private let spo2Type = HKQuantityType(.oxygenSaturation)
    private let sleepType = HKCategoryType(.sleepAnalysis)
    /// Coalesces foreground and background triggers into one transaction. The
    /// actor isolation protects `exportedRanges`; this task prevents actor
    /// reentrancy at HealthKit `await` points from starting a second export.
    private var activeExport: Task<Int, Error>?

    private static let autoExportKey = "healthAutoExportEnabled"
    private var autoExportCancellable: AnyCancellable?

    /// Watches `fitness`'s published arrays so newly-synced samples reach
    /// Apple Health while the app is foregrounded, without waiting for the
    /// next scheduled `BackgroundRefresher` run (which covers the app-suspended
    /// case on its own timer via `exportToHealthIfEnabled`). No-op unless the
    /// "auto-export" setting is on and HealthKit is already authorized —
    /// mirrors `BackgroundRefresher`'s no-prompt gate so a background-launched
    /// foreground session never surprises the user with a permission sheet.
    func startAutoExportObserving(_ fitness: FitnessStore) {
        guard autoExportCancellable == nil else { return }
        let publishers: [AnyPublisher<Void, Never>] = [
            fitness.$samples.map { _ in () }.eraseToAnyPublisher(),
            fitness.$spo2Samples.map { _ in () }.eraseToAnyPublisher(),
            fitness.$workouts.map { _ in () }.eraseToAnyPublisher(),
        ]
        autoExportCancellable = Publishers.MergeMany(publishers)
            // Coalesces one sync's several array updates into one export.
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { [weak self, weak fitness] in
                guard let fitness else { return }
                Task { await self?.autoExportIfEnabled(from: fitness) }
            }
    }

    private func autoExportIfEnabled(from fitness: FitnessStore) async {
        guard UserDefaults.standard.bool(forKey: Self.autoExportKey) else { return }
        guard isAvailable, canExportWithoutPrompt else { return }
        _ = try? await exportNewSamples(from: fitness, requestingAuthorization: false)
    }

    init(store: (any HealthStoreWriting)? = nil, defaults: UserDefaults = .standard) {
        let store = store ?? LiveHealthStoreWriter()
        self.store = store
        self.defaults = defaults
        self.isAvailable = store.isHealthDataAvailable
        lastExportDate = defaults.object(forKey: Self.lastExportKey) as? Date
        if let data = defaults.data(forKey: Self.exportedRangesKey),
           let decoded = try? JSONDecoder().decode([String: [ExportedRange]].self, from: data) {
            exportedRanges = decoded
        } else if let lastExport = lastExportDate {
            // Migration: existing installs have already written everything up
            // to `lastExportDate`. Seed one open-ended-at-the-start interval so
            // they don't get a mass re-export of months of history on upgrade.
            exportedRanges = ["*": [ExportedRange(start: .min, end: Int(lastExport.timeIntervalSince1970))]]
        }
    }

    /// Whether `timestamp` from `watchID` has already been exported. The "*"
    /// bucket is the pre-upgrade migration seed and applies to every watch.
    private func alreadyExported(_ timestamp: Int, watchID: UUID?) -> Bool {
        let key = watchID?.uuidString ?? "legacy"
        for range in exportedRanges["*"] ?? [] where range.covers(timestamp) { return true }
        for range in exportedRanges[key] ?? [] where range.covers(timestamp) { return true }
        return false
    }

    /// Records `[start, end]` as exported for one watch, merging overlapping
    /// and adjacent intervals so the list stays a handful of entries.
    private func markExported(from start: Int, to end: Int, watchID: UUID?) {
        guard start <= end else { return }
        let key = watchID?.uuidString ?? "legacy"
        exportedRanges[key] = Self.merged((exportedRanges[key] ?? [])
                                          + [ExportedRange(start: start, end: end)])
        persistExportedRanges()
    }

    /// Activity samples are one per minute; a gap larger than this between two
    /// exported timestamps is treated as genuinely-missing data (a break in
    /// coverage), not just cadence. 90 s tolerates minor jitter while still
    /// breaking on a single skipped minute.
    nonisolated static let exportCadenceTolerance = 90

    /// Records the exact set of exported `timestamps` for one watch. Consecutive
    /// timestamps within the sampling cadence coalesce into a range, but a real
    /// gap starts a new one — so a minute missing at export time and arriving
    /// later still falls outside coverage and gets exported (§5.5). Contrast
    /// with `markExported(from:to:)`, whose single span swallows such gaps.
    private func markExported(timestamps: [Int], watchID: UUID?) {
        guard !timestamps.isEmpty else { return }
        let key = watchID?.uuidString ?? "legacy"
        let fresh = Self.contiguousRanges(timestamps, maxGap: Self.exportCadenceTolerance)
        exportedRanges[key] = Self.merged((exportedRanges[key] ?? []) + fresh)
        persistExportedRanges()
    }

    /// Builds `[start, end]` ranges from a set of timestamps, starting a new
    /// range wherever the gap to the next exceeds `maxGap`. Internal so it can
    /// be tested directly.
    nonisolated static func contiguousRanges(_ timestamps: [Int], maxGap: Int) -> [ExportedRange] {
        var ranges: [ExportedRange] = []
        for ts in timestamps.sorted() {
            if var last = ranges.last, ts - last.end <= maxGap {
                last.end = max(last.end, ts)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append(ExportedRange(start: ts, end: ts))
            }
        }
        return ranges
    }

    /// Sorts and coalesces overlapping *and* adjacent intervals, so a run of
    /// contiguous daily syncs collapses to one entry instead of growing the
    /// list forever. Genuine gaps (a watch synced late, backfilling an earlier
    /// day) are preserved — that gap is what makes backfill exportable.
    /// Internal rather than private so it can be tested directly.
    nonisolated static func merged(_ ranges: [ExportedRange]) -> [ExportedRange] {
        var result: [ExportedRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, range.start <= last.end + 1 {
                last.end = max(last.end, range.end)
                result[result.count - 1] = last
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func persistExportedRanges() {
        guard let data = try? JSONEncoder().encode(exportedRanges) else { return }
        defaults.set(data, forKey: Self.exportedRangesKey)
    }

    /// Stable identity for a written sample. HealthKit replaces rather than
    /// duplicates same-identifier samples from the same source, so even if the
    /// interval bookkeeping above is wrong (a restore, a reinstall), the user's
    /// Health store cannot end up with two copies of one minute.
    nonisolated private static func syncMetadata(watchID: UUID?, timestamp: Int, kind: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: "hybridge.\(watchID?.uuidString ?? "legacy").\(kind).\(timestamp)",
         HKMetadataKeySyncVersion: 1]
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization()
    }

    /// Whether `fitness` holds any data point not yet covered by
    /// `exportedRanges` — lets the UI disable the export button instead of
    /// running an export just to discover there's nothing to do.
    func hasNewData(in fitness: FitnessStore) -> Bool {
        guard let latest = fitness.latestDataTimestamp else { return false }
        guard let lastExportDate else { return true }
        return latest > lastExportDate
    }

    /// Whether at least one type is already authorized, so a background
    /// run without HealthKit presenting its permission sheet — the gate for
    /// exporting from a background task, where prompting is forbidden.
    var canExportWithoutPrompt: Bool {
        [stepsType, heartRateType, caloriesType, spo2Type, sleepType, HKWorkoutType.workoutType(),
         HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling)]
            .contains { store.authorizationStatus(for: $0) == .sharingAuthorized }
    }

    /// Export everything newer than the last export. Returns sample count.
    /// `requestingAuthorization` is false for background-triggered exports,
    /// where presenting the permission sheet is forbidden — callers there
    /// must gate on `canExportWithoutPrompt` first.
    @discardableResult
    func exportNewSamples(from fitness: FitnessStore, requestingAuthorization: Bool = true) async throws -> Int {
        if let activeExport { return try await activeExport.value }
        let task = Task {
            try await self.performExport(from: fitness,
                                         requestingAuthorization: requestingAuthorization)
        }
        activeExport = task
        defer { activeExport = nil }
        return try await task.value
    }

    private func performExport(from fitness: FitnessStore,
                               requestingAuthorization: Bool) async throws -> Int {
        if requestingAuthorization {
            try await requestAuthorization()
        }

        // Snapshot on the main actor. `FitnessStore` publishes these arrays and
        // mutates them there (merge runs inside MainActor.run), so iterating
        // them from this background task would race the copy-on-write buffer.
        var sleepSessions: [FitnessStore.SleepSession] = []
        for daysBack in 0..<14 {
            guard let day = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())
            else { continue }
            sleepSessions.append(contentsOf: fitness.sleepSessions(nightEnding: day))
        }
        let snapshot = StoreSnapshot(samples: fitness.samples,
                                     spo2: fitness.spo2Samples,
                                     workouts: fitness.workouts,
                                     sleepSessions: sleepSessions)

        // Construct and save at most this many HealthKit objects at a time.
        // The previous implementation built the entire multi-month export in
        // memory and only chunked the eventual save calls.
        let chunkSize = 5000
        var batch: [HKSample] = []
        batch.reserveCapacity(chunkSize + 3)
        var savedSampleCount = 0
        // The exact timestamps exported, per watch, recorded once the write
        // succeeds. NOT a min/max span: a span marks everything between the
        // oldest and newest exported sample as covered, so a minute that was
        // missing at export time (a second watch's data not yet synced) and
        // arrives later would be seen as already-exported and dropped forever
        // (§5.5). Collecting the actual timestamps preserves the gaps.
        var covered: [String: [Int]] = [:]
        func note(_ timestamp: Int, _ watchID: UUID?) {
            covered[watchID?.uuidString ?? "legacy", default: []].append(timestamp)
        }
        func authorized(_ type: HKSampleType) -> Bool {
            store.authorizationStatus(for: type) == .sharingAuthorized
        }

        for sample in snapshot.samples
        where !alreadyExported(sample.timestamp, watchID: sample.watchID) {
            let initialCount = batch.count
            let start = Date(timeIntervalSince1970: TimeInterval(sample.timestamp))
            let end = start.addingTimeInterval(60)
            if authorized(stepsType), sample.stepCount > 0 {
                batch.append(HKQuantitySample(
                    type: stepsType,
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(sample.stepCount)),
                    start: start, end: end,
                    metadata: Self.syncMetadata(watchID: sample.watchID,
                                                timestamp: sample.timestamp, kind: "steps")))
            }
            // The watch's per-minute calorie figure is a total-energy estimate
            // (it accrues even at rest), so writing every sample into
            // activeEnergyBurned inflates Apple's Move ring — completing it while
            // idle. Only samples the watch flagged active count as active energy.
            if authorized(caloriesType), sample.isActive && sample.calories > 0 {
                batch.append(HKQuantitySample(
                    type: caloriesType,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(sample.calories)),
                    start: start, end: end,
                    metadata: Self.syncMetadata(watchID: sample.watchID,
                                                timestamp: sample.timestamp, kind: "kcal")))
            }
            if authorized(heartRateType), sample.hasValidHeartRate {
                batch.append(HKQuantitySample(
                    type: heartRateType,
                    quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()),
                                         doubleValue: Double(sample.heartRate)),
                    start: start, end: start,
                    metadata: Self.syncMetadata(watchID: sample.watchID,
                                                timestamp: sample.timestamp, kind: "hr")))
            }
            if batch.count > initialCount { note(sample.timestamp, sample.watchID) }
            if batch.count >= chunkSize {
                let saving = batch
                batch.removeAll(keepingCapacity: true)
                try await store.save(saving)
                savedSampleCount += saving.count
            }
        }

        for sample in snapshot.spo2
        where !alreadyExported(sample.timestamp, watchID: sample.watchID) {
            guard authorized(spo2Type) else { continue }
            guard sample.value > 0, sample.value <= 100 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(sample.timestamp))
            batch.append(HKQuantitySample(
                type: spo2Type,
                quantity: HKQuantity(unit: .percent(), doubleValue: Double(sample.value) / 100.0),
                start: date, end: date,
                metadata: Self.syncMetadata(watchID: sample.watchID,
                                        timestamp: sample.timestamp, kind: "spo2")))
            note(sample.timestamp, sample.watchID)
            if batch.count >= chunkSize {
                let saving = batch
                batch.removeAll(keepingCapacity: true)
                try await store.save(saving)
                savedSampleCount += saving.count
            }
        }

        // Inferred sleep sessions for the last 14 nights. These are derived
        // rather than recorded, so they carry no watch id; key them on the
        // session end and let the sync identifier dedup re-derived sessions
        // (a session can grow as later samples arrive).
        var sleepCovered: [Int] = []
        for session in snapshot.sleepSessions
        where !alreadyExported(session.endTimestamp, watchID: nil) {
            guard authorized(sleepType) else { continue }
            batch.append(HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                start: Date(timeIntervalSince1970: TimeInterval(session.startTimestamp)),
                end: Date(timeIntervalSince1970: TimeInterval(session.endTimestamp)),
                metadata: Self.syncMetadata(watchID: nil,
                                            timestamp: session.startTimestamp, kind: "sleep")))
            sleepCovered.append(session.endTimestamp)
            if batch.count >= chunkSize {
                let saving = batch
                batch.removeAll(keepingCapacity: true)
                try await store.save(saving)
                savedSampleCount += saving.count
            }
        }

        let workouts = authorized(HKWorkoutType.workoutType()) ? snapshot.workouts.filter {
            !alreadyExported($0.endTimestamp, watchID: $0.watchID)
                && $0.endTimestamp > $0.startTimestamp
        } : []

        guard !batch.isEmpty || savedSampleCount > 0 || !workouts.isEmpty else {
            lastExportDate = Date()
            return 0
        }
        if !batch.isEmpty {
            let saving = batch
            batch.removeAll(keepingCapacity: false)
            try await store.save(saving)
            savedSampleCount += saving.count
        }
        for workout in workouts {
            try await store.saveWorkout(workout)
            // Checkpoint each successful workout immediately. If a later
            // builder fails, this one remains repeat-safe on the next run.
            markExported(timestamps: [workout.endTimestamp], watchID: workout.watchID)
        }
        // Only after the writes land — a throw above leaves the ranges
        // untouched so the next run retries instead of skipping.
        for (key, timestamps) in covered {
            markExported(timestamps: timestamps,
                         watchID: key == "legacy" ? nil : UUID(uuidString: key))
        }
        if !sleepCovered.isEmpty {
            markExported(timestamps: sleepCovered, watchID: nil)
        }
        lastExportDate = Date()
        return savedSampleCount + workouts.count
    }

    /// Immutable copy of everything the export reads, taken on the main actor.
    private struct StoreSnapshot {
        var samples: [ActivitySample]
        var spo2: [SpO2Sample]
        var workouts: [WorkoutSummary]
        var sleepSessions: [FitnessStore.SleepSession]
    }

}
