import XCTest
@testable import Hybridge

final class AppStoreSearchTests: XCTestCase {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    private let twoApps = """
    {"resultCount":2,"results":[
      {"trackName":"Signal","bundleId":"org.whispersystems.signal",
       "artworkUrl60":"https://is1-ssl.mzstatic.com/image/60x60.jpg"},
      {"trackName":"Telegram","bundleId":"ph.telegra.Telegraph","artworkUrl60":null}
    ]}
    """

    /// The regression this file exists for: the iTunes Search API answers with
    /// `text/javascript`, so requiring `application/json` failed every search.
    func testAcceptsTheContentTypeITunesActuallySends() throws {
        let results = try AppStoreSearch.results(
            from: body(twoApps), status: 200, contentType: "text/javascript")
        XCTAssertEqual(results.map(\.bundleId),
                       ["org.whispersystems.signal", "ph.telegra.Telegraph"])
        XCTAssertEqual(results[0].artworkUrl60, "https://is1-ssl.mzstatic.com/image/60x60.jpg")
        XCTAssertNil(results[1].artworkUrl60)

        // Case from the header is normalized before the check.
        XCTAssertNoThrow(try AppStoreSearch.results(
            from: body(twoApps), status: 200, contentType: "TEXT/JAVASCRIPT"))
        XCTAssertNoThrow(try AppStoreSearch.results(
            from: body(twoApps), status: 200, contentType: "application/json"))
    }

    func testRejectsNonJSONContentTypesAndErrorStatuses() {
        XCTAssertThrowsError(try AppStoreSearch.results(
            from: body(twoApps), status: 200, contentType: "text/html"))
        XCTAssertThrowsError(try AppStoreSearch.results(
            from: body(twoApps), status: 200, contentType: nil))
        XCTAssertThrowsError(try AppStoreSearch.results(
            from: body(twoApps), status: 503, contentType: "text/javascript"))
        XCTAssertThrowsError(try AppStoreSearch.results(
            from: body("not json"), status: 200, contentType: "text/javascript"))
    }

    /// A real 20-result `entity=software` reply is ~130–190 KB, so the cap has
    /// to sit well above that — an earlier 256 KB cap was one busy term away
    /// from rejecting valid responses.
    func testResponseSizeCapClearsRealWorldResponses() {
        XCTAssertGreaterThanOrEqual(AppStoreSearch.maximumResponseBytes, 1024 * 1024)
        let oversized = Data(count: AppStoreSearch.maximumResponseBytes + 1)
        XCTAssertThrowsError(try AppStoreSearch.results(
            from: oversized, status: 200, contentType: "text/javascript"))
    }

    func testMalformedEntriesAreSkippedRatherThanFailingTheSearch() throws {
        let mixed = """
        {"results":[
          {"trackName":"Good","bundleId":"com.example.good","artworkUrl60":null},
          {"trackName":"Missing bundle id"},
          {"bundleId":"com.example.nameless"},
          {"trackName":"Bad id","bundleId":"nodots","artworkUrl60":null},
          {"trackName":"Dupe","bundleId":"COM.EXAMPLE.GOOD","artworkUrl60":null},
          {"trackName":"Off-host art","bundleId":"com.example.art",
           "artworkUrl60":"https://evil.example.com/60x60.jpg"}
        ]}
        """
        let results = try AppStoreSearch.results(
            from: body(mixed), status: 200, contentType: "text/javascript")
        XCTAssertEqual(results.map(\.bundleId), ["com.example.good", "com.example.art"])
        XCTAssertNil(results[1].artworkUrl60)
    }

    func testEmptyOrShortQueriesNeverReachTheNetwork() async {
        do {
            _ = try await AppStoreSearch.search("   ")
            XCTFail("expected an invalid-query error")
        } catch {
            XCTAssertEqual(error as? AppStoreSearch.SearchError, .invalidQuery)
        }
    }
}
