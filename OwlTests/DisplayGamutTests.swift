import AppKit
import XCTest
@testable import Owl

/// mpv is told which gamut the screen shows, by name, so that it maps the
/// picture into it. These check the names a screen's colour space comes out as.
final class DisplayGamutTests: XCTestCase {
    func testTheStandardGamutsAreRecognised() {
        XCTAssertEqual(DisplayGamut.mpvPrimaries(for: .sRGB), "bt.709")
        XCTAssertEqual(DisplayGamut.mpvPrimaries(for: .displayP3), "display-p3")
        XCTAssertEqual(DisplayGamut.mpvPrimaries(for: .adobeRGB1998), "adobe")
        XCTAssertEqual(DisplayGamut.mpvPrimaries(for: space(CGColorSpace.itur_2020)), "bt.2020")
    }

    /// A Mac's built-in panel reports a profile of its own rather than the
    /// standard Display P3, and it still has to be taken for P3.
    func testAScreensOwnProfileIsMatchedToTheGamutItIsNearest() throws {
        let screen = try XCTUnwrap(NSScreen.main?.colorSpace)
        XCTAssertNotNil(
            DisplayGamut.mpvPrimaries(for: screen),
            "\(screen.localizedName ?? "this screen") matched no gamut"
        )
    }

    func testNothingIsClaimedForAColourSpaceThatIsNotRGB() {
        XCTAssertNil(DisplayGamut.mpvPrimaries(for: .genericGray))
        XCTAssertNil(DisplayGamut.mpvPrimaries(for: nil))
    }

    private func space(_ name: CFString) -> NSColorSpace? {
        CGColorSpace(name: name).flatMap(NSColorSpace.init(cgColorSpace:))
    }
}
