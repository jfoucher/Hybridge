import XCTest
@testable import Hybridge

/// Sleep is inferred on the phone (the watch stores none). The heart-rate gate
/// exists because "still, worn, no steps, low movement" describes sitting at a
/// desk exactly as well as it describes sleeping — only heart rate separates
/// the two. These pin that a real low-HR night is kept and an elevated-HR desk
/// stretch is rejected, without regressing HR-less watches.
final class SleepInferenceTests: XCTestCase {
    private var fileURL: URL!
    private let watch = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000000")!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleep-inference-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    /// A "still" sample: worn, inactive, no steps, low movement variability.
    private func still(_ timestamp: Int, heartRate: Int) -> ActivitySample {
        ActivitySample(timestamp: timestamp, stepCount: 0, calories: 0,
                       heartRate: heartRate, variability: 10, maxVariability: 20,
                       heartRateQuality: heartRate > 0 ? 3 : 0,
                       isActive: false, wearingState: 0)
    }

    /// Fill every minute in `[start, end)` with still samples at `heartRate`.
    private func stillBlock(from start: Int, to end: Int, heartRate: Int) -> [ActivitySample] {
        stride(from: start, to: end, by: 60).map { still($0, heartRate: heartRate) }
    }

    /// Noon-anchored window boundaries for the night ending on `day`, matching
    /// `sleepSessions`' own [prev noon → this noon] window.
    private func windowNoon(nightEnding day: Date) -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart)!
        return Int(noon.timeIntervalSince1970)
    }

    func testLowHeartRateNightIsSleepAndDaytimeDeskIsNot() async {
        let store = FitnessStore(fileURL: fileURL)
        let today = Date()
        let noon = windowNoon(nightEnding: today)

        // Overnight: 23:00 yesterday → 06:00 today, heart rate at a sleeping 52.
        let nightStart = noon - 13 * 3600   // 23:00 previous day
        let nightEnd = noon - 6 * 3600      // 06:00 today
        // Daytime desk: 09:00 → 11:00 today, motionless but heart rate at 78.
        let deskStart = noon - 3 * 3600     // 09:00 today
        let deskEnd = noon - 1 * 3600       // 11:00 today

        var input = stillBlock(from: nightStart, to: nightEnd, heartRate: 52)
        input += stillBlock(from: deskStart, to: deskEnd, heartRate: 78)
        await store.merge(samples: input, spo2: [], workouts: [], from: watch)

        let sessions = store.sleepSessions(nightEnding: today)
        XCTAssertEqual(sessions.count, 1, "exactly the overnight block should be sleep")
        XCTAssertEqual(sessions.first?.startTimestamp, nightStart,
                       "the detected session should be the low-HR night, not the desk stretch")
        // The desk window must not be covered by any session.
        for session in sessions {
            XCTAssertLessThanOrEqual(session.endTimestamp, deskStart,
                                     "no session may extend into the elevated-HR desk period")
        }
    }

    func testHeartRatelessWatchStillDetectsStillStretches() async {
        // A non-HR watch (or a night with no HR sampling) has no baseline, so
        // the gate must not delete an otherwise-valid still stretch.
        let store = FitnessStore(fileURL: fileURL)
        let today = Date()
        let noon = windowNoon(nightEnding: today)

        let input = stillBlock(from: noon - 13 * 3600, to: noon - 6 * 3600, heartRate: 0)
        await store.merge(samples: input, spo2: [], workouts: [], from: watch)

        XCTAssertEqual(store.sleepSessions(nightEnding: today).count, 1,
                       "with no heart-rate data the still stretch must still count as sleep")
    }
}
