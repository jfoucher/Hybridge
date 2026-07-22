import XCTest
@testable import Hybridge

final class ActivityQuarantineStoreTests: XCTestCase {
    func testQuarantinePersistsIdentityAndSkipsOnlyUnchangedHandle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-quarantine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchID = UUID()
        let bytes = Data([1, 2, 3, 4])

        let store = ActivityQuarantineStore(directory: directory)
        let record = try await store.quarantine(
            bytes, watchID: watchID, handle: 0x0107, failureCategory: "truncated")
        XCTAssertEqual(record.version, 7)
        XCTAssertEqual(record.length, bytes.count)
        XCTAssertEqual(record.fingerprint, Checksums.crc32(bytes))
        let skipsSame = await store.shouldSkipAutomaticDownload(watchID: watchID, handle: 0x0107)
        let skipsChanged = await store.shouldSkipAutomaticDownload(watchID: watchID, handle: 0x0108)
        let exportURL = await store.exportURL(for: watchID)
        XCTAssertTrue(skipsSame)
        XCTAssertFalse(skipsChanged)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(exportURL)), bytes)

        let reloaded = ActivityQuarantineStore(directory: directory)
        let loadedRecord = await reloaded.record(for: watchID)
        XCTAssertEqual(loadedRecord, record)
        await reloaded.noteExplicitRetry(watchID: watchID, handle: 0x0107)
        let retriedRecord = await reloaded.record(for: watchID)
        XCTAssertEqual(retriedRecord?.retryCount, 1)
        await reloaded.clear(watchID: watchID)
        let clearedRecord = await reloaded.record(for: watchID)
        let clearedURL = await reloaded.exportURL(for: watchID)
        XCTAssertNil(clearedRecord)
        XCTAssertNil(clearedURL)
    }
}
