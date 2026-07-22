import XCTest
@testable import Hybridge

/// Covers the archive-durability contract and the indexed aggregations that
/// replaced the full-array scans. Both were previously untested.
final class FitnessStoreDurabilityTests: XCTestCase {
    private var fileURL: URL!
    private let watch = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fitness-durability-\(UUID().uuidString).json")
        UserDefaults.standard.removeObject(forKey: AppMigrations.fitnessLegacyOwnerKey)
    }

    override func tearDown() {
        let directory = fileURL.deletingLastPathComponent()
        for url in (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)) ?? [] {
            if url.lastPathComponent.hasPrefix("fitness-durability")
                || url.lastPathComponent.hasPrefix("fitness.corrupt-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        super.tearDown()
    }

    private func sample(_ timestamp: Int, steps: Int = 10, calories: Int = 2,
                        heartRate: Int = 70, active: Bool = false) -> ActivitySample {
        ActivitySample(timestamp: timestamp, stepCount: steps, calories: calories,
                       heartRate: heartRate, variability: 10, maxVariability: 20,
                       heartRateQuality: 3, isActive: active, wearingState: 0)
    }

    // MARK: - Corrupt-archive handling

    func testCorruptArchiveIsQuarantinedNotOverwritten() throws {
        try Data("{ this is not valid json".utf8).write(to: fileURL)

        let store = FitnessStore(fileURL: fileURL)
        XCTAssertTrue(store.samples.isEmpty)

        let quarantined = try XCTUnwrap(store.quarantinedArchiveURL,
                                        "an undecodable archive must be moved aside, not ignored")
        XCTAssertTrue(quarantined.lastPathComponent.hasPrefix("fitness.corrupt-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path),
                      "the original bytes must survive for recovery")
        XCTAssertEqual(try Data(contentsOf: quarantined), Data("{ this is not valid json".utf8))
    }

    func testStoreIsUsableAfterQuarantine() async throws {
        try Data("garbage".utf8).write(to: fileURL)
        let store = FitnessStore(fileURL: fileURL)

        // Quarantine moved the bad file out of the way, so writing is safe.
        // Must be inside the retention window or the merge trims it again.
        await store.merge(samples: [sample(Int(Date().timeIntervalSince1970) - 3600)],
                          spo2: [], workouts: [], from: watch)
        let reloaded = FitnessStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.samples.count, 1)
        XCTAssertNil(reloaded.quarantinedArchiveURL)
    }

    func testMissingArchiveIsNotTreatedAsCorruption() {
        let store = FitnessStore(fileURL: fileURL)
        XCTAssertNil(store.quarantinedArchiveURL, "first run is not a corruption case")
        XCTAssertFalse(store.loadFailed)
    }

    // MARK: - Unreadable-archive handling (data protection while locked)

    /// A directory at the archive path stands in for the real case:
    /// `Data(contentsOf:)` throws while `fileExists` is true, exactly like
    /// `.completeFileProtection` denying the bytes during a locked background
    /// launch — which the simulator can't reproduce with real data protection.
    func testUnreadableArchiveBlocksWritesAndIsNotOverwritten() async throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        let store = FitnessStore(fileURL: fileURL)
        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertTrue(store.loadBlocked, "a present-but-unreadable archive must block writes")
        XCTAssertNil(store.quarantinedArchiveURL,
                     "an unreadable (not undecodable) archive must not be quarantined")

        // A merge must not report success, or `syncActivity` would delete the
        // watch's only copy after failing to persist over the unreadable file.
        let (_, persisted) = await store.merge(
            samples: [sample(Int(Date().timeIntervalSince1970) - 600)],
            spo2: [], workouts: [], from: watch)
        XCTAssertFalse(persisted, "writing over an unreadable archive would lose history")
        XCTAssertTrue(store.lastSaveFailed)

        // The original path is untouched — the store did not replace what it
        // could not read.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "the store must not overwrite an archive it couldn't read")
    }

    func testBlockedLoadRecoversWhenArchiveBecomesReadable() async throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let store = FitnessStore(fileURL: fileURL)
        XCTAssertTrue(store.loadBlocked)

        // The device unlocks and the real archive is now readable.
        try FileManager.default.removeItem(at: fileURL)
        struct Archive: Codable {
            var samples: [ActivitySample]; var spo2: [SpO2Sample]; var workouts: [WorkoutSummary]
        }
        let ts = Int(Date().timeIntervalSince1970) - 600
        try JSONEncoder().encode(Archive(samples: [sample(ts)], spo2: [], workouts: []))
            .write(to: fileURL)

        store.retryLoadIfBlocked()
        XCTAssertFalse(store.loadBlocked)
        XCTAssertEqual(store.samples.count, 1, "history must return once the archive is readable")

        // Persistence is unblocked again, and preserves the recovered history.
        let (_, persisted) = await store.merge(samples: [sample(ts + 60)], spo2: [], workouts: [], from: watch)
        XCTAssertTrue(persisted)
        let reloaded = FitnessStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.samples.count, 2, "recovered + merged samples must both persist")
    }

    // MARK: - Persistence reporting (gates deleting the watch's only copy)

    func testSuccessfulSaveIsReported() async {
        let store = FitnessStore(fileURL: fileURL)
        let (_, persisted) = await store.merge(samples: [sample(Int(Date().timeIntervalSince1970) - 600)],
                                               spo2: [], workouts: [], from: watch)
        XCTAssertTrue(persisted, "syncActivity keys the on-watch delete off this")
        XCTAssertFalse(store.lastSaveFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUnwritableLocationIsReportedAsFailure() async {
        // A path that cannot be written (directory does not exist) stands in
        // for the real cases: locked device during a background sync, full
        // disk. The store must admit the failure rather than report success,
        // because the caller deletes the watch's copy on success.
        let unwritable = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/fitness.json")
        let store = FitnessStore(fileURL: unwritable)
        let (_, persisted) = await store.merge(samples: [sample(Int(Date().timeIntervalSince1970) - 600)],
                                               spo2: [], workouts: [], from: watch)
        XCTAssertFalse(persisted, "a failed write must not be reported as persisted")
        XCTAssertTrue(store.lastSaveFailed)
        // The merge still applied in memory — the data is not lost, it just
        // isn't durable yet, which is why the watch's copy must be kept.
        XCTAssertEqual(store.samples.count, 1)
    }

    // MARK: - Concurrent persists must not lose data to a stale write

    /// Many merges started concurrently (mirroring a launch-time
    /// `adoptLegacyData` racing a first sync — they don't share the BLE session
    /// gate) each snapshot a growing superset. The newest snapshot on disk must
    /// win: a stale snapshot enqueued out of order must never overwrite it, or a
    /// sync that saw `persisted == true` would have deleted the watch's copy of
    /// data that is no longer on disk.
    func testConcurrentMergesDoNotLoseDataToStaleWrite() async throws {
        let store = FitnessStore(fileURL: fileURL)
        let base = Int(Date().timeIntervalSince1970) - 3600
        let count = 60

        await withTaskGroup(of: Void.self) { group in
            for offset in 0..<count {
                group.addTask {
                    await store.merge(samples: [self.sample(base + offset)],
                                      spo2: [], workouts: [], from: self.watch)
                }
            }
        }

        XCTAssertEqual(store.samples.count, count, "in-memory merge dropped samples")
        // The file must hold every sample — the highest-revision snapshot is a
        // superset of all others, and the revision guard forbids an older write
        // landing after it.
        let reloaded = FitnessStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.samples.count, count,
                       "a stale concurrent write overwrote newer persisted data")
    }

    // MARK: - Indexed aggregations match the previous full-scan semantics

    /// Reference implementation: what the aggregations did before the binary
    /// search. Any divergence is a regression.
    private func referenceSamples(_ all: [ActivitySample], onDay day: Date,
                                  calendar: Calendar = .current) -> [ActivitySample] {
        let start = Int(calendar.startOfDay(for: day).timeIntervalSince1970)
        let end = start + 86400
        return all.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    func testDayRangeMatchesFullScan() async {
        let store = FitnessStore(fileURL: fileURL)
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        // Three days of sparse samples, including exact boundary minutes.
        var input: [ActivitySample] = []
        for dayOffset in -2...0 {
            let base = midnight + dayOffset * 86400
            for minute in stride(from: 0, to: 1440, by: 97) {
                input.append(sample(base + minute * 60, steps: minute))
            }
            input.append(sample(base, steps: 1))                  // first second of the day
            input.append(sample(base + 86399, steps: 2))          // last second of the day
        }
        await store.merge(samples: input.shuffled(), spo2: [], workouts: [], from: watch)

        for dayOffset in -2...0 {
            let day = Date(timeIntervalSince1970: TimeInterval(midnight + dayOffset * 86400 + 3600))
            let expected = referenceSamples(store.samples, onDay: day).map(\.timestamp).sorted()
            let actual = store.samples(onDay: day).map(\.timestamp).sorted()
            XCTAssertEqual(actual, expected, "day \(dayOffset) range diverged from a full scan")
        }
    }

    func testEmptyDayReturnsNothing() async {
        let store = FitnessStore(fileURL: fileURL)
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        await store.merge(samples: [sample(midnight + 100)], spo2: [], workouts: [], from: watch)

        let otherDay = Date(timeIntervalSince1970: TimeInterval(midnight - 5 * 86400))
        XCTAssertTrue(store.samples(onDay: otherDay).isEmpty)
        XCTAssertEqual(store.steps(onDay: otherDay), 0)
        XCTAssertNil(store.restingHeartRate(onDay: otherDay))
    }

    func testRollupsMatchDirectComputation() async {
        let store = FitnessStore(fileURL: fileURL)
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        var input: [ActivitySample] = []
        for minute in 0..<200 {
            input.append(sample(midnight + minute * 60, steps: minute,
                                calories: minute % 7, heartRate: 60 + minute % 40,
                                active: minute % 3 == 0))
        }
        await store.merge(samples: input, spo2: [], workouts: [], from: watch)

        let day = Date(timeIntervalSince1970: TimeInterval(midnight + 3600))
        let inDay = store.samples(onDay: day)
        XCTAssertEqual(store.steps(onDay: day), inDay.reduce(0) { $0 + $1.stepCount })
        XCTAssertEqual(store.calories(onDay: day), inDay.reduce(0) { $0 + $1.calories })
        XCTAssertEqual(store.activeMinutes(onDay: day), inDay.filter(\.isActive).count)

        let restingReference = inDay
            .filter { $0.hasValidHeartRate && !$0.isActive }
            .map(\.heartRate)
            .sorted()
        XCTAssertEqual(store.restingHeartRate(onDay: day),
                       restingReference.count >= 10 ? restingReference[restingReference.count / 20] : nil)
    }

    func testCachedRollupIsInvalidatedByMerge() async {
        let store = FitnessStore(fileURL: fileURL)
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        await store.merge(samples: [sample(midnight + 60, steps: 100)], spo2: [], workouts: [], from: watch)

        let day = Date(timeIntervalSince1970: TimeInterval(midnight + 3600))
        XCTAssertEqual(store.steps(onDay: day), 100)   // populates the cache

        await store.merge(samples: [sample(midnight + 120, steps: 50)], spo2: [], workouts: [], from: watch)
        XCTAssertEqual(store.steps(onDay: day), 150, "stale rollup served after a merge")
    }

    func testUnsortedArchiveIsSortedOnLoad() throws {
        // Hand-written archive with samples out of order — the range lookups
        // binary-search, so load() has to restore the invariant.
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let outOfOrder = [sample(midnight + 600, steps: 3),
                          sample(midnight + 60, steps: 1),
                          sample(midnight + 300, steps: 2)]
        let json = try JSONEncoder().encode([
            "samples": outOfOrder,
        ])
        // Encode via the same shape the store writes (samples/spo2/workouts).
        struct Archive: Codable {
            var samples: [ActivitySample]
            var spo2: [SpO2Sample]
            var workouts: [WorkoutSummary]
        }
        _ = json
        try JSONEncoder()
            .encode(Archive(samples: outOfOrder, spo2: [], workouts: []))
            .write(to: fileURL)

        let store = FitnessStore(fileURL: fileURL)
        XCTAssertEqual(store.samples.map(\.timestamp),
                       outOfOrder.map(\.timestamp).sorted())
        let day = Date(timeIntervalSince1970: TimeInterval(midnight + 3600))
        XCTAssertEqual(store.steps(onDay: day), 6, "binary search needs sorted input")
    }

    func testRollingWindowSeriesMatchFullScan() async {
        let store = FitnessStore(fileURL: fileURL)
        let base = Int(Date().timeIntervalSince1970) - 12 * 3600
        var input: [ActivitySample] = []
        for minute in stride(from: 0, to: 12 * 60, by: 5) {
            input.append(sample(base + minute * 60, steps: minute % 50,
                                heartRate: 60 + minute % 30))
        }
        await store.merge(samples: input, spo2: [], workouts: [], from: watch)

        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date()
        let startTS = Int(start.timeIntervalSince1970)
        let endTS = Int(end.timeIntervalSince1970)

        let expectedHR = store.samples
            .filter { $0.timestamp >= startTS && $0.timestamp < endTS && $0.hasValidHeartRate }
            .map(\.heartRate)
        XCTAssertEqual(store.heartRateSeries(from: start, to: end).map(\.bpm), expectedHR)

        let expectedTotal = store.samples
            .filter { $0.timestamp >= startTS && $0.timestamp < endTS }
            .reduce(0) { $0 + $1.stepCount }
        XCTAssertEqual(store.steps(inBucketsOf: 60, from: start, to: end)
            .reduce(0) { $0 + $1.steps }, expectedTotal)
        XCTAssertEqual(store.steps(inBucketsOf: 10, from: start, to: end)
            .reduce(0) { $0 + $1.steps },
                       expectedTotal)
    }

    func testStepSeriesUsesRequestedBucketsAndSumsWatches() async {
        let store = FitnessStore(fileURL: fileURL)
        let watchB = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000000")!
        let base = Calendar.current.startOfDay(for: Date())
        let timestamp = Int(base.timeIntervalSince1970)

        await store.merge(samples: [sample(timestamp, steps: 12)],
                          spo2: [], workouts: [], from: watch)
        await store.merge(samples: [sample(timestamp + 5 * 60, steps: 8),
                                    sample(timestamp + 12 * 60, steps: 5)],
                          spo2: [], workouts: [], from: watchB)

        let series = store.steps(inBucketsOf: 10, from: base,
                                 to: base.addingTimeInterval(20 * 60))
        XCTAssertEqual(series.map(\.steps), [20, 5])
        XCTAssertEqual(series.map(\.start), [base, base.addingTimeInterval(10 * 60)])
        XCTAssertEqual(series.map(\.end), [base.addingTimeInterval(10 * 60),
                                           base.addingTimeInterval(20 * 60)])
    }
}
