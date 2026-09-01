import Foundation
import XCTest
@testable import Owl

@MainActor
final class PlaybackProgressStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testProgressPersistsAndRestores() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("progress.json")
        let video = temporaryDirectory.appendingPathComponent("lesson.mp4")
        try Data().write(to: video)
        let store = PlaybackProgressStore(storageURL: storageURL)

        store.record(url: video, position: 120, duration: 600)
        store.waitForPendingWrites()

        let restored = PlaybackProgressStore(storageURL: storageURL)
        XCTAssertEqual(restored.progress(for: video)?.position, 120)
    }

    func testNearEndProgressIsMarkedCompleted() {
        let store = PlaybackProgressStore(
            storageURL: temporaryDirectory.appendingPathComponent("progress.json")
        )
        let video = temporaryDirectory.appendingPathComponent("finished.mkv")

        store.record(url: video, position: 590, duration: 600)

        XCTAssertTrue(store.progress(for: video)?.isCompleted == true)
    }

    func testWatchedStateCanBeToggledWithoutKnownDuration() {
        let store = PlaybackProgressStore(
            storageURL: temporaryDirectory.appendingPathComponent("progress.json")
        )
        let video = temporaryDirectory.appendingPathComponent("manual-status.mkv")

        store.setWatched(true, url: video, duration: nil)

        XCTAssertTrue(store.progress(for: video)?.isCompleted == true)

        store.setWatched(false, url: video, duration: nil)

        XCTAssertNil(store.progress(for: video))
    }

    func testTheOldestEntriesFallOffOnceTheStoreIsFull() {
        let store = PlaybackProgressStore(
            storageURL: temporaryDirectory.appendingPathComponent("progress.json")
        )
        let limit = PlaybackProgressStore.maximumEntryCount
        let videos = (0..<(limit + 10)).map {
            temporaryDirectory.appendingPathComponent("episode-\($0).mkv")
        }

        // Recorded oldest first, so the earliest ones are the ones over the
        // ceiling. `lastPlayed` is stamped inside `record`, and its resolution
        // is fine enough to keep these in order.
        for video in videos {
            store.record(url: video, position: 30, duration: 600)
        }

        XCTAssertEqual(store.entries.count, limit)
        for dropped in videos.prefix(10) {
            XCTAssertNil(store.progress(for: dropped))
        }
        for kept in videos.suffix(limit) {
            XCTAssertEqual(store.progress(for: kept)?.position, 30)
        }
    }

    func testAnOversizedFileIsTrimmedOnRestore() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("progress.json")
        let limit = PlaybackProgressStore.maximumEntryCount
        let start = Date(timeIntervalSince1970: 1_000_000)
        let stored = (0..<(limit + 25)).map { index in
            PlaybackProgress(
                url: temporaryDirectory.appendingPathComponent("old-\(index).mkv"),
                position: 30,
                duration: 600,
                // Ascending, so index 0 is the least recently played and should
                // be among the entries dropped.
                lastPlayed: start.addingTimeInterval(Double(index)),
                isCompleted: false
            )
        }
        try JSONEncoder().encode(stored).write(to: storageURL)

        let restored = PlaybackProgressStore(storageURL: storageURL)

        XCTAssertEqual(restored.entries.count, limit)
        XCTAssertNil(restored.progress(for: stored[0].url))
        XCTAssertNotNil(restored.progress(for: stored[stored.count - 1].url))
    }
}
