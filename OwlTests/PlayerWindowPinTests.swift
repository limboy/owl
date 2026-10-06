import AppKit
import SwiftUI
import XCTest
@testable import Owl

@MainActor
final class PlayerWindowPinTests: XCTestCase {
    /// The pin keeps the window above other apps' windows until it is
    /// unpinned, and sits in the title bar, which fades with the controls.
    func testThePinKeepsTheWindowOnTopAndSitsInTheTitleBar() {
        let appModel = AppModel(folderLibrary: nil)
        let controller = PlayerWindowController(
            appModel: appModel,
            ownership: .owned,
            frameAutosaveName: "PlayerWindowPinTests",
            rootView: Color.black
        ) {}
        defer { controller.close() }
        let window = controller.window

        XCTAssertFalse(controller.isPinned)
        XCTAssertEqual(window.level, .normal)

        controller.togglePin()
        XCTAssertTrue(controller.isPinned)
        XCTAssertEqual(window.level, .floating)

        controller.togglePin()
        XCTAssertEqual(window.level, .normal)

        let titleBar = window.standardWindowButton(.closeButton)?.superview?.superview
        XCTAssertNotNil(titleBar)
        XCTAssertTrue(controller.pinButton.isDescendant(of: titleBar!))
    }
}
