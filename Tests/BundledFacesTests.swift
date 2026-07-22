import XCTest
@testable import Hybridge

/// Guards Resources/bundled_faces: every .wapp shipped there must parse as
/// a valid watchface, or the "Bundled" section would try to install a
/// broken file on real hardware. Passes trivially while the folder is empty.
final class BundledFacesTests: XCTestCase {
    func testEveryBundledWappParsesAsAWatchface() throws {
        let urls = Bundle.main.urls(forResourcesWithExtension: "wapp", subdirectory: "bundled_faces") ?? []
        for url in urls {
            let wapp = try Data(contentsOf: url)
            XCTAssertEqual(wapp.u16LE(at: 0), FossilFileHandle.appCode.rawValue,
                            "\(url.lastPathComponent): bad .wapp header")
            let meta = try XCTUnwrap(WappReader.metadata(fromWapp: wapp),
                                     "\(url.lastPathComponent): could not read .wapp header")
            XCTAssertTrue(meta.isWatchface, "\(url.lastPathComponent): not a watchface")
        }
    }

    /// The list subtitle comes from a "description" entry in the wapp's
    /// displayName section (written by faces/build.py out of app.json). Our
    /// own bundled faces must all carry one, or the row reads as a bare name.
    func testEveryBundledWappCarriesADescription() throws {
        let urls = Bundle.main.urls(forResourcesWithExtension: "wapp", subdirectory: "bundled_faces") ?? []
        for url in urls {
            let wapp = try Data(contentsOf: url)
            XCTAssertNotNil(WappReader.description(fromWapp: wapp),
                            "\(url.lastPathComponent): no description entry")
        }
    }

    /// `BundledFaces.matching(name:)` is how the dashboard hero finds a local
    /// image for the active watchface offline — it must resolve a real
    /// bundled name to that face's thumbnail and reject an unknown one.
    func testMatchingResolvesKnownNameAndRejectsUnknown() throws {
        let known = try XCTUnwrap(BundledFaces.all.first)
        let match = try XCTUnwrap(BundledFaces.matching(name: known.name))
        XCTAssertEqual(match.id, known.id)
        XCTAssertNotNil(match.thumbnail)

        XCTAssertNil(BundledFaces.matching(name: "not-a-real-face-name"))
        XCTAssertNil(BundledFaces.matching(name: nil))
    }
}
