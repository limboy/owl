import XCTest
@testable import Owl

@MainActor
final class PlaybackQueueTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/owl-tests")

    func testNormalQueueStopsAtEndWhenRepeatIsOff() {
        let queue = PlaybackQueue()
        let videos = makeVideos(["A.mp4", "B.mkv", "C.webm"])
        queue.select(videos[0], from: videos)

        XCTAssertEqual(queue.next(automatic: true), videos[1])
        XCTAssertEqual(queue.next(automatic: true), videos[2])
        XCTAssertNil(queue.next(automatic: true))
    }

    func testRepeatAllWrapsToFirstVideo() {
        let queue = PlaybackQueue()
        let videos = makeVideos(["A.mp4", "B.mkv"])
        queue.select(videos[1], from: videos)
        queue.repeatMode = .all

        XCTAssertEqual(queue.next(automatic: true), videos[0])
    }

    func testRepeatOneKeepsCurrentVideo() {
        let queue = PlaybackQueue()
        let videos = makeVideos(["A.mp4", "B.mkv"])
        queue.select(videos[0], from: videos)
        queue.repeatMode = .one

        XCTAssertEqual(queue.next(automatic: true), videos[0])
        XCTAssertEqual(queue.next(), videos[1], "Manual Next should still advance.")
    }

    func testJumpKeepsShuffledOrder() {
        let queue = PlaybackQueue(shuffleProvider: { Array($0.reversed()) })
        let videos = makeVideos(["A.mp4", "B.mkv", "C.webm", "D.avi"])
        queue.select(videos[0], from: videos)
        queue.isShuffled = true

        XCTAssertTrue(queue.jump(to: videos[2]))
        XCTAssertEqual(queue.current, videos[2])
        XCTAssertEqual(queue.next(), videos[1])
        XCTAssertFalse(queue.jump(to: folder.appendingPathComponent("E.mp4")))
        XCTAssertEqual(queue.current, videos[1])
    }

    func testShuffleUsesInjectedOrderAndAddsNewVideos() {
        let queue = PlaybackQueue(shuffleProvider: { Array($0.reversed()) })
        let videos = makeVideos(["A.mp4", "B.mkv", "C.webm"])
        queue.select(videos[0], from: videos)
        queue.isShuffled = true

        XCTAssertEqual(queue.next(), videos[2])

        let newVideo = folder.appendingPathComponent("D.avi")
        queue.updateVideos(videos + [newVideo])
        XCTAssertEqual(queue.next(), videos[1])
        XCTAssertEqual(queue.next(), newVideo)
    }

    func testClearRemovesCurrentVideoAndQueue() {
        let queue = PlaybackQueue()
        let videos = makeVideos(["A.mp4", "B.mkv"])
        queue.select(videos[0], from: videos)

        queue.clear()

        XCTAssertTrue(queue.videos.isEmpty)
        XCTAssertNil(queue.current)
        XCTAssertNil(queue.next())
    }

    private func makeVideos(_ names: [String]) -> [URL] {
        names.map(folder.appendingPathComponent)
    }
}
