import Foundation
#if canImport(UIKit)
import UIKit
#endif

private actor FitnessMergeGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

/// Local persistence for synced fitness data (JSON in Documents), with the
/// aggregations the charts need. One combined dataset across all watches:
/// every record is tagged with its source watch, and samples are
/// deduplicated by (timestamp, watch) — two watches worn in the same minute
/// both keep their samples.
// Published state is mutated on main and archive I/O state on the serial
// `ioQueue`; closures crossing to that queue never access the published arrays.
final class FitnessStore: ObservableObject, @unchecked Sendable {
    static let shared = FitnessStore(loadAsynchronously: true)

    enum LoadState: Equatable {
        case notLoaded, loading, loaded, blocked, failed
    }
    @Published private(set) var loadState: LoadState = .notLoaded

    @Published private(set) var samples: [ActivitySample] = []
    @Published private(set) var spo2Samples: [SpO2Sample] = []
    @Published private(set) var workouts: [WorkoutSummary] = []
    /// Last sync per watch. UUID-string keys — [UUID: Date] would encode as
    /// a flat array in JSON.
    @Published private(set) var lastSyncByWatch: [String: Date] = [:]

    /// Latest daily counter read directly from each watch's configuration.
    /// Kept per watch so changing the active watch cannot replace the user's
    /// global total with that one device's counter. These values are only a
    /// live-session overlay; the minute samples remain the persisted source.
    struct LiveStepCount: Equatable {
        var count: Int
        var observedAt: Date
    }
    @Published private(set) var liveStepCountsByWatch: [UUID: LiveStepCount] = [:]

    /// Most recent sync across all watches (the Fitness screen label).
    var lastSyncDate: Date? { lastSyncByWatch.values.max() }

    private static let retentionDays = 120
    private static let legacySyncKey = "legacy"

    /// Set when `load()` found an archive it could not decode. While true,
    /// `persist()` refuses to write: overwriting an archive we failed to read
    /// would turn a recoverable read error into permanent data loss.
    private(set) var loadFailed = false
    /// Where the unreadable archive was moved, for the UI to offer/report.
    private(set) var quarantinedArchiveURL: URL?

    /// Set when `load()` found the archive *present but unreadable* — almost
    /// always `.completeFileProtection` denying us the bytes during a
    /// background launch while the device is locked. Unlike `loadFailed`, the
    /// bytes are fine; we just can't see them yet, so the file is **not**
    /// quarantined. While true, `persist()` refuses to write (an empty-store
    /// overwrite would destroy the readable history), and the load is retried
    /// when protected data becomes available.
    private(set) var loadBlocked = false

    private let fileURL: URL

    /// Retained so it can be removed in `deinit`; fires the blocked-load retry
    /// when the device unlocks.
    private var protectedDataObserver: NSObjectProtocol?
    private var initialLoadTask: Task<Void, Never>?

    /// Serial queue for the JSON encode + disk write, so that work never runs
    /// on the main thread (a full-history archive is ~15–25 MB at the retention
    /// steady state, and the sync hot path hit it every few minutes).
    private let ioQueue = DispatchQueue(label: "eu.sixpixels.hybridge.fitness-io", qos: .utility)
    private let mergeGate = FitnessMergeGate()

    private struct Archive: Codable, Sendable {
        /// Bumped when a field stops being decodable by older builds. Absent
        /// in archives written before versioning — treated as version 1.
        var schemaVersion: Int?
        var samples: [ActivitySample]
        var spo2: [SpO2Sample]
        var workouts: [WorkoutSummary]
        var lastSync: Date?                     // pre-multi-watch archives
        var lastSyncByWatch: [String: Date]?
    }

    private static let currentSchemaVersion = 1

    /// Pre-multi-watch single sync date, folded into lastSyncByWatch by the
    /// one-time adoption.
    private var legacyLastSync: Date?

    init(fileURL: URL? = nil, loadAsynchronously: Bool = false) {
        self.fileURL = fileURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("fitness.json")
        if loadAsynchronously {
            loadBlocked = true
            loadState = .loading
            startAsynchronousLoad()
        } else {
            load()
            loadState = loadBlocked ? .blocked : (loadFailed ? .failed : .loaded)
            adoptLegacyDataIfNeeded()
        }
        observeProtectedDataAvailability()
    }

    private struct LoadOutcome: Sendable {
        var archive: Archive?
        var blocked = false
        var failed = false
        var quarantinedURL: URL?
    }

    private static func readArchive(at url: URL) -> LoadOutcome {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return LoadOutcome(archive: nil)
        }
        // A directory (and any other non-file object) at the archive path is
        // present but unreadable data, not a first-run/missing archive. Keep
        // writes blocked so it cannot be replaced with an empty history.
        guard !isDirectory.boolValue else {
            return LoadOutcome(archive: nil, blocked: true)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return LoadOutcome(archive: nil,
                               blocked: manager.fileExists(atPath: url.path),
                               failed: false, quarantinedURL: nil)
        }
        do {
            var archive = try JSONDecoder().decode(Archive.self, from: data)
            if !archive.samples.isSorted(by: \.timestamp) {
                archive.samples.sort { $0.timestamp < $1.timestamp }
            }
            if !archive.spo2.isSorted(by: \.timestamp) {
                archive.spo2.sort { $0.timestamp < $1.timestamp }
            }
            return LoadOutcome(archive: archive)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let target = url.deletingLastPathComponent()
                .appendingPathComponent("fitness.corrupt-\(stamp).json")
            do {
                try manager.moveItem(at: url, to: target)
                return LoadOutcome(archive: nil, blocked: false,
                                   failed: false, quarantinedURL: target)
            } catch {
                return LoadOutcome(archive: nil, blocked: false,
                                   failed: true, quarantinedURL: url)
            }
        }
    }

    private func startAsynchronousLoad() {
        let url = fileURL
        initialLoadTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                Self.readArchive(at: url)
            }.value
            guard let self else { return }
            await MainActor.run {
                if let archive = outcome.archive {
                    self.samples = archive.samples
                    self.spo2Samples = archive.spo2
                    self.workouts = archive.workouts
                    self.lastSyncByWatch = archive.lastSyncByWatch ?? [:]
                    self.legacyLastSync = archive.lastSync
                }
                self.loadBlocked = outcome.blocked
                self.loadFailed = outcome.failed
                self.quarantinedArchiveURL = outcome.quarantinedURL
                self.loadState = outcome.blocked ? .blocked
                    : (outcome.failed ? .failed : .loaded)
                self.daySummaryCache = [:]
                self.adoptLegacyDataIfNeeded()
            }
        }
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
    }

    /// Retry a load blocked by data protection once the device unlocks. The
    /// blocked case only happens on a locked background launch, and this is the
    /// event that clears it — after which persistence is safe again.
    private func observeProtectedDataAvailability() {
        #if canImport(UIKit)
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.retryLoadIfBlocked() }
        }
        #endif
    }

    /// Re-attempt a load that data protection blocked. If the archive is now
    /// readable the history returns and persistence unblocks; if it still isn't,
    /// `load()` re-latches `loadBlocked`. Safe to call repeatedly.
    func retryLoadIfBlocked() async {
        guard loadBlocked else { return }
        loadState = .loading
        startAsynchronousLoad()
        await initialLoadTask?.value
    }

    /// Loads the archive. A *missing* file is the normal first-run case and
    /// leaves the store empty. A file that exists but does not decode is not:
    /// it means months of heart-rate/SpO2/sleep history we can still see on
    /// disk but cannot read. Silently starting empty would let the next
    /// `persist()` overwrite it, so instead the bad file is moved aside and the
    /// store latches into `loadFailed`, which blocks writes.
    private func load() {
        loadBlocked = false
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            loadBlocked = true
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // A *missing* file is the normal first-run case: leave the store
            // empty. A file that *exists* but cannot be read is not — most
            // often it is `.completeFileProtection` denying us the bytes during
            // a background launch while the phone is locked. Starting empty
            // there would let the next `persist()` overwrite months of history
            // (the write path's `…UntilFirstUserAuthentication` fallback still
            // succeeds while locked). Latch `loadBlocked` instead: persistence
            // refuses, and `retryLoadIfBlocked` re-reads once the device
            // unlocks. Do *not* quarantine — the bytes are readable data, not
            // corruption.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                loadBlocked = true
                NSLog("FitnessStore: archive present but unreadable (\(error)); "
                      + "blocking writes until protected data is available")
            }
            return
        }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            samples = archive.samples
            spo2Samples = archive.spo2
            workouts = archive.workouts
            lastSyncByWatch = archive.lastSyncByWatch ?? [:]
            legacyLastSync = archive.lastSync
            // `merge` keeps these sorted, but archives written before that
            // (or hand-edited ones) may not be, and the range lookups below
            // binary-search. Cheap on already-sorted input.
            if !samples.isSorted(by: \.timestamp) {
                samples.sort { $0.timestamp < $1.timestamp }
            }
            if !spo2Samples.isSorted(by: \.timestamp) {
                spo2Samples.sort { $0.timestamp < $1.timestamp }
            }
        } catch {
            loadFailed = true
            quarantineCorruptArchive(error)
        }
    }

    /// Moves an undecodable archive to `fitness.corrupt-<timestamp>.json` so
    /// it survives for recovery instead of being overwritten.
    private func quarantineCorruptArchive(_ error: Error) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("fitness.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            quarantinedArchiveURL = target
            // The archive is gone from its usual path now, so writes are safe
            // again — a fresh one starts here rather than clobbering history.
            loadFailed = false
        } catch {
            // Could not move it: keep refusing to write so the bytes stay put.
            quarantinedArchiveURL = fileURL
        }
        NSLog("FitnessStore: archive at \(fileURL.lastPathComponent) did not decode (\(error)); "
              + "moved to \(quarantinedArchiveURL?.lastPathComponent ?? "nowhere")")
    }

    /// True when the last `persist()` did not reach disk. Callers about to
    /// destroy the only other copy of the data — `syncActivity`, which deletes
    /// the activity file off the watch after merging — check the `persisted`
    /// result of `merge` (backed by this) and hold off.
    private(set) var lastSaveFailed = false

    /// Monotonic snapshot revision, bumped on the main actor at the instant a
    /// snapshot is taken — so revision order is exactly state-mutation order.
    /// Main-actor only.
    private var persistRevision = 0
    /// Highest revision already written to disk. Touched only inside the serial
    /// `ioQueue`, so it needs no other synchronization.
    private var lastWrittenRevision = 0

    /// The archive value for the current in-memory state. Cheap (arrays are
    /// copy-on-write references); the expensive encode happens in `writeArchive`.
    private func currentArchive() -> Archive {
        Archive(schemaVersion: Self.currentSchemaVersion,
                samples: samples, spo2: spo2Samples, workouts: workouts,
                lastSync: legacyLastSync, lastSyncByWatch: lastSyncByWatch)
    }

    /// Encodes and writes `archive` to `url`. Pure and thread-agnostic, so the
    /// ~20 MB encode can run off the main thread. Returns whether the bytes
    /// reached disk.
    ///
    /// Health data (heart rate, SpO2, inferred sleep), so prefer
    /// `.completeFileProtection` — encrypted whenever the device is locked. But
    /// that class also makes the file *unwritable* while locked, and background
    /// syncs run exactly then (BLE restoration wakes us with the phone in a
    /// pocket); the watch's copy is deleted right after a merge, so this archive
    /// is the only copy. Fall back to the weaker class rather than drop data.
    private static func writeArchive(_ archive: Archive, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(archive) else { return false }
        let attempts: [Data.WritingOptions] = [[.atomic, .completeFileProtection],
                                               [.atomic, .completeFileProtectionUntilFirstUserAuthentication]]
        for options in attempts {
            do {
                try data.write(to: url, options: options)
                var excluded = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? excluded.setResourceValues(values)
                return true
            } catch {
                NSLog("FitnessStore: write failed (\(options)): \(error)")
            }
        }
        return false
    }

    /// The single persistence path: snapshots the archive on the main actor
    /// (cheap COW), then encodes + writes on `ioQueue`, so the big JSON encode
    /// never runs on main. Every mutating method calls this; `syncActivity`
    /// awaits it before deleting the watch's only copy of the data.
    ///
    /// Snapshot and its `revision` are taken together on the main actor, so
    /// revision order equals state-mutation order and a higher revision always
    /// reflects a *superset* of a lower one. Between the snapshot and the
    /// `ioQueue.async` there is an `await`, so two concurrent callers can reach
    /// the enqueue out of snapshot order (e.g. a launch-time `adoptLegacyData`
    /// racing a first sync's `merge`, which don't share the BLE session gate).
    /// The serial `ioQueue` therefore drops any write already superseded on
    /// disk — otherwise a stale snapshot could clobber a newer one, and a sync
    /// that saw `persisted == true` would already have deleted the watch's copy.
    @discardableResult
    func persist() async -> Bool {
        let prepared: (archive: Archive, revision: Int)? = await MainActor.run {
            guard !self.loadFailed, !self.loadBlocked else {
                NSLog("FitnessStore: refusing to save over an archive that "
                      + (self.loadBlocked ? "is present but unreadable" : "failed to load"))
                self.lastSaveFailed = true
                return nil
            }
            self.persistRevision += 1
            return (self.currentArchive(), self.persistRevision)
        }
        guard let prepared else { return false }
        let url = fileURL
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ioQueue.async {
                // A newer snapshot already landed: its state includes this one,
                // so the data is durable and skipping the stale write is a
                // success — never overwrite newer bytes with older.
                if prepared.revision <= self.lastWrittenRevision {
                    continuation.resume(returning: true)
                    return
                }
                let ok = Self.writeArchive(prepared.archive, to: url)
                if ok { self.lastWrittenRevision = prepared.revision }
                continuation.resume(returning: ok)
            }
        }
        await MainActor.run { self.lastSaveFailed = !ok }
        return ok
    }

    /// Explicitly removes the phone's complete local fitness history. The
    /// revision barrier ensures a stale persist that took its snapshot before
    /// this deletion cannot recreate the archive after the delete lands.
    @discardableResult
    func deleteAllHistory() async -> Bool {
        let deletionRevision = await MainActor.run { () -> Int in
            self.samples = []
            self.spo2Samples = []
            self.workouts = []
            self.lastSyncByWatch = [:]
            self.liveStepCountsByWatch = [:]
            self.legacyLastSync = nil
            self.daySummaryCache = [:]
            self.loadFailed = false
            self.loadBlocked = false
            self.quarantinedArchiveURL = nil
            self.persistRevision += 1
            return self.persistRevision
        }
        let url = fileURL
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ioQueue.async {
                var succeeded = true
                let manager = FileManager.default
                let directory = url.deletingLastPathComponent()
                let candidates = (try? manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
                for candidate in candidates where candidate == url
                    || candidate.lastPathComponent.hasPrefix("fitness.corrupt-") {
                    do {
                        try manager.removeItem(at: candidate)
                    } catch let error as CocoaError where error.code == .fileNoSuchFile {
                        continue
                    } catch {
                        succeeded = false
                        NSLog("FitnessStore: explicit history deletion failed for \(candidate.lastPathComponent): \(error)")
                    }
                }
                // Any older snapshot enqueued after this block is stale and
                // will be skipped by persist's revision check.
                self.lastWrittenRevision = max(self.lastWrittenRevision, deletionRevision)
                continuation.resume(returning: succeeded)
            }
        }
        await MainActor.run { self.lastSaveFailed = !ok }
        return ok
    }

    /// The multi-watch migration stashes the first watch's id so the
    /// pre-migration archive can be tagged on the next load. Runs the adoption
    /// off the init path (persistence is async); the UserDefaults key is only
    /// cleared once the tagged archive is on disk, so an interrupted migration
    /// simply retries on the next launch.
    private func adoptLegacyDataIfNeeded() {
        let key = AppMigrations.fitnessLegacyOwnerKey
        guard let idString = UserDefaults.standard.string(forKey: key) else { return }
        guard let id = UUID(uuidString: idString) else {
            UserDefaults.standard.removeObject(forKey: key)   // unusable value, drop it
            return
        }
        Task { @MainActor in
            if await self.adoptLegacyData(watchID: id) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Tags every untagged record with `watchID`, folds the single legacy sync
    /// date into the per-watch dictionary, and persists.
    @discardableResult
    func adoptLegacyData(watchID: UUID) async -> Bool {
        await MainActor.run { self.applyLegacyAdoption(watchID: watchID) }
        return await persist()
    }

    /// The in-memory half of `adoptLegacyData`. Must run on main (mutates
    /// `@Published` state).
    private func applyLegacyAdoption(watchID: UUID) {
        for index in samples.indices where samples[index].watchID == nil {
            samples[index].watchID = watchID
        }
        for index in spo2Samples.indices where spo2Samples[index].watchID == nil {
            spo2Samples[index].watchID = watchID
        }
        for index in workouts.indices where workouts[index].watchID == nil {
            workouts[index].watchID = watchID
        }
        if let legacy = legacyLastSync {
            if lastSyncByWatch[watchID.uuidString] == nil {
                lastSyncByWatch[watchID.uuidString] = legacy
            }
            legacyLastSync = nil
        }
        daySummaryCache = [:]
    }

    func lastSync(for watchID: UUID?) -> Date? {
        lastSyncByWatch[Self.syncKey(watchID)]
    }

    func setLastSync(_ date: Date, for watchID: UUID?) async {
        if let initialLoadTask { await initialLoadTask.value }
        guard !loadBlocked, !loadFailed else { return }
        await MainActor.run { self.lastSyncByWatch[Self.syncKey(watchID)] = date }
        _ = await persist()
    }

    private static func syncKey(_ watchID: UUID?) -> String {
        watchID?.uuidString ?? legacySyncKey
    }

    private static func dedupKey(_ timestamp: Int, _ watchID: UUID?) -> String {
        "\(timestamp)-\(watchID?.uuidString ?? legacySyncKey)"
    }

    /// Merge data newly synced from `watchID`: applies the incoming records on
    /// the main actor, then persists off it (the encode/write is the costly
    /// part). Returns the new minute-sample count and whether the write reached
    /// disk — `syncActivity` keys the on-watch delete off the latter.
    @discardableResult
    func merge(samples newSamples: [ActivitySample],
               spo2 newSpo2: [SpO2Sample],
               workouts newWorkouts: [WorkoutSummary],
               from watchID: UUID? = nil) async -> (count: Int, persisted: Bool) {
        if let initialLoadTask { await initialLoadTask.value }
        guard !loadBlocked, !loadFailed else {
            await MainActor.run { self.lastSaveFailed = true }
            return (0, false)
        }
        await mergeGate.acquire()
        let existing = await MainActor.run {
            (self.samples, self.spo2Samples, self.workouts, self.lastSyncByWatch)
        }
        let result = await Task.detached(priority: .utility) {
            Self.computeMerge(existingSamples: existing.0, existingSpo2: existing.1,
                              existingWorkouts: existing.2,
                              incomingSamples: newSamples, incomingSpo2: newSpo2,
                              incomingWorkouts: newWorkouts, watchID: watchID)
        }.value
        await MainActor.run {
            self.samples = result.samples
            self.spo2Samples = result.spo2
            self.workouts = result.workouts
            self.lastSyncByWatch[Self.syncKey(watchID)] = Date()
            self.daySummaryCache = [:]
        }
        let persisted = await persist()
        await mergeGate.release()
        return (result.freshCount, persisted)
    }

    private struct MergeResult: Sendable {
        var samples: [ActivitySample]
        var spo2: [SpO2Sample]
        var workouts: [WorkoutSummary]
        var freshCount: Int
    }

    private static func computeMerge(
        existingSamples: [ActivitySample], existingSpo2: [SpO2Sample],
        existingWorkouts: [WorkoutSummary], incomingSamples: [ActivitySample],
        incomingSpo2: [SpO2Sample], incomingWorkouts: [WorkoutSummary],
        watchID: UUID?
    ) -> MergeResult {
        var samplesToAdd = incomingSamples
        for index in samplesToAdd.indices { samplesToAdd[index].watchID = watchID }
        let knownSamples = Set(existingSamples.lazy
            .filter { $0.watchID == watchID }.map(\.timestamp))
        var seenSamples = Set<Int>()
        samplesToAdd = samplesToAdd
            .filter { !knownSamples.contains($0.timestamp) && seenSamples.insert($0.timestamp).inserted }
            .sorted { $0.timestamp < $1.timestamp }

        var spo2ToAdd = incomingSpo2
        for index in spo2ToAdd.indices { spo2ToAdd[index].watchID = watchID }
        let knownSpo2 = Set(existingSpo2.lazy
            .filter { $0.watchID == watchID }.map(\.timestamp))
        var seenSpo2 = Set<Int>()
        spo2ToAdd = spo2ToAdd
            .filter { !knownSpo2.contains($0.timestamp) && seenSpo2.insert($0.timestamp).inserted }
            .sorted { $0.timestamp < $1.timestamp }

        func merged<T>(_ lhs: [T], _ rhs: [T], by key: (T) -> Int) -> [T] {
            var output: [T] = []
            output.reserveCapacity(lhs.count + rhs.count)
            var left = 0, right = 0
            while left < lhs.count && right < rhs.count {
                if key(lhs[left]) <= key(rhs[right]) {
                    output.append(lhs[left]); left += 1
                } else {
                    output.append(rhs[right]); right += 1
                }
            }
            output.append(contentsOf: lhs[left...])
            output.append(contentsOf: rhs[right...])
            return output
        }

        let cutoff = Int(Date().timeIntervalSince1970) - retentionDays * 86400
        let allSamples = merged(existingSamples, samplesToAdd, by: \.timestamp)
            .drop(while: { $0.timestamp < cutoff })
        let allSpo2 = merged(existingSpo2, spo2ToAdd, by: \.timestamp)
            .drop(while: { $0.timestamp < cutoff })

        var workoutsToAdd = incomingWorkouts
        for index in workoutsToAdd.indices { workoutsToAdd[index].watchID = watchID }
        func workoutKey(_ workout: WorkoutSummary) -> String {
            "\(workout.startTimestamp)-\(workout.endTimestamp)-\(workout.watchID?.uuidString ?? legacySyncKey)"
        }
        let knownWorkouts = Set(existingWorkouts.map(workoutKey))
        workoutsToAdd.removeAll { knownWorkouts.contains(workoutKey($0)) }
        let allWorkouts = merged(existingWorkouts, workoutsToAdd.sorted {
            $0.startTimestamp < $1.startTimestamp
        }, by: \.startTimestamp)

        return MergeResult(samples: Array(allSamples), spo2: Array(allSpo2),
                           workouts: allWorkouts, freshCount: samplesToAdd.count)
    }

    /// The in-memory mutation, split out so `merge` can run it on the main
    /// actor without also doing the write. Must run on main (mutates
    /// `@Published` state).
    @discardableResult
    private func applyMerge(samples newSamples: [ActivitySample],
                            spo2 newSpo2: [SpO2Sample],
                            workouts newWorkouts: [WorkoutSummary],
                            from watchID: UUID?) -> Int {
        // Dedup is by (timestamp, watch), and every incoming record carries
        // this one `watchID` — so it's enough to compare timestamps against
        // the existing records *from the same watch*. A `Set<Int>` of those
        // timestamps replaces the old `Set<String>` of "ts-uuid" keys, which
        // allocated a string per sample on both sides (~344k allocations at
        // the 172k-sample steady state, on the main thread, every 5 minutes).
        var incoming = newSamples
        for index in incoming.indices { incoming[index].watchID = watchID }
        let known = Set(samples.lazy.filter { $0.watchID == watchID }.map(\.timestamp))
        let fresh = incoming.filter { !known.contains($0.timestamp) }
        samples.append(contentsOf: fresh)
        samples.sort { $0.timestamp < $1.timestamp }

        var incomingSpo2 = newSpo2
        for index in incomingSpo2.indices { incomingSpo2[index].watchID = watchID }
        let knownSpo2 = Set(spo2Samples.lazy.filter { $0.watchID == watchID }.map(\.timestamp))
        spo2Samples.append(contentsOf: incomingSpo2.filter { !knownSpo2.contains($0.timestamp) })
        spo2Samples.sort { $0.timestamp < $1.timestamp }

        var incomingWorkouts = newWorkouts
        for index in incomingWorkouts.indices { incomingWorkouts[index].watchID = watchID }
        func workoutKey(_ workout: WorkoutSummary) -> String {
            "\(workout.startTimestamp)-\(Self.dedupKey(workout.endTimestamp, workout.watchID))"
        }
        let knownWorkouts = Set(workouts.map(workoutKey))
        workouts.append(contentsOf: incomingWorkouts.filter { !knownWorkouts.contains(workoutKey($0)) })
        workouts.sort { $0.startTimestamp < $1.startTimestamp }

        // Retention trim
        let cutoff = Int(Date().timeIntervalSince1970) - Self.retentionDays * 86400
        samples.removeAll { $0.timestamp < cutoff }
        spo2Samples.removeAll { $0.timestamp < cutoff }

        lastSyncByWatch[Self.syncKey(watchID)] = Date()
        daySummaryCache = [:]
        return fresh.count
    }

    // MARK: Aggregations

    /// Per-day rollups, keyed by start-of-day timestamp. At steady state the
    /// store holds ~172k samples (120 days × 1440 minutes) and the charts ask
    /// for a month at a time; without this, `dailySummaries(days: 30)` alone
    /// ran 120 full scans of the array, on the main thread, on every SwiftUI
    /// body evaluation. Dropped wholesale whenever the samples change.
    private var daySummaryCache: [Int: DaySummary] = [:]

    /// Index of the first sample at or after `timestamp`. `samples` is kept
    /// sorted ascending (on merge and after load), so day ranges are a binary
    /// search rather than a full scan.
    private func lowerBound(_ timestamp: Int) -> Int {
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].timestamp < timestamp { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Half-open sample range `[from, to)` as indices into `samples`.
    private func range(from: Int, to: Int) -> Range<Int> {
        let low = lowerBound(from)
        let high = lowerBound(to)
        return low..<max(low, high)
    }

    func samples(onDay day: Date, calendar: Calendar = .current) -> [ActivitySample] {
        let startDate = calendar.startOfDay(for: day)
        let endDate = calendar.date(byAdding: .day, value: 1, to: startDate)
            ?? startDate.addingTimeInterval(86400)
        let start = Int(startDate.timeIntervalSince1970)
        let end = Int(endDate.timeIntervalSince1970)
        return Array(samples[range(from: start, to: end)])
    }

    /// The cached rollup for a day, computing it in a single pass if needed.
    private func summary(onDay day: Date, calendar: Calendar = .current) -> DaySummary {
        let startOfDay = calendar.startOfDay(for: day)
        let start = Int(startOfDay.timeIntervalSince1970)
        if let cached = daySummaryCache[start] { return cached }

        let endDate = calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86400)
        let indices = range(from: start, to: Int(endDate.timeIntervalSince1970))
        var steps = 0
        var calories = 0
        var activeMinutes = 0
        var restingCandidates: [Int] = []
        for index in indices {
            let sample = samples[index]
            steps += sample.stepCount
            calories += sample.calories
            if sample.isActive { activeMinutes += 1 }
            if sample.hasValidHeartRate && !sample.isActive {
                restingCandidates.append(sample.heartRate)
            }
        }
        // Resting HR: 5th percentile of inactive valid readings — robust
        // against both missing data and daytime spikes.
        var restingHR: Int?
        if restingCandidates.count >= 10 {
            restingCandidates.sort()
            restingHR = restingCandidates[restingCandidates.count / 20]
        }
        let summary = DaySummary(day: startOfDay, steps: steps, calories: calories,
                                 activeMinutes: activeMinutes, restingHR: restingHR)
        daySummaryCache[start] = summary
        return summary
    }

    func steps(onDay day: Date) -> Int {
        summary(onDay: day).steps
    }

    /// Global step total across every watch, topped up with the latest daily
    /// counter observed from each device. A watch's counter includes steps
    /// already present in its synced minute samples, so only the positive
    /// difference is added; summing the two directly would double-count.
    func stepsIncludingLive(onDay day: Date, calendar: Calendar = .current) -> Int {
        let start = Int(calendar.startOfDay(for: day).timeIntervalSince1970)
        let endDate = calendar.date(byAdding: .day, value: 1,
                                    to: calendar.startOfDay(for: day))
            ?? Date(timeIntervalSince1970: TimeInterval(start + 86400))
        let end = Int(endDate.timeIntervalSince1970)

        var syncedByWatch: [UUID: Int] = [:]
        for index in range(from: start, to: end) {
            let sample = samples[index]
            if let watchID = sample.watchID {
                syncedByWatch[watchID, default: 0] += sample.stepCount
            }
        }

        var total = summary(onDay: day, calendar: calendar).steps
        for (watchID, live) in liveStepCountsByWatch
        where calendar.isDate(live.observedAt, inSameDayAs: day) {
            total += max(0, live.count - syncedByWatch[watchID, default: 0])
        }
        return total
    }

    func recordLiveStepCount(_ count: Int, for watchID: UUID, at date: Date = Date()) {
        liveStepCountsByWatch[watchID] = LiveStepCount(count: max(0, count), observedAt: date)
    }

    func hasLiveStepCount(onDay day: Date, calendar: Calendar = .current) -> Bool {
        liveStepCountsByWatch.values.contains {
            calendar.isDate($0.observedAt, inSameDayAs: day)
        }
    }

    /// Actual observation time behind the current step display. This never
    /// advances because an unrelated setting or widget flush occurred.
    var latestStepObservationDate: Date? {
        let live = liveStepCountsByWatch.values.map(\.observedAt).max()
        let synced = samples.last.map {
            Date(timeIntervalSince1970: TimeInterval($0.timestamp))
        }
        return [live, synced].compactMap { $0 }.max()
    }

    func calories(onDay day: Date) -> Int {
        summary(onDay: day).calories
    }

    func activeMinutes(onDay day: Date) -> Int {
        summary(onDay: day).activeMinutes
    }

    /// Steps summed per hour (0–23) for a day.
    func stepsPerHour(onDay day: Date, calendar: Calendar = .current) -> [(hour: Int, steps: Int)] {
        let daySamples = samples(onDay: day)
        var buckets = [Int](repeating: 0, count: 24)
        for sample in daySamples {
            let date = Date(timeIntervalSince1970: TimeInterval(sample.timestamp))
            let hour = min(max(calendar.component(.hour, from: date), 0), 23)
            buckets[hour] += sample.stepCount
        }
        return buckets.enumerated().map { (hour: $0.offset, steps: $0.element) }
    }

    /// Sums the native one-minute samples into contiguous clock-aligned
    /// buckets. The chart chooses `minutes` from its visible duration so it
    /// keeps roughly the same number of bars at every zoom level.
    func steps(inBucketsOf minutes: Int, from start: Date, to end: Date,
               calendar: Calendar = .current) -> [(start: Date, end: Date, steps: Int)] {
        let bucketSeconds = max(minutes, 1) * 60
        let dayStart = calendar.startOfDay(for: start)
        let elapsed = max(Int(start.timeIntervalSince(dayStart)), 0)
        let firstBucket = dayStart.addingTimeInterval(
            TimeInterval((elapsed / bucketSeconds) * bucketSeconds)
        )
        let baseTS = Int(firstBucket.timeIntervalSince1970)
        let bucketCount = max(Int(ceil(end.timeIntervalSince(firstBucket)
                                      / TimeInterval(bucketSeconds))), 0)
        let startTS = Int(start.timeIntervalSince1970)
        let endTS = Int(end.timeIntervalSince1970)
        var buckets = [Int](repeating: 0, count: bucketCount)
        for index in range(from: startTS, to: endTS) {
            let sample = samples[index]
            let idx = (sample.timestamp - baseTS) / bucketSeconds
            if idx >= 0 && idx < buckets.count { buckets[idx] += sample.stepCount }
        }
        return buckets.enumerated().map {
            let bucketStart = Date(timeIntervalSince1970:
                TimeInterval(baseTS + $0.offset * bucketSeconds))
            return (start: bucketStart,
                    end: bucketStart.addingTimeInterval(TimeInterval(bucketSeconds)),
                    steps: $0.element)
        }
    }

    func heartRateSeries(onDay day: Date) -> [(date: Date, bpm: Int)] {
        samples(onDay: day)
            .filter(\.hasValidHeartRate)
            .map { (Date(timeIntervalSince1970: TimeInterval($0.timestamp)), $0.heartRate) }
    }

    /// Heart-rate samples in a rolling window, e.g. the last 24h ending now
    /// (as opposed to `heartRateSeries(onDay:)`'s midnight-to-midnight day).
    func heartRateSeries(from start: Date, to end: Date) -> [(date: Date, bpm: Int)] {
        let startTS = Int(start.timeIntervalSince1970)
        let endTS = Int(end.timeIntervalSince1970)
        return samples[range(from: startTS, to: endTS)]
            .filter(\.hasValidHeartRate)
            .map { (Date(timeIntervalSince1970: TimeInterval($0.timestamp)), $0.heartRate) }
    }

    var latestHeartRate: (date: Date, bpm: Int)? {
        guard let sample = samples.last(where: { $0.hasValidHeartRate }) else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(sample.timestamp)), sample.heartRate)
    }

    // MARK: Sleep inference

    /// The watch records no explicit sleep state : a minute counts as "still" when worn, inactive, without steps
    /// and with low movement variability. Still stretches ≥ 45 min (gaps up
    /// to 20 min tolerated) become sleep sessions.
    struct SleepSession: Equatable, Identifiable {
        var startTimestamp: Int
        var endTimestamp: Int
        var id: Int { startTimestamp }
        var duration: Int { endTimestamp - startTimestamp }
    }

    private static let sleepVariabilityThreshold = 128
    private static let sleepMaxGapSeconds = 20 * 60
    private static let sleepMinSessionSeconds = 45 * 60

    /// Sleep sessions for the night ending on the morning of `day`
    /// (window: noon the day before → noon of `day`).
    func sleepSessions(nightEnding day: Date, calendar: Calendar = .current) -> [SleepSession] {
        let dayStart = calendar.startOfDay(for: day)
        let noonDate = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart)
            ?? dayStart.addingTimeInterval(12 * 3600)
        let windowStartDate = calendar.date(byAdding: .day, value: -1, to: noonDate)
            ?? noonDate.addingTimeInterval(-86400)
        let noon = Int(noonDate.timeIntervalSince1970)
        let windowStart = Int(windowStartDate.timeIntervalSince1970)
        let window = samples[range(from: windowStart, to: noon)]

        var sessions: [SleepSession] = []
        var current: SleepSession?
        for sample in window {
            let still = sample.wearingState == 0
                && !sample.isActive
                && sample.stepCount == 0
                && sample.variability < Self.sleepVariabilityThreshold
            if still {
                if var session = current, sample.timestamp - session.endTimestamp <= Self.sleepMaxGapSeconds {
                    session.endTimestamp = sample.timestamp + 60
                    current = session
                } else {
                    if let session = current, session.duration >= Self.sleepMinSessionSeconds {
                        sessions.append(session)
                    }
                    current = SleepSession(startTimestamp: sample.timestamp,
                                           endTimestamp: sample.timestamp + 60)
                }
            }
        }
        if let session = current, session.duration >= Self.sleepMinSessionSeconds {
            sessions.append(session)
        }
        return sessions
    }

    func sleepDuration(nightEnding day: Date) -> Int {
        sleepSessions(nightEnding: day).reduce(0) { $0 + $1.duration }
    }

    /// Minute-resolution restfulness within a session: a minute is "deep"
    /// when its movement variability is in the calmest third of the session.
    /// Heuristic on top of a heuristic — labelled as such in the UI.
    func sleepPhases(for session: SleepSession) -> [(date: Date, isDeep: Bool)] {
        let minutes = samples[range(from: session.startTimestamp, to: session.endTimestamp)]
        guard !minutes.isEmpty else { return [] }
        let sorted = minutes.map(\.variability).sorted()
        let threshold = sorted[sorted.count / 3]
        return minutes.map {
            (Date(timeIntervalSince1970: TimeInterval($0.timestamp)), $0.variability <= threshold)
        }
    }

    // MARK: Wellness aggregations

    /// Resting heart rate: the 5th percentile of valid readings while
    /// inactive — robust against both missing data and daytime spikes.
    func restingHeartRate(onDay day: Date) -> Int? {
        summary(onDay: day).restingHR
    }

    struct DaySummary: Identifiable {
        var day: Date
        var steps: Int
        var calories: Int
        var activeMinutes: Int
        var restingHR: Int?
        var id: Date { day }
    }

    /// One row per day for the trailing `days` (oldest first). Days without
    /// any samples are included with zeros so charts keep their time axis.
    func dailySummaries(days: Int, endingOn end: Date = Date(),
                        calendar: Calendar = .current) -> [DaySummary] {
        (0..<days).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: end) else { return nil }
            return summary(onDay: day, calendar: calendar)
        }
    }

    /// Consecutive days meeting the step goal, counting back from yesterday.
    /// Today is added on top once it's met, so an in-progress day doesn't
    /// break the streak.
    func stepGoalStreak(goal: Int, calendar: Calendar = .current) -> Int {
        guard goal > 0 else { return 0 }
        var streak = steps(onDay: Date()) >= goal ? 1 : 0
        var back = 1
        while let previous = calendar.date(byAdding: .day, value: -back, to: Date()),
              steps(onDay: previous) >= goal {
            streak += 1
            back += 1
        }
        return streak
    }
}
