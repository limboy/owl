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

    func testNothingIsAnnouncedWithNothingPlaying() {
        model.playerState.currentURL = nil
        let before = model.playerState.noticeRevision

        model.seek(by: 5)
        model.showPosition()

        XCTAssertEqual(model.playerState.noticeRevision, before)
    }
}
