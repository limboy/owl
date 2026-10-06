import AppKit
import XCTest
@testable import Owl

/// Changes made from a key or the menu bar have nothing on screen showing them
/// while the controls are hidden, so each one says what it did.
@MainActor
final class PlayerNoticeTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlPlayerNoticeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = AppModel(
            folderLibrary: nil,
            progressStore: PlaybackProgressStore(
                storageURL: directory.appendingPathComponent("progress.json")
            )
        )
        try XCTSkipIf(model.engine == nil, "libmpv is not installed")
        model.playerState.currentURL = directory.appendingPathComponent("film.mkv")
    }

    override func tearDown() async throws {
        model?.shutdown()
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// A held key sends its next step before mpv has reported the last one, so
    /// each step has to start from the level the one before it asked for.
    func testVolumeStepsFromTheLevelJustAskedForAndSaysSo() {
        model.playerState.volume = 50

        model.changeVolume(by: 5)
        model.changeVolume(by: 5)

        XCTAssertEqual(model.playerState.volume, 60)
        XCTAssertEqual(model.playerState.notice, .volume(60, isMuted: false))
    }

    func testVolumeStopsAtItsLimits() {
        model.playerState.volume = 98

        model.changeVolume(by: 5)

        XCTAssertEqual(model.playerState.notice, .volume(100, isMuted: false))
    }

    func testSpeedIsClampedAndAnnounced() {
        model.setSpeed(1)
        model.changeSpeed(by: 0.25)
        XCTAssertEqual(model.playerState.notice, .speed(1.25))

        model.setSpeed(10)
        XCTAssertEqual(model.playerState.speed, MPVPlayerEngine.speedRange.upperBound)
    }

    /// Pressing the key twice has to flash the indicator twice, even though
    /// the notice itself is the same both times.
    func testEverySeekAndPositionRequestFlashesTheIndicator() {
        let before = model.playerState.noticeRevision

        model.seek(by: 5)
        model.showPosition()
        model.showPosition()

        XCTAssertEqual(model.playerState.notice, .position)
        XCTAssertEqual(model.playerState.noticeRevision, before + 3)
    }

    /// The clock moves with the jump rather than when mpv reports it, so a
    /// second press goes on from the chapter the first one reached.
    func testMovingBetweenChaptersNamesTheChapterAndMovesTheClock() {
        model.playerState.chapters = [
            Chapter(index: 0, title: "Opening", start: 0),
            Chapter(index: 1, title: "Middle", start: 60),
            Chapter(index: 2, title: "", start: 120),
        ]
        model.playerState.currentTime = 10

        model.playNextChapter()
        XCTAssertEqual(model.playerState.notice, .chapter("Middle"))
        XCTAssertEqual(model.playerState.currentTime, 60)

        model.playNextChapter()
        XCTAssertEqual(model.playerState.notice, .chapter("Chapter 3"))

        let before = model.playerState.noticeRevision
        model.playNextChapter()
        XCTAssertEqual(
            model.playerState.noticeRevision,
            before,
            "there is no chapter after the last, and nothing should say there was"
        )

        model.playPreviousChapter()
        XCTAssertEqual(model.playerState.notice, .chapter("Middle"))
    }

    func testNothingIsAnnouncedWithNothingPlaying() {
        model.playerState.currentURL = nil
        let before = model.playerState.noticeRevision

        model.seek(by: 5)
        model.showPosition()

        XCTAssertEqual(model.playerState.noticeRevision, before)
    }

    /// The speed button and the speed notice draw a gauge whose needle stands
    /// up at normal speed and leans with it either way, to its ends at the
    /// slowest and fastest of the speeds offered.
    func testTheSpeedGaugeLeansWithTheSpeed() {
        let needles = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4].map {
            PlayerContainerView.speedSymbol(speed: $0)
                .replacingOccurrences(of: "gauge.with.dots.needle.", with: "")
        }

        XCTAssertEqual(needles, [
            "0percent", "0percent", "33percent", "50percent",
            "67percent", "67percent", "100percent", "100percent",
        ])
        for symbol in Set(needles) {
            XCTAssertNotNil(
                NSImage(systemSymbolName: "gauge.with.dots.needle.\(symbol)", accessibilityDescription: nil),
                symbol
            )
        }
    }
}
