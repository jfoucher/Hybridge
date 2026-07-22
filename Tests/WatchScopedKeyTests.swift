import XCTest
@testable import Hybridge

/// The per-watch key set and the purge list used to be two hand-maintained
/// things that drifted: the four `body*` keys were written with
/// `WatchScoped.key(...)` but missing from `perWatchKeys`, so forgetting a
/// watch left its owner's age, gender, height and weight in UserDefaults.
/// Deriving the list from a `CaseIterable` enum makes that unrepresentable;
/// these tests pin the properties that matter.
final class WatchScopedKeyTests: XCTestCase {
    private let watchID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000000")!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "scoped-key-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPurgeListCoversEveryDeclaredKey() {
        let declared = Set(WatchScopedKey.allCases.map(\.rawValue))
        let purged = Set(WatchScoped.perWatchKeys)
        XCTAssertEqual(declared, purged,
                       "every scoped key must be purged when a watch is forgotten")
    }

    func testBodyProfileKeysArePurged() {
        // The specific regression: these were written but never cleared.
        for key in [WatchScopedKey.bodyHeightCm, .bodyWeightKg, .bodyGender, .bodyBirth] {
            XCTAssertTrue(WatchScoped.perWatchKeys.contains(key.rawValue),
                          "\(key.rawValue) must be purged on forget — it is personal data")
        }
    }

    func testPurgeRemovesEveryScopedValueForThatWatch() {
        for key in WatchScopedKey.allCases {
            defaults.set("value", forKey: WatchScoped.key(key.rawValue, watchID: watchID))
        }
        WatchScoped.purge(watchID: watchID, defaults: defaults)
        for key in WatchScopedKey.allCases {
            XCTAssertNil(defaults.object(forKey: WatchScoped.key(key.rawValue, watchID: watchID)),
                         "\(key.rawValue) survived the purge")
        }
    }

    func testPurgeLeavesOtherWatchesAlone() {
        let other = UUID()
        defaults.set("keep", forKey: WatchScoped.key(WatchScopedKey.storedAlarms.rawValue, watchID: other))
        defaults.set("drop", forKey: WatchScoped.key(WatchScopedKey.storedAlarms.rawValue, watchID: watchID))
        WatchScoped.purge(watchID: watchID, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: WatchScoped.key(WatchScopedKey.storedAlarms.rawValue,
                                                              watchID: other)), "keep")
    }

    func testRawValuesAreStableAcrossTheRename() {
        // The enum replaced string literals; the raw values are the on-disk
        // UserDefaults keys, so changing one silently orphans user settings.
        XCTAssertEqual(WatchScopedKey.storedAlarms.rawValue, "storedAlarms")
        XCTAssertEqual(WatchScopedKey.qButtonFunctions.rawValue, "qButtonFunctions")
        XCTAssertEqual(WatchScopedKey.bodyHeightCm.rawValue, "bodyHeightCm")
        XCTAssertEqual(WatchScopedKey.quietSchedule.rawValue, "quietSchedule")
        XCTAssertEqual(WatchScopedKey.notificationIconsEnabled.rawValue, "notificationIconsEnabled")
    }

    func testKeysAreUnique() {
        let raws = WatchScopedKey.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count, "two cases share a UserDefaults key")
    }

    // MARK: - WatchScopedValue

    func testScopedValueRoundTripsAndFallsBackToDefault() {
        let store = WatchScopedValue(.storedAlarms, default: [1, 2, 3], defaults: defaults)
        XCTAssertEqual(store.wrappedValue, [1, 2, 3], "unset must read as the default")
        store.wrappedValue = [9]
        XCTAssertEqual(store.wrappedValue, [9])
        store.reset()
        XCTAssertEqual(store.wrappedValue, [1, 2, 3], "reset must restore the default")
    }

    func testScopedValueRejectsInvalidStoredValue() {
        // Mirrors the Q button/multi-press rule: exactly three entries.
        let store = WatchScopedValue(.qMultiPressActions, default: [0, 0, 0],
                                     defaults: defaults, isValid: { $0.count == 3 })
        store.wrappedValue = [1, 2]        // wrong shape, e.g. an older build
        XCTAssertEqual(store.wrappedValue, [0, 0, 0], "invalid stored value must not be served")
        store.wrappedValue = [4, 5, 6]
        XCTAssertEqual(store.wrappedValue, [4, 5, 6])
    }

    func testGlobalSettingsValueUsesBareKey() {
        let store = GlobalSettingsValue(.qMultiPressActions, default: [0, 0, 0],
                                        defaults: defaults)
        store.wrappedValue = [1, 2, 3]
        XCTAssertEqual(store.wrappedValue, [1, 2, 3])
        XCTAssertNotNil(defaults.data(forKey: WatchScopedKey.qMultiPressActions.rawValue))
        XCTAssertNil(defaults.data(forKey: WatchScoped.key(.qMultiPressActions,
                                                           watchID: watchID)))
    }
}
