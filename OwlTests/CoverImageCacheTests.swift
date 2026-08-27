import Foundation
import XCTest
@testable import Owl

final class CoverImageCacheTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlCoverCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCoverSurvivesANewCache() async throws {
        let video = try makeVideo(named: "lesson.mp4", contents: "one")
        let directory = temporaryDirectory.appendingPathComponent("Covers", isDirectory: true)

        await CoverImageCache(directory: directory).store(Data("cover".utf8), for: video, at: 10)
        let restored = await CoverImageCache(directory: directory).data(for: video, at: 10)

        XCTAssertEqual(restored, Data("cover".utf8))
    }

    func testChangingTheVideoInvalidatesItsCover() async throws {
        let video = try makeVideo(named: "lesson.mp4", contents: "one")
        let cache = CoverImageCache(
            directory: temporaryDirectory.appendingPathComponent("Covers", isDirectory: true)
        )

        await cache.store(Data("cover".utf8), for: video, at: 10)
        try Data("a longer re-encode".utf8).write(to: video)

        let stale = await cache.data(for: video, at: 10)
        XCTAssertNil(stale, "A rewritten file must not keep the cover of its old contents.")
    }

    func testEachSecondIsCachedSeparately() async throws {
        let video = try makeVideo(named: "lesson.mp4", contents: "one")
        let cache = CoverImageCache(
            directory: temporaryDirectory.appendingPathComponent("Covers", isDirectory: true)
        )

        await cache.store(Data("cover".utf8), for: video, at: 10)

        let other = await cache.data(for: video, at: 20)
        XCTAssertNil(other)
    }

    func testAMissingVideoHasNoCover() async throws {
        let cache = CoverImageCache(
            directory: temporaryDirectory.appendingPathComponent("Covers", isDirectory: true)
        )
        let missing = temporaryDirectory.appendingPathComponent("gone.mp4")

        await cache.store(Data("cover".utf8), for: missing, at: 10)

        let stored = await cache.data(for: missing, at: 10)
        XCTAssertNil(stored, "A file that cannot be measured has no identity to key a cover on.")
    }

    func testFolderCoverIsRememberedAcrossLaunches() async throws {
        let folder = temporaryDirectory.appendingPathComponent("Season 1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("episode.mkv")
        try Data().write(to: video)
        let storageURL = temporaryDirectory.appendingPathComponent("folders.json")

        await FolderCoverIndex(storageURL: storageURL).setVideo(video, for: folder)
        let restored = await FolderCoverIndex(storageURL: storageURL).video(for: folder)

        XCTAssertEqual(restored, video.standardizedFileURL)
    }

    func testAFolderCoverPointingAtADeletedFileIsForgotten() async throws {
        let folder = temporaryDirectory.appendingPathComponent("Season 1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("episode.mkv")
        try Data().write(to: video)
        let index = FolderCoverIndex(
            storageURL: temporaryDirectory.appendingPathComponent("folders.json")
        )

        await index.setVideo(video, for: folder)
        try FileManager.default.removeItem(at: video)

        let remembered = await index.video(for: folder)
        XCTAssertNil(remembered, "A folder whose cover file is gone must be walked again.")
    }

    private func makeVideo(named name: String, contents: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
