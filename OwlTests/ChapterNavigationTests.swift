import XCTest
@testable import Owl

final class ChapterNavigationTests: XCTestCase {
    private let chapters = [
        Chapter(index: 0, title: "Opening", start: 0),
        Chapter(index: 1, title: "", start: 60),
        Chapter(index: 2, title: "Credits", start: 300),
    ]

    func testThePlayheadIsInTheLastChapterThatHasBegun() {
        XCTAssertEqual(ChapterNavigation.chapter(at: 0, in: chapters)?.index, 0)
        XCTAssertEqual(ChapterNavigation.chapter(at: 120, in: chapters)?.index, 1)
        XCTAssertEqual(ChapterNavigation.chapter(at: 400, in: chapters)?.index, 2)
        XCTAssertNil(ChapterNavigation.chapter(at: 10, in: []))
    }

    /// A seek lands a frame either side of the mark it was aimed at, and has
    /// to count as being in that chapter rather than the one before.
    func testASeekThatLandsJustShortOfAChapterIsInIt() {
        XCTAssertEqual(ChapterNavigation.chapter(at: 59.9, in: chapters)?.index, 1)
        XCTAssertEqual(ChapterNavigation.next(after: 59.9, in: chapters)?.index, 2)
    }

    /// mpv's own `add chapter` steps past the last chapter into the end of the
    /// file, which with the queue advancing is the next video.
    func testNextStopsAtTheLastChapter() {
        XCTAssertEqual(ChapterNavigation.next(after: 10, in: chapters)?.index, 1)
        XCTAssertNil(ChapterNavigation.next(after: 310, in: chapters))
    }

    func testPreviousRestartsAChapterWellUnderwayAndOtherwiseGoesBackOne() {
        XCTAssertEqual(ChapterNavigation.previous(from: 120, in: chapters)?.index, 1)
        XCTAssertEqual(ChapterNavigation.previous(from: 61, in: chapters)?.index, 0)
        XCTAssertNil(ChapterNavigation.previous(from: 1, in: chapters))
    }

    func testAChapterWithNoTitleIsNamedByItsNumber() {
        XCTAssertEqual(chapters[1].displayName, "Chapter 2")
        XCTAssertEqual(chapters[2].displayName, "Credits")
    }
}
