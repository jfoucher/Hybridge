import XCTest
@testable import Hybridge

/// Covers the on-disk app cache (`UploadedAppStore`) that lets a watch switch
/// re-upload an app it never had, plus the pure resolver that decides which
/// app names the global button/menu config references.
final class UploadedAppStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-apps-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - UploadedAppStore

    func testRememberAndDataRoundTrip() {
        let store = UploadedAppStore(directory: directory)
        let bytes = Data("fake wapp bytes".utf8)

        store.remember(name: "homeAssistantApp", wapp: bytes)

        XCTAssertEqual(store.data(forName: "homeAssistantApp"), bytes)
        XCTAssertEqual(store.names, ["homeAssistantApp"])
    }

    func testDataForUncachedNameIsNil() {
        let store = UploadedAppStore(directory: directory)
        XCTAssertNil(store.data(forName: "neverUploaded"))
    }

    func testRememberOverwritesPreviousBytesForSameName() {
        let store = UploadedAppStore(directory: directory)
        store.remember(name: "timerApp", wapp: Data("first".utf8))
        store.remember(name: "timerApp", wapp: Data("second".utf8))

        XCTAssertEqual(store.data(forName: "timerApp"), Data("second".utf8))
        XCTAssertEqual(store.names, ["timerApp"], "must not accumulate duplicate records")
    }

    func testForgetRemovesRecordAndBlob() {
        let store = UploadedAppStore(directory: directory)
        store.remember(name: "commuteApp", wapp: Data("bytes".utf8))
        XCTAssertNotNil(store.data(forName: "commuteApp"))

        store.forget(name: "commuteApp")

        XCTAssertNil(store.data(forName: "commuteApp"))
        XCTAssertTrue(store.names.isEmpty)
    }

    func testCachePersistsAcrossStoreInstances() {
        UploadedAppStore(directory: directory).remember(name: "musicApp", wapp: Data("bytes".utf8))

        let reloaded = UploadedAppStore(directory: directory)
        XCTAssertEqual(reloaded.data(forName: "musicApp"), Data("bytes".utf8))
    }

    func testCorruptPrimaryIndexRecoversLastVerifiedIndex() throws {
        let bytes = Data("durable bytes".utf8)
        XCTAssertTrue(UploadedAppStore(directory: directory)
            .remember(name: "homeAssistantApp", wapp: bytes))
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("index.json"))

        let recovered = UploadedAppStore(directory: directory)
        XCTAssertEqual(recovered.names, ["homeAssistantApp"])
        XCTAssertEqual(recovered.data(forName: "homeAssistantApp"), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix("index.corrupt-") })
    }

    // MARK: - ButtonConfig.referencedAppNames

    private func selection(_ appName: String) -> ButtonSelection {
        ButtonSelection(button: .top, press: .short, appName: appName)
    }

    func testReferencedAppNamesCollectsButtonApps() {
        let names = ButtonConfig.referencedAppNames(
            buttonSelections: [selection("homeAssistantApp"), selection("weatherApp")])

        XCTAssertEqual(names, ["homeAssistantApp", "weatherApp"])
    }

    func testReferencedAppNamesFiltersEmptyNames() {
        let names = ButtonConfig.referencedAppNames(
            buttonSelections: [selection("")])

        XCTAssertTrue(names.isEmpty)
    }

    func testReferencedAppNamesDeduplicates() {
        let names = ButtonConfig.referencedAppNames(
            buttonSelections: [selection("homeAssistantApp"), selection("homeAssistantApp")])

        XCTAssertEqual(names, ["homeAssistantApp"])
    }
}
