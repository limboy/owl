import XCTest
@testable import Owl

@MainActor
final class RecentFilesTests: XCTestCase {
    func testRecentFilesAreOrderedDeduplicatedAndRestoredByTheSystemStore() {
        let controller = RecentDocumentStub()
        let files = RecentFiles(controller: controller)
        let first = URL(fileURLWithPath: "/tmp/first.mkv")
        let second = URL(fileURLWithPath: "/tmp/second.mkv")
        files.record(first)
        files.record(second)
        files.record(URL(fileURLWithPath: "/tmp/other/../first.mkv"))
        XCTAssertEqual(files.urls, [first, second])
        XCTAssertEqual(RecentFiles(controller: controller).urls, files.urls)
    }

    func testMigrationExcludesFolderPlaybackAndClearDoesNotReimportHistory() throws {
        let suite = "OwlRecentFilesTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecentDocumentStub()
        let old = progress("old", at: 100)
        let latest = progress("latest", at: 200)
        var folder = progress("folder", at: 300)
        folder.queueDirectory = URL(fileURLWithPath: "/tmp")
        let files = RecentFiles(controller: controller, defaults: defaults, legacyProgress: [latest, folder, old])
        XCTAssertEqual(files.urls, [latest.url, old.url])
        files.clear()
        XCTAssertTrue(files.urls.isEmpty)
        XCTAssertTrue(RecentFiles(controller: controller, defaults: defaults, legacyProgress: [old, latest]).urls.isEmpty)
    }

    func testMigrationKeepsExplicitRecentOpensAheadOfOlderProgress() throws {
        let suite = "OwlRecentFilesTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecentDocumentStub()
        let existing = URL(fileURLWithPath: "/tmp/recent.mkv")
        controller.noteNewRecentDocumentURL(existing)
        let legacy = progress("legacy", at: 100)
        let files = RecentFiles(controller: controller, defaults: defaults, legacyProgress: [legacy])
        XCTAssertEqual(files.urls, [existing, legacy.url])
    }

    func testMenuDistinguishesFilesWithTheSameName() {
        let files = RecentFiles(controller: RecentDocumentStub())
        let first = URL(fileURLWithPath: "/tmp/one/episode.mkv")
        let second = URL(fileURLWithPath: "/tmp/two/episode.mkv")
        files.record(first)
        XCTAssertEqual(files.title(for: first), "episode.mkv")
        files.record(second)
        XCTAssertNotEqual(files.title(for: first), files.title(for: second))
    }

    private func progress(_ name: String, at time: TimeInterval) -> PlaybackProgress {
        PlaybackProgress(
            url: URL(fileURLWithPath: "/tmp/\(name).mkv"), position: 120, duration: 600,
            lastPlayed: Date(timeIntervalSince1970: time), isCompleted: false
        )
    }
}

@MainActor
private final class RecentDocumentStub: RecentDocumentTracking {
    var recentDocumentURLs: [URL] = []

    func noteNewRecentDocumentURL(_ url: URL) {
        recentDocumentURLs.removeAll { $0 == url }
        recentDocumentURLs.insert(url, at: 0)
    }

    func clearRecentDocuments(_ sender: Any?) {
        recentDocumentURLs = []
    }
}
