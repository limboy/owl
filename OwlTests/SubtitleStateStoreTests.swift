import Foundation
import XCTest
@testable import Owl

@MainActor
final class SubtitleStateStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlSubtitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testADelayAndATrackArePersistedTogetherAndRestored() {
        let storageURL = temporaryDirectory.appendingPathComponent("subtitles.json")
        let video = temporaryDirectory.appendingPathComponent("episode.mkv")
        let store = SubtitleStateStore(storageURL: storageURL)

        store.recordDelay(url: video, delaySeconds: 0.75)
        store.recordSelection(
            url: video,
            selection: .embedded(id: 3, language: "jpn", title: "Japanese")
        )

        let restored = SubtitleStateStore(storageURL: storageURL)
        XCTAssertEqual(restored.delay(for: video), 0.75)
        XCTAssertEqual(
            restored.selection(for: video),
            .embedded(id: 3, language: "jpn", title: "Japanese")
        )
    }

    /// The two are recorded by different actions at different moments, and
    /// neither may wipe the other: a track chosen after the delay was set has
    /// to leave the delay standing.
    func testRecordingOneLeavesTheOtherAlone() {
        let store = makeStore()
        let video = temporaryDirectory.appendingPathComponent("both.mkv")

        store.recordSelection(url: video, selection: .off)
        store.recordDelay(url: video, delaySeconds: -1.5)

        XCTAssertEqual(store.selection(for: video), .off)
        XCTAssertEqual(store.delay(for: video), -1.5)
    }

    /// A file watched the way it came needs no row of its own, and every video
    /// merely opened and closed would otherwise leave one.
    func testAnEntryThatSaysNothingIsDropped() {
        let store = makeStore()
        let video = temporaryDirectory.appendingPathComponent("ordinary.mkv")

        store.recordDelay(url: video, delaySeconds: 0.5)
        store.recordSelection(url: video, selection: .off)
        XCTAssertEqual(store.entries.count, 1)

        store.recordDelay(url: video, delaySeconds: 0)
        XCTAssertEqual(store.entries.count, 1, "a track is still remembered for it")

        store.recordSelection(url: video, selection: nil)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.delay(for: video))
    }

    func testTheSameFileIsRecognisedThroughAnUntidyPath() {
        let store = makeStore()
        let video = temporaryDirectory.appendingPathComponent("tidy.mkv")
        let untidy = temporaryDirectory
            .appendingPathComponent("subdir")
            .appendingPathComponent("..")
            .appendingPathComponent("tidy.mkv")

        store.recordDelay(url: untidy, delaySeconds: 2)

        XCTAssertEqual(store.delay(for: video), 2)
        XCTAssertEqual(store.entries.count, 1)
    }

    /// The file on disk predates subtitle track memory, and holds delays
    /// somebody set. Reading it has to go on working, or their adjustments are
    /// lost to an upgrade.
    func testAFileWrittenBeforeTracksWereRememberedStillReads() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("legacy.json")
        let video = temporaryDirectory.appendingPathComponent("old.mkv")
        let legacy = """
        [{"url":"\(video.absoluteString)","delaySeconds":1.25,\
        "lastUpdated":768000000}]
        """
        try Data(legacy.utf8).write(to: storageURL)

        let store = SubtitleStateStore(storageURL: storageURL)

        XCTAssertEqual(store.delay(for: video), 1.25)
        XCTAssertNil(store.selection(for: video))
    }

    func testTheOldestEntriesFallOffOnceTheStoreIsFull() {
        let store = makeStore()

        for index in 0..<(SubtitleStateStore.maximumEntryCount + 10) {
            store.recordDelay(
                url: temporaryDirectory.appendingPathComponent("file-\(index).mkv"),
                delaySeconds: 0.5
            )
        }

        XCTAssertEqual(store.entries.count, SubtitleStateStore.maximumEntryCount)
        XCTAssertNil(store.delay(for: temporaryDirectory.appendingPathComponent("file-0.mkv")))
        XCTAssertNotNil(
            store.delay(
                for: temporaryDirectory.appendingPathComponent(
                    "file-\(SubtitleStateStore.maximumEntryCount + 9).mkv"
                )
            )
        )
    }

    private func makeStore() -> SubtitleStateStore {
        SubtitleStateStore(
            storageURL: temporaryDirectory.appendingPathComponent("subtitles.json")
        )
    }
}
