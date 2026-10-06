import XCTest
@testable import Owl

/// The bar along the bottom of a video's card says where the video stands in
/// one symbol and one span of time.
final class CardPlaybackStateTests: XCTestCase {
    private func progress(position: Double, duration: Double, completed: Bool = false) -> PlaybackProgress {
        PlaybackProgress(
            url: URL(fileURLWithPath: "/Videos/Episode.mkv"),
            position: position,
            duration: duration,
            lastPlayed: Date(),
            isCompleted: completed
        )
    }

    func testAnUnstartedVideoShowsItsLength() {
        let state = CardPlaybackState(progress: nil, duration: 48 * 60 + 39)
        XCTAssertEqual(state.kind, .unstarted)
        XCTAssertEqual(state.timeText, "49m")
    }

    func testAVideoPartwayThroughShowsTheTimeLeft() {
        let state = CardPlaybackState(progress: progress(position: 27 * 60, duration: 48 * 60), duration: nil)
        XCTAssertEqual(state.kind, .inProgress(fraction: 27.0 / 48.0))
        XCTAssertEqual(state.timeText, "21m")
    }

    func testAWatchedVideoShowsItsLength() {
        let state = CardPlaybackState(
            progress: progress(position: 29 * 60, duration: 29 * 60, completed: true),
            duration: nil
        )
        XCTAssertEqual(state.kind, .watched)
        XCTAssertEqual(state.timeText, "29m")
    }

    /// A video marked watched without being played has no length of its own
    /// in its progress, and falls back on the library's.
    func testAVideoMarkedWatchedUnplayedTakesTheLibrarysLength() {
        let state = CardPlaybackState(
            progress: progress(position: 0, duration: 0, completed: true),
            duration: 45 * 60
        )
        XCTAssertEqual(state.timeText, "45m")
    }

    func testSpansAreWrittenShort() {
        XCTAssertEqual(CardPlaybackState.shortText(20), "<1m")
        XCTAssertEqual(CardPlaybackState.shortText(65 * 60), "1h 5m")
        XCTAssertEqual(CardPlaybackState.shortText(2 * 3600), "2h")
        XCTAssertNil(CardPlaybackState.shortText(0))
        XCTAssertNil(CardPlaybackState.shortText(.nan))
    }
}
