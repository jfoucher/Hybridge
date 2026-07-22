import XCTest
import HealthKit
@testable import Hybridge

@MainActor
private final class MockHealthStoreWriter: HealthStoreWriting {
    struct Failure: Error {}

    var isHealthDataAvailable = true
    var authorizedIdentifiers = Set<String>()
    var savedBatches: [[HKSample]] = []
    var workoutAttempts: [Int] = []
    var failingWorkoutStart: Int?

    func requestAuthorization() async throws {}

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        authorizedIdentifiers.contains(type.identifier) ? .sharingAuthorized : .sharingDenied
    }

    func save(_ samples: [HKSample]) async throws {
        savedBatches.append(samples)
    }

    func saveWorkout(_ workout: WorkoutSummary) async throws {
        workoutAttempts.append(workout.startTimestamp)
        if workout.startTimestamp == failingWorkoutStart { throw Failure() }
    }
}

final class HealthKitExporterAdapterTests: XCTestCase {
    @MainActor
    func testExportsIndependentlyAuthorizedSampleTypes() async throws {
        let writer = MockHealthStoreWriter()
        writer.authorizedIdentifiers = [HKQuantityType(.stepCount).identifier]
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "HealthKitExporterAdapterTests-\(UUID().uuidString)"))
        let exporter = HealthKitExporter(store: writer, defaults: defaults)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-export-\(UUID().uuidString).json")
        let fitness = FitnessStore(fileURL: archive)
        let timestamp = Int(Date().timeIntervalSince1970) - 60
        let sample = ActivitySample(
            timestamp: timestamp, stepCount: 123, calories: 8, heartRate: 72,
            variability: 0, maxVariability: 0, heartRateQuality: 2,
            isActive: true, wearingState: 0)
        _ = await fitness.merge(samples: [sample], spo2: [], workouts: [])

        let count = try await exporter.exportNewSamples(
            from: fitness, requestingAuthorization: false)

        XCTAssertEqual(count, 1)
        let samples = writer.savedBatches.flatMap { $0 }
        XCTAssertEqual(samples.map(\.sampleType.identifier),
                       [HKQuantityType(.stepCount).identifier])
        XCTAssertNotNil(samples.first?.metadata?[HKMetadataKeySyncIdentifier])
    }

    @MainActor
    func testSuccessfulWorkoutIsCheckpointedBeforeLaterFailure() async throws {
        let writer = MockHealthStoreWriter()
        writer.authorizedIdentifiers = [HKWorkoutType.workoutType().identifier]
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "HealthKitExporterAdapterTests-\(UUID().uuidString)"))
        let exporter = HealthKitExporter(store: writer, defaults: defaults)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-workouts-\(UUID().uuidString).json")
        let fitness = FitnessStore(fileURL: archive)
        let base = Int(Date().timeIntervalSince1970) - 3_600
        let first = WorkoutSummary(kind: "Running", startTimestamp: base,
                                   endTimestamp: base + 600)
        let second = WorkoutSummary(kind: "Walking", startTimestamp: base + 1_000,
                                    endTimestamp: base + 1_600)
        _ = await fitness.merge(samples: [], spo2: [], workouts: [first, second])
        writer.failingWorkoutStart = second.startTimestamp

        do {
            _ = try await exporter.exportNewSamples(from: fitness,
                                                     requestingAuthorization: false)
            XCTFail("partial workout failure was not propagated")
        } catch is MockHealthStoreWriter.Failure {
            // The first workout completed and must already be checkpointed.
        }

        writer.failingWorkoutStart = nil
        let retryCount = try await exporter.exportNewSamples(
            from: fitness, requestingAuthorization: false)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(writer.workoutAttempts,
                       [first.startTimestamp, second.startTimestamp, second.startTimestamp])
    }
}
