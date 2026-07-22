import XCTest
@testable import Hybridge

/// Sleep is inferred on the phone (the watch stores none). "Still, worn, no
/// steps, low movement" describes sitting at a desk as well as sleeping, and for
/// a calm person with a low resting heart rate the two overlap on HR too — so
/// inference is gated on both a night-time window and a per-minute heart-rate
/// test. These pin: a real low-HR night is kept; a low-HR *daytime* desk stretch
/// is not (night window); an elevated-HR stretch inside the window is not (HR
/// split); and an HR-less watch still gets night detection.
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

    /// Local noon of the day the night-ending window closes on, matching
    /// `sleepScan`'s [prev noon → this noon] window.
    private func windowNoon(nightEnding day: Date) -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart)!
        return Int(noon.timeIntervalSince1970)
    }

    /// A given local hour on the day the window closes on (negative → previous day).
    private func hour(_ h: Int, nightEnding day: Date) -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        return Int(dayStart.timeIntervalSince1970) + h * 3600
    }

    func testLowHeartRateNightIsSleep() async {
        let store = FitnessStore(fileURL: fileURL)
        let today = Date()
        // 23:00 previous day → 06:00 today, sleeping heart rate 52. Inside the
        // 21:00–11:00 night window.
        let start = hour(-1, nightEnding: today)   // 23:00 previous day
        let end = hour(6, nightEnding: today)       // 06:00 today
        await store.merge(samples: stillBlock(from: start, to: end, heartRate: 52),
                          spo2: [], workouts: [], from: watch)

        let sessions = store.sleepSessions(nightEnding: today)
        XCTAssertEqual(sessions.count, 1, "the low-HR overnight block should be sleep")
        XCTAssertGreaterThanOrEqual(sessions.first?.duration ?? 0, 6 * 3600 - 120)
    }

    func testLowHeartRateDaytimeDeskIsNotSleep() async {
        // The reported regression: a calm, motionless, *low heart rate* stretch
        // during the afternoon — indistinguishable from sleep on HR/movement,
        // separated only by the time of day.
        let store = FitnessStore(fileURL: fileURL)
        let today = Date()

        // A real low-HR night so a resting-HR floor exists, plus an afternoon
        // desk block at the same low heart rate outside the night window.
        var input = stillBlock(from: hour(-1, nightEnding: today),   // 23:00 prev
                               to: hour(6, nightEnding: today),        // 06:00 today
                               heartRate: 52)
        input += stillBlock(from: hour(-9, nightEnding: today),       // 15:00 prev day
                            to: hour(-4, nightEnding: today),          // 20:00 prev day
                            heartRate: 55)
        await store.merge(samples: input, spo2: [], workouts: [], from: watch)

        let sessions = store.sleepSessions(nightEnding: today)
        XCTAssertEqual(sessions.count, 1, "only the night block should count, not the afternoon")
        // No session may touch the afternoon desk period (before 21:00 prev day).
        let nightStart = hour(-3, nightEnding: today) // 21:00 previous day
        for session in sessions {
            XCTAssertGreaterThanOrEqual(session.startTimestamp, nightStart,
                                        "a daytime low-HR stretch must not be inferred as sleep")
        }
    }

    func testElevatedHeartRateInsideWindowIsNotSleep() async {
        // Inside the night window but with an awake heart rate (early-morning
        // desk work): the per-minute HR split must reject it.
        let store = FitnessStore(fileURL: fileURL)
        let today = Date()

        var input = stillBlock(from: hour(-1, nightEnding: today),   // 23:00 prev
                               to: hour(4, nightEnding: today),        // 04:00 today
                               heartRate: 50)
        // 07:00–10:00 today, still inside the 11:00 window but heart rate 82.
        input += stillBlock(from: hour(7, nightEnding: today),
                            to: hour(10, nightEnding: today),
                            heartRate: 82)
        await store.merge(samples: input, spo2: [], workouts: [], from: watch)

        let sessions = store.sleepSessions(nightEnding: today)
        let sleepEnd = hour(4, nightEnding: today)
        for session in sessions {
            XCTAssertLessThanOrEqual(session.endTimestamp, sleepEnd + 120,
                                     "an elevated-HR stretch in the window must be split off")
        }
        XCTAssertEqual(sessions.count, 1)
    }

    func testHeartRatelessWatchStillDetectsNightStretch() async {
        // A non-HR watch has no baseline, so the HR split can't veto minutes —
        // the night window alone must still yield a session.
        let store = FitnessStore(fileURL: fileURL)
        let today = Date()
        let input = stillBlock(from: hour(-1, nightEnding: today),
                               to: hour(6, nightEnding: today), heartRate: 0)
        await store.merge(samples: input, spo2: [], workouts: [], from: watch)

        XCTAssertEqual(store.sleepSessions(nightEnding: today).count, 1,
                       "with no heart-rate data the night still-stretch must still count")
    }
}
