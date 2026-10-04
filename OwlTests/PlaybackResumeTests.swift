import XCTest
@testable import Owl

@MainActor
final class PlaybackResumeTests: XCTestCase {
    private var directory: URL!
    private var store: PlaybackProgressStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwlResumeTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PlaybackProgressStore(storageURL: directory.appendingPathComponent("progress.json"))
    }

    override func tearDownWithError() throws {
        store.waitForPendingWrites()
        try FileManager.default.removeItem(at: directory)
    }

    func testMarkWatchedUndoRestoresExactPositionAndRecency() throws {
        let url = video("episode")
        store.record(url: url, position: 120, duration: 600, queueDirectory: directory)
        let original = try XCTUnwrap(store.progress(for: url))
        store.setWatched(true, url: url, duration: 600)
        XCTAssertEqual(store.progress(for: url)?.isCompleted, true)
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
        XCTAssertEqual(legacy.entries.first?.position, 120)
        XCTAssertNil(legacy.entries.first?.queueDirectory)
    }

    func testLegacyDuplicatePathsResolveToTheLatestEntry() throws {
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
        XCTAssertEqual(restored.progress(for: original.url), latest)
    }

    func testBrowserLocationRemembersNestedFolder() throws {
        let suite = "OwlNavigationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(BrowserLocation.load(defaults: defaults))
        let folder = BrowserLocation(destination: .folder(UUID()), path: [directory, directory.appendingPathComponent("Season 1")])
        folder.save(defaults: defaults)
        XCTAssertEqual(BrowserLocation.load(defaults: defaults), folder)
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

    func testBrowserRefreshCannotCloseAPlayerThatIsNotFollowingTheBrowser() throws {
        let library = FolderLibrary(storageURL: directory.appendingPathComponent("library.json"), startWatching: false)
        let model = AppModel(folderLibrary: library, progressStore: store)
        defer { model.shutdown() }
        try XCTSkipIf(model.engine == nil, "libmpv is not installed")
        let url = video("episode")
        model.play(url, from: [url], directory: directory, followsBrowserQueue: false)
        library.refreshVisibleDirectory()
        library.refreshVisibleDirectory()
        XCTAssertEqual(model.playerState.currentURL, url)
        XCTAssertEqual(model.playbackQueue.videos, [url])
    }

    private func video(_ name: String) -> URL {
        directory.appendingPathComponent(name + ".mkv")
    }
}
