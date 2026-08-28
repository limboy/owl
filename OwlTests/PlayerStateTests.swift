import XCTest
@testable import Owl

@MainActor
final class PlayerStateTests: XCTestCase {
    private let video = URL(fileURLWithPath: "/tmp/owl-tests/A.mp4")

    func testTheTitleIsTheFileNameWithoutItsExtension() {
        let state = PlayerState()
        XCTAssertNil(state.currentTitle, "nothing is playing")

        state.resetForLoad(URL(fileURLWithPath: "/tmp/owl-tests/Mad Men - S04E11.mkv"))

        XCTAssertEqual(state.currentTitle, "Mad Men - S04E11")
    }

    func testResetForLoadClearsThePausedFlag() {
        let state = PlayerState()
        state.reset()

        state.resetForLoad(video)

        // Closing a video leaves isPaused == true while mpv itself stays
        // unpaused, so loading the next file has to clear the flag; mpv sends
        // no `pause` event when the property does not actually change.
        XCTAssertFalse(state.isPaused)
    }

    func testResetForLoadClearsPlaybackPosition() {
        let state = PlayerState()
        state.currentTime = 42
        state.duration = 120

        state.resetForLoad(video)

        XCTAssertEqual(state.currentURL, video)
        XCTAssertEqual(state.currentTime, 0)
        XCTAssertEqual(state.duration, 0)
        XCTAssertTrue(state.isLoading)
    }

    func testUnlabelledAudioTracksFallBackToTheirIdentifier() {
        // A file can carry several audio tracks with no title, language, or
        // codec between them. Without the identifier every entry in the menu
        // reads the same and there is no way to tell them apart.
        let tracks = [Int64(1), Int64(2)].map { id in
            AudioTrack(
                id: id,
                title: "",
                language: nil,
                codec: nil,
                isExternal: false,
                isSelected: false
            )
        }

        XCTAssertEqual(tracks.map(\.displayName), ["Audio 1", "Audio 2"])
    }
}
