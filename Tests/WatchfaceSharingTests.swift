import XCTest
@testable import Hybridge

/// End-to-end cover for the `.hbface` file itself: a design goes out through
/// `exportTemporaryFile` (which really runs `WappBuilder`, against the bundled
/// `fossil_hr` assets) and comes back through `importDesign`. The format tests
/// live in SharedWatchfacePackageTests; this is the part that would break if
/// the build, the encode or the file handling regressed.
final class WatchfaceSharingTests: XCTestCase {
    private var exported: URL?

    override func tearDown() {
        if let exported { try? FileManager.default.removeItem(at: exported) }
        exported = nil
        super.tearDown()
    }

    private func sampleDesign(name: String = "Aurora") -> WatchfaceDesign {
        var design = WatchfaceDesign(name: name)
        design.widgets = [
            WatchfaceWidget(type: "widgetSteps", x: 120, y: 182, color: 0,
                            background: "widget_bg_thin_circle", goalRing: true),
            WatchfaceWidget(type: "widgetDate", x: 120, y: 58, color: 0, background: ""),
        ]
        design.textLayers = [
            WatchfaceTextLayer(text: "Hi", x: 40, y: 40, fontSize: 18, shade: 3),
        ]
        return design
    }

    func testExportedFileImportsBackToAnEquivalentDesign() async throws {
        let design = sampleDesign()
        let url = try await WatchfaceSharing.exportTemporaryFile(for: design)
        exported = url

        XCTAssertEqual(url.pathExtension, WatchfaceSharing.fileExtension)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let imported = try WatchfaceSharing.importDesign(from: url, existing: [])
        XCTAssertEqual(imported.name, design.name)
        XCTAssertEqual(imported.widgets.map(\.type), design.widgets.map(\.type))
        XCTAssertEqual(imported.textLayers.map(\.text), design.textLayers.map(\.text))
        // A shared face must be a *new* face on the receiving phone, never an
        // overwrite of whatever happens to share its identifier.
        XCTAssertNotEqual(imported.id, design.id)
    }

    /// The carried `.wapp` is the integrity gate the importer checks, so the
    /// exporter has to put a real, valid watchface container in there.
    func testExportedPackageCarriesAValidWatchfaceContainer() async throws {
        let design = sampleDesign(name: "Meridian Test")
        let url = try await WatchfaceSharing.exportTemporaryFile(for: design)
        exported = url

        let package = try SharedWatchfacePackage.decode(Data(contentsOf: url))
        XCTAssertEqual(package.formatVersion, SharedWatchfacePackage.currentFormatVersion)
        XCTAssertNotNil(package.sourceAppVersion)
        XCTAssertTrue(WappReader.isValidContainer(package.compiledWapp))
        XCTAssertEqual(WappReader.metadata(fromWapp: package.compiledWapp)?.name,
                       design.sanitizedName)
    }

    /// Importing the same file twice is the ordinary case (someone re-opens
    /// the message), and must leave the first copy alone.
    func testReimportingTheSameFileDisambiguatesTheName() async throws {
        let design = sampleDesign()
        let url = try await WatchfaceSharing.exportTemporaryFile(for: design)
        exported = url

        let first = try WatchfaceSharing.importDesign(from: url, existing: [])
        let second = try WatchfaceSharing.importDesign(from: url, existing: [first])
        XCTAssertEqual(first.name, "Aurora")
        XCTAssertEqual(second.name, "Aurora 2")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testImportingSomethingThatIsNotAPackageThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-face.\(WatchfaceSharing.fileExtension)")
        try Data("hello".utf8).write(to: url)
        exported = url
        XCTAssertThrowsError(try WatchfaceSharing.importDesign(from: url, existing: [])) { error in
            XCTAssertEqual(error as? SharedWatchfaceError, .notAPackage)
        }
    }

    func testImportingAMissingFileThrowsRatherThanTraps() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).hbface")
        XCTAssertThrowsError(try WatchfaceSharing.importDesign(from: url, existing: []))
    }
}
