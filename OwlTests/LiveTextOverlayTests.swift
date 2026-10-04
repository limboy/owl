import AppKit
import XCTest
@testable import Owl

@MainActor
final class LiveTextOverlayTests: XCTestCase {
    /// The overlay covers the whole picture. Until it has found text to offer
    /// it must be invisible to the pointer, or it would sit between the player
    /// and every click and drop aimed at the picture.
    func testWithNothingReadTheOverlayLetsThePointerThrough() {
        let overlay = LiveTextOverlayView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))

        XCTAssertNil(overlay.hitTest(NSPoint(x: 160, y: 90)))
    }
}
