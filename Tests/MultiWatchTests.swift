import XCTest
@testable import Hybridge

final class WatchScopedTests: XCTestCase {
    func testKeyFormatting() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(WatchScoped.key("storedAlarms", watchID: id),
                       "storedAlarms.11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(WatchScoped.key("storedAlarms", watchID: nil), "storedAlarms")
    }

    func testPurgeRemovesAllScopedKeys() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        let id = UUID()
        for base in WatchScoped.perWatchKeys {
            defaults.set("x", forKey: WatchScoped.key(base, watchID: id))
        }
        WatchScoped.purge(watchID: id, defaults: defaults)
        for base in WatchScoped.perWatchKeys {
            XCTAssertNil(defaults.object(forKey: WatchScoped.key(base, watchID: id)), base)
        }
    }
}

final class WatchKindTests: XCTestCase {
    /// GB WatchAdapterFactory.createWatchAdapter, byte for byte:
    /// prefix IV0/VA/WA or charAt(2)=='1' → HR; else charAt(6):
    /// '0'/'1' → misfit, '2' → fossil.
    func testDetectTable() {
        let cases: [(String, WatchKind)] = [
            // Hybrid HR family
            ("DN1.0.2.20r.v5", .hybridHR),   // hardware digit at index 2
            ("IV0.0.10.22", .hybridHR),      // HR prefix
            ("VA0.0.26", .hybridHR),         // Gen 6 prefix
            ("WA0.0.30", .hybridHR),         // Gen 6 prefix
            // Non-HR Q: firmware major at index 6 decides the protocol era
            ("HW2.0.2.13r.v5", .fossilQ),
            ("HL2.0.2.7", .fossilQ),
            ("HW2.0.0.13", .misfitQ),
            ("HL2.0.1.7", .misfitQ),
            // Strings GB would crash/throw on
            ("", .unknown),
            ("AB", .unknown),
            ("HW2.0", .unknown),
            ("HW2.0.9.1", .unknown),
        ]
        for (firmware, expected) in cases {
            XCTAssertEqual(WatchKind.detect(firmware: firmware), expected, firmware)
        }
    }

    func testUnknownAndHRGetHRCapabilities() {
        for kind in [WatchKind.hybridHR, .unknown] {
            XCTAssertTrue(kind.needsAuthKey, "\(kind)")
            XCTAssertFalse(kind.hasHandNotificationConfig, "\(kind)")
            XCTAssertFalse(kind.movesHandsMinTwoDegrees, "\(kind)")
        }
        XCTAssertFalse(WatchKind.fossilQ.needsAuthKey)
        XCTAssertFalse(WatchKind.fossilQ.hasDisplay)
        XCTAssertTrue(WatchKind.fossilQ.movesHandsMinTwoDegrees)
        XCTAssertTrue(WatchKind.misfitQ.movesHandsMinTwoDegrees)
    }
}

final class WatchActionAuthorizationTests: XCTestCase {
    private let watchID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let peripheralID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func allows(kind: WatchKind = .hybridHR,
                        token: WatchConnectionToken? = nil,
                        attachedPeripheralID: UUID? = nil,
                        activeWatchID: UUID? = nil,
                        trusted: Bool = true,
                        ready: Bool = true,
                        authenticated: Bool = true) -> Bool {
        let resolvedToken = token ?? WatchConnectionToken(
            watchID: watchID, peripheralID: peripheralID,
            generation: 7, kind: kind)
        return WatchActionAuthorization.allows(
            token: resolvedToken,
            attachedPeripheralID: attachedPeripheralID ?? peripheralID,
            activeWatchID: activeWatchID ?? watchID,
            trusted: trusted,
            sessionReady: ready,
            sessionAuthenticated: authenticated,
            connectedKind: kind)
    }

    func testOnlyTrustedReadyAuthenticatedHRSessionIsAuthorized() {
        XCTAssertTrue(allows())
        XCTAssertFalse(WatchActionAuthorization.allows(
            token: nil, attachedPeripheralID: nil, activeWatchID: nil,
            trusted: false, sessionReady: false,
            sessionAuthenticated: false, connectedKind: .unknown))
        XCTAssertFalse(allows(attachedPeripheralID: UUID()))
        XCTAssertFalse(allows(activeWatchID: UUID()))
        XCTAssertFalse(allows(trusted: false))
        XCTAssertFalse(allows(ready: false))
        XCTAssertFalse(allows(authenticated: false))
    }

    func testStaleFamilyAndUnsupportedSessionsFailClosed() {
        let stale = WatchConnectionToken(
            watchID: watchID, peripheralID: peripheralID,
            generation: 6, kind: .hybridHR)
        XCTAssertFalse(allows(kind: .fossilQ, token: stale))
        XCTAssertFalse(allows(kind: .unknown))
        XCTAssertFalse(allows(kind: .misfitQ))
    }

    func testExplicitlyTrustedReadyQDoesNotPretendToHaveProtocolAuthentication() {
        XCTAssertTrue(allows(kind: .fossilQ, authenticated: false))
        XCTAssertFalse(allows(kind: .fossilQ, trusted: false, authenticated: false))
        XCTAssertFalse(allows(kind: .fossilQ, ready: false, authenticated: false))
    }
}

final class WatchRegistryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "WatchRegistryTests")
        defaults.removePersistentDomain(forName: "WatchRegistryTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "WatchRegistryTests")
        super.tearDown()
    }

    func testRegisterIsIdempotentAndPersists() {
        let registry = WatchRegistry(defaults: defaults)
        let id = UUID()
        registry.register(id: id, name: "Watch A")
        registry.register(id: id, name: "Renamed later")
        XCTAssertEqual(registry.watches.count, 1)
        XCTAssertEqual(registry.watches[0].name, "Watch A")

        // A fresh instance sees the persisted roster.
        let reloaded = WatchRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.watches.map(\.id), [id])
    }

    func testSetActiveRoundTripsAndPostsNotification() {
        let registry = WatchRegistry(defaults: defaults)
        let id = UUID()
        registry.register(id: id, name: "Watch A")

        let posted = expectation(forNotification: .activeWatchChanged, object: nil)
        registry.setActive(id)
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(registry.activeWatchID, id)
        XCTAssertEqual(WatchRegistry(defaults: defaults).activeWatchID, id)

        registry.setActive(nil)
        XCTAssertNil(registry.activeWatchID)
        XCTAssertNil(WatchRegistry(defaults: defaults).activeWatchID)
    }

    func testRenameUpdateModelRemove() {
        let registry = WatchRegistry(defaults: defaults)
        let a = UUID(), b = UUID()
        registry.register(id: a, name: "A")
        registry.register(id: b, name: "B")

        registry.rename(a, to: "Skagen")
        registry.updateModel(a, model: "DW9F2")
        XCTAssertEqual(registry.watch(a)?.name, "Skagen")
        XCTAssertEqual(registry.watch(a)?.modelNumber, "DW9F2")
        XCTAssertNil(registry.watch(b)?.modelNumber)

        registry.remove(a)
        XCTAssertNil(registry.watch(a))
        XCTAssertEqual(registry.watches.map(\.id), [b])
    }

    func testUpdateKindRoundTrips() {
        let registry = WatchRegistry(defaults: defaults)
        let id = UUID()
        registry.register(id: id, name: "Grant")
        XCTAssertNil(registry.watch(id)?.kind)

        registry.updateKind(id, kind: .fossilQ, firmware: "XX2.0.2.1")
        XCTAssertEqual(registry.watch(id)?.kind, .fossilQ)
        XCTAssertEqual(registry.watch(id)?.firmware, "XX2.0.2.1")

        let reloaded = WatchRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.watch(id)?.kind, .fossilQ)
    }

    func testActiveKindSyncDefaultsToHybridHR() {
        // Uses .standard via the Sync helpers — exercise the decode-level
        // default instead: a roster entry without a kind is treated as HR.
        let registry = WatchRegistry(defaults: defaults)
        let id = UUID()
        registry.register(id: id, name: "Old HR")
        XCTAssertNil(registry.watch(id)?.kind)
    }

    /// A roster persisted before the kind/firmware fields existed must keep
    /// decoding (optionals absent from the JSON).
    func testDecodesPreKindRosterJSON() throws {
        let id = UUID()
        let legacyJSON = """
        [{"id":"\(id.uuidString)","name":"My watch","addedDate":700000000}]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: WatchRegistry.watchesKey)

        let registry = WatchRegistry(defaults: defaults)
        XCTAssertEqual(registry.watches.map(\.id), [id])
        XCTAssertNil(registry.watches[0].kind)
        XCTAssertNil(registry.watches[0].firmware)
    }

    func testCorruptRosterRestoresLastVerifiedCopyAndPreservesBadBytes() {
        let registry = WatchRegistry(defaults: defaults)
        let id = UUID()
        registry.register(id: id, name: "Safe watch")
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: WatchRegistry.watchesKey)

        let recovered = WatchRegistry(defaults: defaults)
        XCTAssertEqual(recovered.watches.map(\.id), [id])
        XCTAssertNotEqual(defaults.data(forKey: WatchRegistry.watchesKey), corrupt)
        let preserved = defaults.dictionaryRepresentation().contains {
            $0.key.hasPrefix(WatchRegistry.corruptWatchesPrefix)
                && ($0.value as? Data) == corrupt
        }
        XCTAssertTrue(preserved)
    }
}

final class QMultiPressStoreTests: XCTestCase {
    func testDefaultsAndStableStorageKey() {
        // One button doing volume both ways out of the box: single up,
        // double down (long = play/pause).
        XCTAssertEqual(QMultiPressStore.defaults, [.volumeUp, .volumeDown, .playPause])
        XCTAssertTrue(WatchScoped.perWatchKeys.contains("qMultiPressActions"),
                      "legacy scoped copies must still be purged on forget")
    }
}

final class AppMigrationsTests: XCTestCase {
    private let suite = "AppMigrationsTests"
    private var defaults: UserDefaults!
    private let watchID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testMigratesRememberedWatchIntoRoster() throws {
        defaults.set(watchID.uuidString, forKey: "rememberedPeripheralID")
        let alarms = Data("alarm-blob".utf8)
        defaults.set(alarms, forKey: "storedAlarms")
        defaults.set(50, forKey: "vibrationStrength")
        defaults.set("SomeFace", forKey: "activeWatchfaceName")

        AppMigrations.run(defaults: defaults)

        // Roster + active id.
        let registry = WatchRegistry(defaults: defaults)
        XCTAssertEqual(registry.watches.map(\.id), [watchID])
        XCTAssertEqual(registry.activeWatchID, watchID)

        // Watch-owned values move into the watch namespace.
        XCTAssertEqual(defaults.data(forKey: WatchScoped.key("storedAlarms", watchID: watchID)), alarms)
        XCTAssertNil(defaults.object(forKey: "storedAlarms"))

        // Settings-tab values become shared after the v2 migration. The old
        // scoped copy stays only as downgrade/recovery data.
        XCTAssertEqual(defaults.integer(forKey: WatchScoped.key("vibrationStrength", watchID: watchID)), 50)
        XCTAssertEqual(defaults.integer(forKey: "vibrationStrength"), 50)
        XCTAssertEqual(defaults.string(forKey: WatchScoped.key("activeWatchfaceName", watchID: watchID)), "SomeFace")

        // Fitness adoption marker for FitnessStore.
        XCTAssertEqual(defaults.string(forKey: AppMigrations.fitnessLegacyOwnerKey), watchID.uuidString)
    }

    func testClearsRemovedLegacyCommuteKey() {
        defaults.set(watchID.uuidString, forKey: "rememberedPeripheralID")
        defaults.set(["Home", "Work"], forKey: "commuteDestinations")

        AppMigrations.run(defaults: defaults)

        // The commute feature was removed; its legacy key must be cleaned up.
        XCTAssertNil(defaults.object(forKey: "commuteDestinations"))
    }

    func testIdempotent() {
        defaults.set(watchID.uuidString, forKey: "rememberedPeripheralID")
        AppMigrations.run(defaults: defaults)

        // A value written after migration must not be re-moved or clobbered.
        defaults.set(Data("new".utf8), forKey: "storedAlarms")
        AppMigrations.run(defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: "storedAlarms"), Data("new".utf8))
        XCTAssertNil(defaults.data(forKey: WatchScoped.key("storedAlarms", watchID: watchID)))
    }

    func testNoRememberedWatchMeansEmptyRoster() {
        AppMigrations.run(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: AppMigrations.versionKey), 2)
        XCTAssertTrue(WatchRegistry(defaults: defaults).isEmpty)
        XCTAssertNil(defaults.string(forKey: AppMigrations.fitnessLegacyOwnerKey))
    }
}

final class FitnessStoreMultiWatchTests: XCTestCase {
    private var fileURL: URL!
    private let watchA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let watchB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fitness-test-\(UUID().uuidString).json")
        // Make sure the adoption marker from a real migration can't leak in.
        UserDefaults.standard.removeObject(forKey: AppMigrations.fitnessLegacyOwnerKey)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeSample(_ timestamp: Int, steps: Int = 10) -> ActivitySample {
        ActivitySample(timestamp: timestamp, stepCount: steps, calories: 1, heartRate: 70,
                       variability: 10, maxVariability: 20, heartRateQuality: 3,
                       isActive: true, wearingState: 0)
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }

    func testSameMinuteFromTwoWatchesBothSurvive() async {
        let store = FitnessStore(fileURL: fileURL)
        let ts = now - 3600
        await store.merge(samples: [makeSample(ts, steps: 10)], spo2: [], workouts: [], from: watchA)
        let added = await store.merge(samples: [makeSample(ts, steps: 20)], spo2: [], workouts: [], from: watchB).count
        XCTAssertEqual(added, 1, "watch B's sample in the same minute must not be dropped")
        XCTAssertEqual(store.samples.count, 2)
        XCTAssertEqual(Set(store.samples.compactMap(\.watchID)), [watchA, watchB])
    }

    func testGlobalStepsTopUpEachWatchWithoutDoubleCountingSyncedSamples() async {
        let store = FitnessStore(fileURL: fileURL)
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        await store.merge(samples: [makeSample(midnight + 60, steps: 100)],
                          spo2: [], workouts: [], from: watchA)
        await store.merge(samples: [makeSample(midnight + 120, steps: 200)],
                          spo2: [], workouts: [], from: watchB)

        await store.recordLiveStepCount(150, for: watchA)
        XCTAssertEqual(store.stepsIncludingLive(onDay: Date()), 350)

        await store.recordLiveStepCount(260, for: watchB)
        XCTAssertEqual(store.stepsIncludingLive(onDay: Date()), 410,
                       "both watches contribute, independent of which one is active")
    }

    func testGlobalStepsIgnoreStaleAndLowerLiveCounters() async {
        let store = FitnessStore(fileURL: fileURL)
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        await store.merge(samples: [makeSample(midnight + 60, steps: 100)],
                          spo2: [], workouts: [], from: watchA)

        await store.recordLiveStepCount(80, for: watchA)
        await store.recordLiveStepCount(500, for: watchB,
                                        at: Date(timeIntervalSince1970: TimeInterval(midnight - 60)))

        XCTAssertEqual(store.stepsIncludingLive(onDay: Date()), 100,
                       "a reset/lower counter and yesterday's observation must not reduce or inflate today")
    }

    func testPushedStepBaselineSurvivesRelaunch() async {
        let store = FitnessStore(fileURL: fileURL)
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        await store.merge(samples: [makeSample(midnight + 60, steps: 2500)],
                          spo2: [], workouts: [], from: watchA)
        XCTAssertEqual(store.stepsIncludingLive(onDay: Date()), 2500)

        // Switching to watch B pushes the cross-watch total into it.
        await store.recordPushedStepBaseline(2500, for: watchB)
        await store.recordLiveStepCount(2500, for: watchB)
        XCTAssertEqual(store.stepsIncludingLive(onDay: Date()), 2500,
                       "the just-pushed baseline must not be added again")

        // A fresh process reads B's config (still 2500, unworn) before
        // `pushDailyStepBaseline` runs again. Without the persisted baseline
        // this used to double the total for an instant.
        let reloaded = FitnessStore(fileURL: fileURL)
        await reloaded.recordLiveStepCount(2500, for: watchB)
        XCTAssertEqual(reloaded.stepsIncludingLive(onDay: Date()), 2500,
                       "a relaunch must remember watch B's already-reconciled baseline")
    }

    /// `FitnessStore.shared` loads its archive asynchronously in production
    /// (`loadAsynchronously: true`) — a BLE config read landing before that
    /// load finishes must not see an empty `pushedStepBaselineByWatch` and
    /// briefly double the total, which is what happened before
    /// `recordLiveStepCount` started awaiting the load task itself.
    func testRecordLiveStepCountAwaitsAsynchronousLoadBeforeMutating() async {
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        do {
            let seed = FitnessStore(fileURL: fileURL)
            await seed.merge(samples: [makeSample(midnight + 60, steps: 2500)],
                             spo2: [], workouts: [], from: watchA)
            await seed.recordPushedStepBaseline(2500, for: watchB)
        }

        let store = FitnessStore(fileURL: fileURL, loadAsynchronously: true)
        // No delay: this races the archive's async load exactly as a BLE
        // config read racing app-launch load would in production.
        await store.recordLiveStepCount(2500, for: watchB)
        XCTAssertEqual(store.stepsIncludingLive(onDay: Date()), 2500,
                       "must not double before the archive (and its baseline) has loaded")
    }

    func testResyncFromSameWatchStillDedups() async {
        let store = FitnessStore(fileURL: fileURL)
        let ts = now - 3600
        await store.merge(samples: [makeSample(ts)], spo2: [], workouts: [], from: watchA)
        let added = await store.merge(samples: [makeSample(ts)], spo2: [], workouts: [], from: watchA).count
        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.samples.count, 1)
    }

    func testPerWatchLastSync() async {
        let store = FitnessStore(fileURL: fileURL)
        await store.merge(samples: [makeSample(now - 60)], spo2: [], workouts: [], from: watchA)
        XCTAssertNotNil(store.lastSync(for: watchA))
        XCTAssertNil(store.lastSync(for: watchB))

        let earlier = Date(timeIntervalSinceNow: -7200)
        await store.setLastSync(earlier, for: watchB)
        XCTAssertEqual(store.lastSync(for: watchB), earlier)
        // The combined label shows the most recent sync.
        XCTAssertEqual(store.lastSyncDate, store.lastSync(for: watchA))
    }

    func testLegacyArchiveDecodesAndAdoptionTags() async throws {
        // A pre-multi-watch archive: no watchID fields, single lastSync.
        let ts = now - 3600
        let legacyJSON = """
        {"samples":[{"timestamp":\(ts),"stepCount":5,"calories":1,"heartRate":70,
        "variability":10,"maxVariability":20,"heartRateQuality":3,
        "isActive":true,"wearingState":0}],
        "spo2":[{"timestamp":\(ts),"value":97}],
        "workouts":[{"id":"\(UUID().uuidString)","kind":"Running","startTimestamp":\(ts),"endTimestamp":\(ts + 600)}],
        "lastSync":700000000}
        """
        try Data(legacyJSON.utf8).write(to: fileURL)

        let store = FitnessStore(fileURL: fileURL)
        XCTAssertEqual(store.samples.count, 1)
        XCTAssertNil(store.samples[0].watchID)

        await store.adoptLegacyData(watchID: watchA)
        XCTAssertEqual(store.samples[0].watchID, watchA)
        XCTAssertEqual(store.spo2Samples[0].watchID, watchA)
        XCTAssertEqual(store.workouts[0].watchID, watchA)
        XCTAssertEqual(store.lastSync(for: watchA), Date(timeIntervalSinceReferenceDate: 700000000))

        // Adoption persists.
        let reloaded = FitnessStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.samples[0].watchID, watchA)
        XCTAssertEqual(reloaded.lastSync(for: watchA), Date(timeIntervalSinceReferenceDate: 700000000))
    }

    func testWorkoutsFromTwoWatchesWithSameWindowBothKept() async {
        let store = FitnessStore(fileURL: fileURL)
        let start = now - 7200, end = now - 3600
        let workout = WorkoutSummary(kind: "Running", startTimestamp: start, endTimestamp: end)
        await store.merge(samples: [], spo2: [], workouts: [workout], from: watchA)
        await store.merge(samples: [], spo2: [], workouts: [workout], from: watchB)
        await store.merge(samples: [], spo2: [], workouts: [workout], from: watchA)
        XCTAssertEqual(store.workouts.count, 2)
    }
}
