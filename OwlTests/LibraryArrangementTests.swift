import XCTest
@testable import Owl

/// What the browser shows of a folder: narrowed by a search over the file
/// name and the catalogue's title, and ordered by name, date added or when it
/// was last watched — with folders ahead of videos throughout.
final class LibraryArrangementTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func video(_ name: String, addedDaysAgo: Double? = nil) -> BrowserEntry {
        BrowserEntry(
            url: URL(fileURLWithPath: "/Movies/\(name)"),
            kind: .video,
            dateAdded: addedDaysAgo.map { now.addingTimeInterval(-$0 * day) }
        )
    }

    private func folder(_ name: String, addedDaysAgo: Double? = nil) -> BrowserEntry {
        BrowserEntry(
            url: URL(fileURLWithPath: "/Movies/\(name)", isDirectory: true),
            kind: .folder,
            dateAdded: addedDaysAgo.map { now.addingTimeInterval(-$0 * day) }
        )
    }

    private func arrange(
        _ entries: [BrowserEntry],
        _ query: String = "",
        by order: LibrarySortOrder = .name,
        titles: [String: String] = [:],
        watchedDaysAgo: [String: Double] = [:]
    ) -> [String] {
        LibraryArrangement.arrange(
            entries,
            matching: query,
            by: order,
            title: { titles[$0.name] ?? $0.name },
            lastWatched: { entry in
                watchedDaysAgo[entry.name].map { self.now.addingTimeInterval(-$0 * self.day) }
            }
        ).map(\.name)
    }

    func testNameOrderCountsNumbersAsNumbersAndKeepsFoldersFirst() {
        let entries = [video("Episode 10.mkv"), video("Episode 2.mkv"), folder("Extras"), video("Episode 1.mkv")]

        XCTAssertEqual(
            arrange(entries),
            ["Extras", "Episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv"]
        )
    }

    /// The card shows the catalogue's title, so that is the name it is filed
    /// under.
    func testNameOrderUsesTheTitleTheCardShows() {
        let entries = [video("a.mkv"), video("b.mkv")]

        XCTAssertEqual(
            arrange(entries, titles: ["a.mkv": "Zodiac", "b.mkv": "Alien"]),
            ["b.mkv", "a.mkv"]
        )
    }

    func testSearchMatchesTheFileNameOrTheTitleIgnoringCaseAndAccents() {
        let entries = [
            video("Amelie.2001.1080p.mkv"),
            video("tt0211915.mkv"),
            video("Heat.1995.mkv"),
        ]
        let titles = ["tt0211915.mkv": "Le Fabuleux Destin d’Amélie Poulain"]

        XCTAssertEqual(arrange(entries, "amélie", titles: titles), ["Amelie.2001.1080p.mkv", "tt0211915.mkv"])
        XCTAssertEqual(arrange(entries, "FABULEUX", titles: titles), ["tt0211915.mkv"])
        XCTAssertEqual(arrange(entries, "1995", titles: titles), ["Heat.1995.mkv"])
    }

    /// Every word has to match, though not next to each other and not all in
    /// the same name.
    func testEveryWordOfTheSearchHasToMatch() {
        let entries = [video("Mad.Men.S01E01.mkv"), video("Mad.Men.S02E01.mkv"), video("Madagascar.mkv")]
        let titles = ["Mad.Men.S01E01.mkv": "Mad Men · S1E1 · Smoke Gets in Your Eyes"]

        XCTAssertEqual(arrange(entries, "mad smoke", titles: titles), ["Mad.Men.S01E01.mkv"])
        XCTAssertEqual(arrange(entries, "  mad   men ", titles: titles), ["Mad.Men.S01E01.mkv", "Mad.Men.S02E01.mkv"])
        XCTAssertEqual(arrange(entries, "   "), ["Mad.Men.S01E01.mkv", "Mad.Men.S02E01.mkv", "Madagascar.mkv"])
    }

    func testFoldersAreSearchedToo() {
        let entries = [folder("Mad Men"), folder("The Wire"), video("Mad Max.mkv")]

        XCTAssertEqual(arrange(entries, "mad"), ["Mad Men", "Mad Max.mkv"])
    }

    func testDateAddedPutsTheNewestFirstAndTheUndatedLast() {
        let entries = [
            video("Old.mkv", addedDaysAgo: 30),
            video("Undated.mkv"),
            video("New.mkv", addedDaysAgo: 1),
            folder("Season 2", addedDaysAgo: 2),
            folder("Season 1", addedDaysAgo: 90),
        ]

        XCTAssertEqual(
            arrange(entries, by: .dateAdded),
            ["Season 2", "Season 1", "New.mkv", "Old.mkv", "Undated.mkv"]
        )
    }

    /// Anything never watched follows everything that has been, by name.
    func testRecentlyWatchedPutsTheLatestFirstAndTheUnwatchedAfterByName() {
        let entries = [
            video("C.mkv"),
            video("A.mkv", addedDaysAgo: 1),
            video("B.mkv"),
            video("D.mkv"),
            folder("Show"),
        ]

        XCTAssertEqual(
            arrange(entries, by: .recentlyWatched, watchedDaysAgo: ["D.mkv": 5, "B.mkv": 1]),
            ["Show", "B.mkv", "D.mkv", "A.mkv", "C.mkv"]
        )
    }
}
