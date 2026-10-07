import XCTest
@testable import Owl

/// A screenshot lands beside the system's own, named for the video and the
/// moment in it, and never on top of one already there.
final class ScreenshotTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/Shots", isDirectory: true)
    private let video = URL(fileURLWithPath: "/Movies/Smoke Gets in Your Eyes.mkv")

    func testNamedForTheVideoAndTheMomentInIt() {
        let url = Screenshot.fileURL(for: video, at: 754.9, in: folder) { _ in false }

        XCTAssertEqual(url.lastPathComponent, "Smoke Gets in Your Eyes 0.12.34.png")
        XCTAssertEqual(url.deletingLastPathComponent().path, folder.path)
    }

    func testHoursAreCountedPastTheFirst() {
        XCTAssertEqual(Screenshot.timestamp(3 * 3_600 + 5 * 60 + 7), "3.05.07")
        XCTAssertEqual(Screenshot.timestamp(-1), "0.00.00")
        XCTAssertEqual(Screenshot.timestamp(.nan), "0.00.00")
    }

    func testASecondStillOfTheSameFrameIsNumbered() {
        let taken: Set<String> = [
            "Smoke Gets in Your Eyes 0.00.10.png",
            "Smoke Gets in Your Eyes 0.00.10 2.png",
        ]
        let url = Screenshot.fileURL(for: video, at: 10, in: folder) {
            taken.contains($0.lastPathComponent)
        }

        XCTAssertEqual(url.lastPathComponent, "Smoke Gets in Your Eyes 0.00.10 3.png")
    }

    func testTheSystemsScreenshotFolderIsUsedWhenItExists() throws {
        let suite = "OwlScreenshotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chosen = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlScreenshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chosen) }

        defaults.set(chosen.path, forKey: "location")
        XCTAssertEqual(
            Screenshot.folder(screencaptureDefaults: defaults).standardizedFileURL.path,
            chosen.standardizedFileURL.path
        )

        defaults.set("/no/such/folder", forKey: "location")
        XCTAssertEqual(
            Screenshot.folder(screencaptureDefaults: defaults).lastPathComponent,
            "Desktop"
        )
    }
}
