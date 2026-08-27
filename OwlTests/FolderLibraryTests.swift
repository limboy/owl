import Foundation
import XCTest
@testable import Owl

@MainActor
final class FolderLibraryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        storageURL = temporaryDirectory.appendingPathComponent("library.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testFolderNavigationFiltersAndSortsEntries() throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        let nested = root.appendingPathComponent("Season 1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("B.mkv"))
        try Data().write(to: root.appendingPathComponent("a.mp4"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let library = FolderLibrary(storageURL: storageURL, startWatching: false)
        XCTAssertTrue(library.addFolders([root]))
        library.openRoot(library.roots[0])

        XCTAssertEqual(library.entries.map(\.name), ["Season 1", "a.mp4", "B.mkv"])
        XCTAssertEqual(library.visibleVideos.map(\.lastPathComponent), ["a.mp4", "B.mkv"])

        library.openFolder(nested)
        XCTAssertEqual(library.navigationPath.count, 2)
        library.goBack()
        XCTAssertEqual(library.currentDirectory, root.standardizedFileURL)

        var returnedToRootList = false
        library.onVisibleVideosChanged = { directory, _ in
            returnedToRootList = directory == nil
        }
        library.goBack()
        XCTAssertTrue(library.isAtRootList)
        XCTAssertTrue(returnedToRootList)
    }

    func testDuplicateRootsAreIgnoredAndPersisted() throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let library = FolderLibrary(storageURL: storageURL, startWatching: false)
        XCTAssertTrue(library.addFolders([root]))
        XCTAssertFalse(library.addFolders([root]))
        XCTAssertEqual(library.roots.count, 1)

        let restored = FolderLibrary(storageURL: storageURL, startWatching: false)
        XCTAssertEqual(restored.roots.count, 1)
        XCTAssertEqual(restored.roots[0].url, root.standardizedFileURL)
        XCTAssertTrue(restored.roots[0].isAvailable)
    }

    func testRefreshReflectsAddedAndRemovedVideos() throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.mp4")
        let second = root.appendingPathComponent("second.webm")
        try Data().write(to: first)

        let library = FolderLibrary(storageURL: storageURL, startWatching: false)
        _ = library.addFolders([root])
        library.openRoot(library.roots[0])
        XCTAssertEqual(library.visibleVideos, [first.standardizedFileURL])

        try Data().write(to: second)
        try FileManager.default.removeItem(at: first)
        library.refreshAll()
        XCTAssertEqual(library.visibleVideos, [second.standardizedFileURL])
    }

    func testUnavailableRootCanBeRemoved() throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let library = FolderLibrary(storageURL: storageURL, startWatching: false)
        _ = library.addFolders([root])
        let id = library.roots[0].id
        try FileManager.default.removeItem(at: root)
        library.refreshAll()

        XCTAssertFalse(library.roots[0].isAvailable)
        library.removeRoot(id: id)
        XCTAssertTrue(library.roots.isEmpty)
    }

    // MARK: - Metadata sync

    func testSyncingFillsInWhatTheCatalogueSays() async throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Arrival.2016.1080p.mkv"))
        let video = root.appendingPathComponent("Arrival.2016.1080p.mkv").standardizedFileURL

        let library = makeLibrary(syncEnabled: true) { _ in
            Data(#"{"results": [{"title": "Arrival", "overview": "A linguist.", "release_date": "2016-11-10", "backdrop_path": "/wide.jpg"}]}"#.utf8)
        }
        library.addFolders([root])
        library.openRoot(try XCTUnwrap(library.roots.first))

        try await waitUntil { library.onlineMetadata(for: video) != nil }

        let found = try XCTUnwrap(library.onlineMetadata(for: video))
        XCTAssertEqual(found.title, "Arrival")
        XCTAssertEqual(found.overview, "A linguist.")
        XCTAssertEqual(found.artworkPath, "/wide.jpg")
    }

    /// Nothing is asked while the switch is off, and turning it off again puts
    /// the rows back to the file names they started with.
    func testTurningSyncOffAsksNothingAndClearsWhatWasFound() async throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Arrival.2016.1080p.mkv"))
        let video = root.appendingPathComponent("Arrival.2016.1080p.mkv").standardizedFileURL

        let requests = RequestCount()
        let library = makeLibrary(syncEnabled: false) { _ in
            await requests.increment()
            return Data(#"{"results": [{"title": "Arrival"}]}"#.utf8)
        }
        library.addFolders([root])
        library.openRoot(try XCTUnwrap(library.roots.first))

        // Give a lookup every chance to happen before concluding it did not.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(library.onlineMetadata(for: video))
        var count = await requests.count
        XCTAssertEqual(count, 0)

        library.isMetadataSyncEnabled = true
        try await waitUntil { library.onlineMetadata(for: video) != nil }
        count = await requests.count
        XCTAssertEqual(count, 1)

        library.isMetadataSyncEnabled = false
        XCTAssertNil(library.onlineMetadata(for: video))
    }

    func testTheSyncSwitchIsRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OwlTests-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let library = FolderLibrary(
            storageURL: storageURL,
            startWatching: false,
            onlineMetadataService: OnlineMetadataService(client: nil, store: makeStore()),
            defaults: defaults
        )
        XCTAssertFalse(library.isMetadataSyncEnabled, "syncing should be off until asked for")

        library.isMetadataSyncEnabled = true

        let restored = FolderLibrary(
            storageURL: storageURL,
            startWatching: false,
            onlineMetadataService: OnlineMetadataService(client: nil, store: makeStore()),
            defaults: defaults
        )
        XCTAssertTrue(restored.isMetadataSyncEnabled)
    }

    // MARK: - Metadata sync helpers

    private func makeLibrary(
        syncEnabled: Bool,
        respond: @escaping @Sendable (URLRequest) async throws -> Data
    ) -> FolderLibrary {
        let defaults = UserDefaults(suiteName: "OwlTests-\(UUID().uuidString)")!
        defaults.set(syncEnabled, forKey: MetadataSyncPreference.defaultsKey)
        return FolderLibrary(
            storageURL: storageURL,
            startWatching: false,
            onlineMetadataService: OnlineMetadataService(
                client: TMDBClient(apiKey: "secret", transport: respond),
                store: makeStore()
            ),
            defaults: defaults
        )
    }

    private func makeStore() -> OnlineMetadataStore {
        OnlineMetadataStore(
            directory: temporaryDirectory.appendingPathComponent("Catalogue", isDirectory: true)
        )
    }

    /// Waits for work that finishes on a task of its own. The lookups run
    /// detached from the call that started them, so there is nothing to await.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the expected state", file: file, line: line)
    }
}

private actor RequestCount {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
