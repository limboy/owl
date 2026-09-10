import XCTest
@testable import Owl

@MainActor
final class ContinueWatchingTests: XCTestCase {
    private var directory: URL!
    private var store: PlaybackProgressStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwlContinueTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PlaybackProgressStore(storageURL: directory.appendingPathComponent("progress.json"))
    }

    override func tearDownWithError() throws {
        store.waitForPendingWrites()
        try FileManager.default.removeItem(at: directory)
    }

    func testContinueWatchingExcludesAccidentalOpensFinishedAndUnknownDuration() {
        store.record(url: video("standalone"), position: 120, duration: 600)
        store.record(url: video("brief"), position: 29, duration: 600, queueDirectory: directory)
        store.record(url: video("finished"), position: 590, duration: 600, queueDirectory: directory)
        store.record(url: video("unknown"), position: 100, duration: 0, queueDirectory: directory)
        store.record(url: video("watching"), position: 30, duration: 600, queueDirectory: directory)
        store.record(url: video("latest"), position: 100, duration: 600, queueDirectory: directory)
        XCTAssertEqual(store.continueWatching.map(\.url), [video("latest"), video("watching")])
    }

    func testOpeningAFolderVideoOnItsOwnImmediatelyRemovesItFromContinueWatching() throws {
        let url = video("episode")
        store.record(url: url, position: 120, duration: 600, queueDirectory: directory)
        let model = AppModel(folderLibrary: nil, progressStore: store)
        defer { model.shutdown() }
        try XCTSkipIf(model.engine == nil, "libmpv is not installed")
        model.play(url, from: [url], directory: nil)
        XCTAssertTrue(store.continueWatching.isEmpty)
        XCTAssertEqual(store.progress(for: url)?.position, 120)
        model.closeVideo()
        model.play(url, from: [url], directory: directory)
        XCTAssertEqual(store.continueWatching.map(\.url), [url.standardizedFileURL])
    }

    func testHidingPersistsWithoutLosingProgressOrQueueAndCanBeUndone() throws {
        let url = video("episode")
        store.record(url: url, position: 120, duration: 600, queueDirectory: directory)
        let original = try XCTUnwrap(store.progress(for: url))
        store.setHiddenFromContinueWatching(true, url: url)
        store.waitForPendingWrites()
        let restored = PlaybackProgressStore(storageURL: directory.appendingPathComponent("progress.json"))
        XCTAssertTrue(restored.continueWatching.isEmpty)
        XCTAssertEqual(restored.progress(for: url)?.position, 120)
        XCTAssertEqual(restored.progress(for: url)?.queueDirectory, directory.standardizedFileURL)
        store.restoreEntry(original)
        XCTAssertEqual(store.continueWatching, [original])
    }

    func testProgressWritesDoNotUndoHidingButExplicitPlaybackCanRevealIt() {
        let url = video("episode")
        store.record(url: url, position: 120, duration: 600, queueDirectory: directory)
        store.setHiddenFromContinueWatching(true, url: url)
        store.record(url: url, position: 125, duration: 600, queueDirectory: directory)
        XCTAssertTrue(store.continueWatching.isEmpty)
        store.setHiddenFromContinueWatching(false, url: url)
        XCTAssertEqual(store.continueWatching.first?.position, 125)
    }

    func testMarkWatchedUndoRestoresExactPositionAndRecency() throws {
        let url = video("episode")
        store.record(url: url, position: 120, duration: 600, queueDirectory: directory)
        let original = try XCTUnwrap(store.progress(for: url))
        store.setWatched(true, url: url, duration: 600)
        XCTAssertTrue(store.continueWatching.isEmpty)
        store.restoreEntry(original)
        XCTAssertEqual(store.progress(for: url), original)
    }

    func testOldProgressWithoutNewFieldsStillLoadsAndKeepsMissingFiles() throws {
        let data = Data("""
        [{"url":"file:///Volumes/Offline/episode.mkv","position":120,"duration":600,"lastPlayed":100,"isCompleted":false}]
        """.utf8)
        let file = directory.appendingPathComponent("legacy.json")
        try data.write(to: file)
        let legacy = PlaybackProgressStore(storageURL: file)
        XCTAssertTrue(legacy.continueWatching.isEmpty)
        XCTAssertEqual(legacy.entries.first?.position, 120)
        XCTAssertNil(legacy.entries.first?.queueDirectory)
    }

    func testLegacyDuplicatePathsProduceOnlyTheLatestContinueWatchingCard() throws {
        let original = PlaybackProgress(
            url: URL(fileURLWithPath: "/tmp/series/episode.mkv"), position: 60, duration: 600,
            lastPlayed: Date(timeIntervalSince1970: 100), isCompleted: false,
            queueDirectory: URL(fileURLWithPath: "/tmp/series")
        )
        let latest = PlaybackProgress(
            url: URL(fileURLWithPath: "/tmp/series/../series/episode.mkv"), position: 120, duration: 600,
            lastPlayed: Date(timeIntervalSince1970: 200), isCompleted: false,
            queueDirectory: URL(fileURLWithPath: "/tmp/series")
        )
        let file = directory.appendingPathComponent("duplicates.json")
        try JSONEncoder().encode([original, latest]).write(to: file)
        let restored = PlaybackProgressStore(storageURL: file)
        XCTAssertEqual(restored.continueWatching, [latest])
    }

    func testResumedFolderUsesNaturalEpisodeOrderAndExcludesNestedAndUnrelatedFiles() throws {
        for name in ["Episode 10.mkv", "Episode 2.mkv", "Episode 1.mkv", "notes.txt", ".hidden.mkv"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("nested.mkv"), withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Episode 2.mkv")
        store.record(url: url, position: 120, duration: 600, queueDirectory: directory)
        store.record(url: video("unrelated"), position: 120, duration: 600)
        let resolved = try ContinueWatchingQueue.resolve(for: XCTUnwrap(store.progress(for: url)))
        XCTAssertEqual(resolved.videos.map(\.lastPathComponent), ["Episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv"])
        let queue = PlaybackQueue()
        queue.select(url.standardizedFileURL, from: resolved.videos)
        XCTAssertEqual(queue.next(automatic: true)?.lastPathComponent, "Episode 10.mkv")
        XCTAssertNil(queue.next(automatic: true))
    }

    func testStandaloneResumeDoesNotPickUpSiblingVideos() throws {
        let url = video("standalone")
        try Data().write(to: url)
        try Data().write(to: video("sibling"))
        store.record(url: url, position: 120, duration: 600)
        let resolved = try ContinueWatchingQueue.resolve(for: XCTUnwrap(store.progress(for: url)))
        XCTAssertEqual(resolved.videos, [url.standardizedFileURL])
        XCTAssertNil(resolved.directory)
    }

    func testMissingFileFailsWithoutRemovingItsResumePoint() throws {
        let url = video("missing")
        store.record(url: url, position: 120, duration: 600, queueDirectory: directory)
        let entry = try XCTUnwrap(store.progress(for: url))
        XCTAssertThrowsError(try ContinueWatchingQueue.resolve(for: entry))
        XCTAssertEqual(store.continueWatching, [entry])
    }

    func testBrowserLocationRemembersContinueWatchingAndNestedFolder() throws {
        let suite = "OwlNavigationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(BrowserLocation.load(defaults: defaults))
        let folder = BrowserLocation(destination: .folder(UUID()), path: [directory, directory.appendingPathComponent("Season 1")])
        folder.save(defaults: defaults)
        XCTAssertEqual(BrowserLocation.load(defaults: defaults), folder)
        let resume = BrowserLocation(destination: .continueWatching, path: folder.path)
        resume.save(defaults: defaults)
        XCTAssertEqual(BrowserLocation.load(defaults: defaults), resume)
    }

    func testStartingOverUsesZeroAndLoadingDoesNotOverwriteStoredProgress() throws {
        let url = video("episode")
        store.record(url: url, position: 120, duration: 600)
        let model = AppModel(folderLibrary: nil, progressStore: store)
        defer { model.shutdown() }
        try XCTSkipIf(model.engine == nil, "libmpv is not installed")
        model.play(url, from: [url], directory: nil, fromBeginning: true)
        XCTAssertEqual(model.playerState.currentTime, 0)
        model.closeVideo()
        XCTAssertEqual(store.progress(for: url)?.position, 120)
        model.play(url, from: [url], directory: nil)
        XCTAssertEqual(model.playerState.currentTime, 120)
    }

    func testBrowserRefreshCannotCloseAContinueWatchingPlayer() throws {
        let library = FolderLibrary(storageURL: directory.appendingPathComponent("library.json"), startWatching: false)
        let model = AppModel(folderLibrary: library, progressStore: store)
        defer { model.shutdown() }
        try XCTSkipIf(model.engine == nil, "libmpv is not installed")
        let url = video("episode")
        model.play(url, from: [url], directory: directory, followsBrowserQueue: false)
        library.refreshVisibleDirectory()
        XCTAssertEqual(model.playerState.currentURL, url)
        XCTAssertEqual(model.playbackQueue.videos, [url])
    }

    private func video(_ name: String) -> URL {
        directory.appendingPathComponent(name + ".mkv")
    }
}
