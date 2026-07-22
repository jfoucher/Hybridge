import XCTest
@testable import Hybridge

/// The export used to filter samples with `sampleTimestamp > lastExportDate`,
/// comparing sample time against wall-clock export time. Anything that arrived
/// late but was older than the last export — a second watch worn yesterday and
/// synced today, or any watch after a sync gap — was skipped permanently.
/// Coverage is now tracked as per-watch timestamp intervals; these tests pin
/// the merge/coverage logic that replaced it.
final class HealthExportRangeTests: XCTestCase {

    /// Exercises the production implementation, not a copy of it.
    private func merge(_ ranges: [HealthKitExporter.ExportedRange]) -> [HealthKitExporter.ExportedRange] {
        HealthKitExporter.merged(ranges)
    }

    func testRangeCoversItsBounds() {
        let range = HealthKitExporter.ExportedRange(start: 100, end: 200)
        XCTAssertTrue(range.covers(100))
        XCTAssertTrue(range.covers(150))
        XCTAssertTrue(range.covers(200))
        XCTAssertFalse(range.covers(99))
        XCTAssertFalse(range.covers(201))
    }

    func testBackfillGapIsNotCovered() {
        // Exported Monday and Wednesday; Tuesday arrives late from a second
        // watch. Under the old cutoff rule Tuesday was invisible forever.
        let ranges = merge([.init(start: 1_000, end: 2_000),
                            .init(start: 5_000, end: 6_000)])
        XCTAssertEqual(ranges.count, 2, "a real gap must not be merged away")
        let tuesday = 3_500
        XCTAssertFalse(ranges.contains { $0.covers(tuesday) },
                       "backfilled data inside the gap must still be exportable")
    }

    func testOverlappingRangesMerge() {
        let ranges = merge([.init(start: 100, end: 200),
                            .init(start: 150, end: 300)])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 100)
        XCTAssertEqual(ranges[0].end, 300)
    }

    func testAdjacentRangesMerge() {
        // Touching intervals collapse, so the list stays a handful of entries
        // rather than growing once per sync forever.
        let ranges = merge([.init(start: 100, end: 200),
                            .init(start: 201, end: 300)])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].end, 300)
    }

    func testManySequentialSyncsCollapseToOneRange() {
        var ranges: [HealthKitExporter.ExportedRange] = []
        for day in 0..<120 {
            ranges = merge(ranges + [.init(start: day * 86400, end: (day + 1) * 86400 - 1)])
        }
        XCTAssertEqual(ranges.count, 1, "contiguous daily syncs must not grow the list")
    }

    func testUnorderedInsertionStillMerges() {
        let ranges = merge([.init(start: 500, end: 600),
                            .init(start: 100, end: 200),
                            .init(start: 201, end: 499)])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 100)
        XCTAssertEqual(ranges[0].end, 600)
    }

    // MARK: - Coverage from actual timestamps preserves intra-span gaps (§5.5)

    private func ranges(_ timestamps: [Int], maxGap: Int = HealthKitExporter.exportCadenceTolerance)
        -> [HealthKitExporter.ExportedRange] {
        HealthKitExporter.contiguousRanges(timestamps, maxGap: maxGap)
    }

    func testConsecutiveMinutesCoalesceToOneRange() {
        // A full hour of minute samples is one contiguous range, not 60.
        let minutes = stride(from: 1_000, through: 1_000 + 59 * 60, by: 60).map { $0 }
        let result = ranges(minutes)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, 1_000)
        XCTAssertEqual(result[0].end, 1_000 + 59 * 60)
    }

    func testMissingMinuteBreaksCoverageSoBackfillStillExports() {
        // Exported :00, :01, :03, :04 — the :02 minute hadn't synced yet.
        let base = 1_000
        let exported = [base, base + 60, base + 180, base + 240]
        let result = HealthKitExporter.merged(ranges(exported))
        XCTAssertEqual(result.count, 2, "the missing minute must split the coverage")
        let missingMinute = base + 120
        XCTAssertFalse(result.contains { $0.covers(missingMinute) },
                       "the not-yet-synced minute must remain exportable")
        // The minutes that were exported are still covered (no re-export).
        XCTAssertTrue(result.contains { $0.covers(base + 60) })
        XCTAssertTrue(result.contains { $0.covers(base + 240) })
    }

    func testSingleTimestampIsAPointRange() {
        let result = ranges([5_000])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, 5_000)
        XCTAssertEqual(result[0].end, 5_000)
    }

    func testUnsortedTimestampsStillCoalesceCorrectly() {
        let base = 1_000
        let result = ranges([base + 120, base, base + 60])   // one contiguous run, shuffled
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, base)
        XCTAssertEqual(result[0].end, base + 120)
    }

    func testMigrationSeedCoversEverythingBeforeLastExport() {
        // Upgrading installs seed one open-ended interval so they don't
        // re-export months of history into Apple Health.
        let lastExport = 1_700_000_000
        let seed = HealthKitExporter.ExportedRange(start: .min, end: lastExport)
        XCTAssertTrue(seed.covers(lastExport - 86_400 * 90))
        XCTAssertTrue(seed.covers(lastExport))
        XCTAssertFalse(seed.covers(lastExport + 1), "new data must still export")
    }
}
