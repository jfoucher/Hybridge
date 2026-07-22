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

    // MARK: - ButtonConfig.referencedAppNames

    private func selection(_ appName: String) -> ButtonSelection {
        ButtonSelection(button: .top, press: .short, appName: appName)
    }

    private func openAppMenuItem(_ appName: String) -> WatchMenuItem {
        var item = WatchMenuItem()
        item.kind = .openApp
        item.text = appName
        return item
    }

    func testReferencedAppNamesUnionsButtonsAndMenu() {
        let names = ButtonConfig.referencedAppNames(
            buttonSelections: [selection("homeAssistantApp"), selection("weatherApp")],
            menuItems: [openAppMenuItem("timerApp")])

        XCTAssertEqual(names, ["homeAssistantApp", "weatherApp", "timerApp"])
    }

    func testReferencedAppNamesFiltersEmptyNames() {
        let names = ButtonConfig.referencedAppNames(
            buttonSelections: [selection("")],
            menuItems: [openAppMenuItem("")])

        XCTAssertTrue(names.isEmpty)
    }

    func testReferencedAppNamesIgnoresNonOpenAppMenuItems() {
        var showMessage = WatchMenuItem()
        showMessage.kind = .showMessage
        showMessage.text = "notAnApp"
        var sendToPhone = WatchMenuItem()
        sendToPhone.kind = .sendToPhone
        sendToPhone.text = "alsoNotAnApp"

        let names = ButtonConfig.referencedAppNames(
            buttonSelections: [],
            menuItems: [showMessage, sendToPhone])

        XCTAssertTrue(names.isEmpty)
    }

    func testReferencedAppNamesDeduplicatesAcrossButtonsAndMenu() {
        let names = ButtonConfig.referencedAppNames(
            buttonSelections: [selection("homeAssistantApp")],
            menuItems: [openAppMenuItem("homeAssistantApp")])

        XCTAssertEqual(names, ["homeAssistantApp"])
    }
}
