import XCTest
@testable import Hybridge

/// `SharedWatchfacePackage` is the .hbface export/import format (see
/// SharedWatchfacePackage.swift) — a compiled .wapp plus its editable
/// WatchfaceDesign, traded between Hybridge users via Files/AirDrop/Messages.
/// These are pure Codable-format tests; no BLE/watch hardware involved.
final class SharedWatchfacePackageTests: XCTestCase {
    func testRoundTripPreservesDesignAndCompiledWapp() throws {
        var design = WatchfaceDesign(name: "Test Face")
        design.widgets = [WatchfaceWidget(type: "widgetSteps", x: 120, y: 182, color: 0,
                                          background: "widget_bg_thin_circle", goalRing: true)]
        design.textLayers = [WatchfaceTextLayer(text: "Hi", x: 40, y: 40)]
        let wapp = Data([0xAA, 0xBB, 0xCC, 0x01, 0x02])
        let package = SharedWatchfacePackage(design: design, compiledWapp: wapp, sourceAppVersion: "1.0.0")

        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(SharedWatchfacePackage.self, from: data)

        XCTAssertEqual(decoded.design, design)
        XCTAssertEqual(decoded.compiledWapp, wapp)
        XCTAssertEqual(decoded.sourceAppVersion, "1.0.0")
        XCTAssertEqual(decoded.formatVersion, 1)
    }

    func testDecodingGarbageOrTruncatedDataThrowsAndNeverTraps() {
        let inputs: [Data] = [
            Data(),
            Data([0x00, 0x01, 0x02, 0x03]),
            "{\"not\": \"a package\"}".data(using: .utf8)!,
            "{\"formatVersion\": 1, \"design\": {}}".data(using: .utf8)!,
        ]
        for input in inputs {
            XCTAssertThrowsError(try JSONDecoder().decode(SharedWatchfacePackage.self, from: input))
            // The validating path used by every import must reject the same
            // inputs, and by throwing rather than trapping.
            XCTAssertThrowsError(try SharedWatchfacePackage.decode(input))
        }
    }

    /// A design saved before `contrast`/`textLayers` existed must still
    /// import — exercises the same lenient `decodeIfPresent` init that lets
    /// `WatchfaceStore` load pre-upgrade designs.
    func testImportsAPackageWrappingAnOldFormatDesign() throws {
        let legacyDesignJSON = """
        {"id": "\(UUID().uuidString)", "name": "Old Face", "widgets": []}
        """
        let packageJSON = """
        {"formatVersion": 1, "design": \(legacyDesignJSON), "compiledWapp": "qg=="}
        """
        let decoded = try JSONDecoder().decode(SharedWatchfacePackage.self,
                                               from: packageJSON.data(using: .utf8)!)
        XCTAssertEqual(decoded.design.name, "Old Face")
        XCTAssertEqual(decoded.design.textLayers, [])
        XCTAssertNil(decoded.design.contrast)
        XCTAssertNil(decoded.sourceAppVersion)
    }

    // MARK: The validating decode

    /// The importing device rebuilds the face from the design, so the carried
    /// .wapp is only ever an integrity gate — but it has to actually gate.
    /// Bytes that aren't a valid watchface container must be refused before
    /// anything is added to the user's designs.
    func testDecodeRejectsAPackageWhoseWappIsNotAWatchface() throws {
        var design = WatchfaceDesign(name: "Bogus")
        design.widgets = []
        let package = SharedWatchfacePackage(design: design,
                                             compiledWapp: Data(repeating: 0xAB, count: 512),
                                             sourceAppVersion: "1.0.0")
        let data = try package.encoded()
        XCTAssertFalse(WappReader.isValidContainer(package.compiledWapp))
        XCTAssertThrowsError(try SharedWatchfacePackage.decode(data)) { error in
            XCTAssertEqual(error as? SharedWatchfaceError, .notAWatchface)
        }
    }

    /// Forward compatibility is a refusal, not a best-effort parse: a package
    /// from a future build may mean fields this version would silently drop.
    func testDecodeRejectsANewerFormatVersion() throws {
        let json = """
        {"formatVersion": \(SharedWatchfacePackage.currentFormatVersion + 1),
         "design": {"id": "\(UUID().uuidString)", "name": "Future", "widgets": []},
         "compiledWapp": "qg=="}
        """
        XCTAssertThrowsError(
            try SharedWatchfacePackage.decode(json.data(using: .utf8)!)
        ) { error in
            XCTAssertEqual(error as? SharedWatchfaceError, .newerFormat)
        }
    }

    /// The size ceiling is checked before the JSON is parsed, so a hostile
    /// file can't make the importer allocate its way through a decode first.
    func testDecodeRejectsAnOversizePackage() {
        let oversize = Data(repeating: 0x20, count: SharedWatchfacePackage.maxPackageBytes + 1)
        XCTAssertThrowsError(try SharedWatchfacePackage.decode(oversize)) { error in
            XCTAssertEqual(error as? SharedWatchfaceError, .tooLarge)
        }
    }

    // MARK: Naming

    /// Importing never overwrites a design the user already has, so the same
    /// file opened twice has to land beside its first copy, not on top of it.
    func testUniqueNameDisambiguatesAgainstExistingDesigns() {
        XCTAssertEqual(SharedWatchfacePackage.uniqueName("Aurora", existing: []), "Aurora")
        XCTAssertEqual(SharedWatchfacePackage.uniqueName("Aurora", existing: ["Aurora"]),
                       "Aurora 2")
        XCTAssertEqual(SharedWatchfacePackage.uniqueName("Aurora", existing: ["Aurora", "Aurora 2"]),
                       "Aurora 3")
        XCTAssertEqual(SharedWatchfacePackage.uniqueName("  Aurora  ", existing: []), "Aurora")
        XCTAssertFalse(SharedWatchfacePackage.uniqueName("", existing: []).isEmpty)
        XCTAssertLessThanOrEqual(
            SharedWatchfacePackage.uniqueName(String(repeating: "x", count: 500), existing: []).count,
            SharedWatchfacePackage.maxNameLength)
    }
}
