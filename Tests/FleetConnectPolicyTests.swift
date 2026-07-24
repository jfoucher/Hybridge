import XCTest
@testable import Hybridge

final class FleetConnectPolicyTests: XCTestCase {
    private func watch(_ id: UUID, keepConnected: Bool?) -> KnownWatch {
        KnownWatch(id: id, name: "w", modelNumber: nil, addedDate: Date(),
                   lastConnectedDate: nil, kind: .hybridHR, firmware: nil,
                   trusted: true, keepConnected: keepConnected)
    }

    func testConnectsEveryWatchExceptExplicitlyParked() {
        let a = UUID(), b = UUID(), c = UUID()
        let roster = [watch(a, keepConnected: true),
                      watch(b, keepConnected: nil),      // nil == yes
                      watch(c, keepConnected: false)]    // parked
        let toConnect = Set(FleetConnectPolicy.watchesToConnect(roster: roster))
        XCTAssertEqual(toConnect, [a, b])
        XCTAssertFalse(toConnect.contains(c))
    }

    func testShouldStayConnected() {
        let a = UUID(), b = UUID(), gone = UUID()
        let roster = [watch(a, keepConnected: nil), watch(b, keepConnected: false)]
        XCTAssertTrue(FleetConnectPolicy.shouldStayConnected(a, roster: roster))
        XCTAssertFalse(FleetConnectPolicy.shouldStayConnected(b, roster: roster))
        // A forgotten watch (absent from the roster) is never reconnected.
        XCTAssertFalse(FleetConnectPolicy.shouldStayConnected(gone, roster: roster))
    }

    func testRestoredAdoptionMatchesStayConnected() {
        let a = UUID(), parked = UUID(), stray = UUID()
        let roster = [watch(a, keepConnected: true), watch(parked, keepConnected: false)]
        XCTAssertTrue(FleetConnectPolicy.shouldAdoptRestored(a, roster: roster))
        XCTAssertFalse(FleetConnectPolicy.shouldAdoptRestored(parked, roster: roster))
        XCTAssertFalse(FleetConnectPolicy.shouldAdoptRestored(stray, roster: roster))
    }

    func testKeepConnectedDecodesOnOlderRosterAsYes() throws {
        // A roster written before the field existed must decode with
        // keepConnected == nil and therefore count as "connect".
        let legacy = """
        [{"id":"\(UUID().uuidString)","name":"old","addedDate":0}]
        """.data(using: .utf8)!
        let watches = try JSONDecoder().decode([KnownWatch].self, from: legacy)
        XCTAssertEqual(watches.count, 1)
        XCTAssertNil(watches[0].keepConnected)
        XCTAssertEqual(FleetConnectPolicy.watchesToConnect(roster: watches), [watches[0].id])
    }
}
