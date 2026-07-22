import SwiftUI
import XCTest
@testable import Hybridge

final class AdaptiveLayoutTests: XCTestCase {
    func testRegularWidthIPadUsesSidebar() {
        XCTAssertEqual(RootLayout.navigationStyle(isPad: true, horizontalSizeClass: .regular),
                       .sidebar)
    }

    func testCompactWidthIPadUsesFloatingTabBar() {
        XCTAssertEqual(RootLayout.navigationStyle(isPad: true, horizontalSizeClass: .compact),
                       .floatingTabBar)
    }

    func testIPhonePortraitUsesFloatingTabBar() {
        XCTAssertEqual(RootLayout.navigationStyle(isPad: false,
                                                   horizontalSizeClass: .compact,
                                                   verticalSizeClass: .regular),
                       .floatingTabBar)
    }

    func testIPhoneLandscapeUsesFloatingTabBar() {
        XCTAssertEqual(RootLayout.navigationStyle(isPad: false,
                                                   horizontalSizeClass: .compact,
                                                   verticalSizeClass: .compact),
                       .floatingTabBar)
    }

    func testFacesSelectionIsRemovedForHandsOnlyWatch() {
        XCTAssertEqual(RootLayout.normalizedSelection(.faces, hasFaces: false), .watch)
        XCTAssertFalse(RootLayout.tabs(hasFaces: false).contains(.faces))
    }

    func testAvailableSelectionSurvivesCapabilityChange() {
        XCTAssertEqual(RootLayout.normalizedSelection(.fitness, hasFaces: false), .fitness)
    }

    func testEditorUsesSideBySideLayoutForCompactHeightAndWideIPad() {
        XCTAssertTrue(EditorLayout.usesSideBySide(horizontalSizeClass: .compact,
                                                  verticalSizeClass: .compact,
                                                  availableWidth: 667))
        XCTAssertTrue(EditorLayout.usesSideBySide(horizontalSizeClass: .regular,
                                                  verticalSizeClass: .regular,
                                                  availableWidth: 1024))
        XCTAssertFalse(EditorLayout.usesSideBySide(horizontalSizeClass: .compact,
                                                   verticalSizeClass: .regular,
                                                   availableWidth: 500))
    }

    func testEditorPreviewShrinksToPaneAndCapsAt250() {
        XCTAssertEqual(EditorLayout.previewSide(paneSize: CGSize(width: 420, height: 800),
                                                sideBySide: true), 250)
        XCTAssertEqual(EditorLayout.previewSide(paneSize: CGSize(width: 280, height: 300),
                                                sideBySide: true), 196)
    }
}
