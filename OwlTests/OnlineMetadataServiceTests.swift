import Foundation
import XCTest
@testable import Owl

final class OnlineMetadataServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlOnlineMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testAMatchSurvivesANewStore() async throws {
        let video = videoURL(named: "Arrival.2016.1080p.mkv")
        let record = OnlineMetadataRecord(
            metadata: OnlineMetadata(
                title: "Arrival",
                overview: "A linguist.",
                year: 2_016,
                episodeLabel: nil,
                artworkPath: "/wide.jpg"
            ),
            fetchedAt: Date()
        )

        await makeStore().store(record, for: video)
        let restored = await makeStore().record(for: video)

        XCTAssertEqual(restored?.metadata?.title, "Arrival")
        XCTAssertEqual(restored?.metadata?.artworkPath, "/wide.jpg")
    }

    /// The identity is the path, not the bytes: a re-encode is still the same
    /// film, and re-asking the network for it would be the whole cost of the
    /// feature paid again.
    func testRewritingTheFileKeepsItsMatch() async throws {
        let video = videoURL(named: "Arrival.2016.1080p.mkv")
        try Data("one".utf8).write(to: video)
        let store = makeStore()
        await store.store(
            OnlineMetadataRecord(metadata: sample, fetchedAt: Date()),
            for: video
        )

        try Data("a much longer re-encode".utf8).write(to: video)

        let restored = await store.record(for: video)
        XCTAssertEqual(restored?.metadata?.title, sample.title)
    }

    func testAMissIsFreshForAWhileAndThenIsNot() {
        let miss = OnlineMetadataRecord(metadata: nil, fetchedAt: Date())
        XCTAssertTrue(miss.isFresh())

        let stale = OnlineMetadataRecord(
            metadata: nil,
            fetchedAt: Date(timeIntervalSinceNow: -OnlineMetadataRecord.missLifetime - 1)
        )
        XCTAssertFalse(stale.isFresh())

        // A match never goes stale on its own; a renamed or replaced file gets
        // a different key instead.
        let old = OnlineMetadataRecord(
            metadata: sample,
            fetchedAt: Date(timeIntervalSinceNow: -10 * OnlineMetadataRecord.missLifetime)
        )
        XCTAssertTrue(old.isFresh())
    }

    /// A miss written by an older reading of file names is asked again, because
    /// improving that reading is exactly what turns such a miss into a match.
    func testAnAnswerFromAnOlderParserIsNotFresh() {
        let current = OnlineMetadataRecord(metadata: nil, fetchedAt: Date())
        XCTAssertTrue(current.isFresh())

        var older = current
        older.generation = OnlineMetadataRecord.currentGeneration - 1
        XCTAssertFalse(older.isFresh())

        // Records written before the field existed decode with no value.
        var unversioned = OnlineMetadataRecord(metadata: sample, fetchedAt: Date())
        unversioned.generation = nil
        XCTAssertFalse(unversioned.isFresh())
    }

    func testARecordStoredBeforeVersioningIsAskedAgain() async throws {
        let video = videoURL(named: "Arrival.2016.1080p.mkv")
        let store = makeStore()
        var stale = OnlineMetadataRecord(metadata: nil, fetchedAt: Date())
        stale.generation = nil
        await store.store(stale, for: video)

        let calls = CallCounter()
        let client = TMDBClient(apiKey: "secret") { _ in
            await calls.increment()
            return Data(#"{"results": [{"title": "Arrival"}]}"#.utf8)
        }
        let found = await OnlineMetadataService(client: client, store: store)
            .metadata(for: video)

        XCTAssertEqual(found?.title, "Arrival")
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testASecondLookAsksNothing() async throws {
        let video = videoURL(named: "Arrival.2016.1080p.mkv")
        let calls = CallCounter()
        let service = makeService(calls: calls) { _ in
            Data(#"{"results": [{"title": "Arrival", "release_date": "2016-11-10"}]}"#.utf8)
        }

        let first = await service.metadata(for: video)
        let second = await service.metadata(for: video)

        XCTAssertEqual(first?.title, "Arrival")
        XCTAssertEqual(second?.title, "Arrival")
        let count = await calls.count
        XCTAssertEqual(count, 1, "the second look should come out of the store")
    }

    /// A file nothing matches would otherwise be asked about on every visit to
    /// the folder it lives in.
    func testAMissIsRememberedToo() async throws {
        let video = videoURL(named: "Zzzz.Unknowable.Thing.2044.mkv")
        let calls = CallCounter()
        let service = makeService(calls: calls) { _ in Data(#"{"results": []}"#.utf8) }

        let first = await service.metadata(for: video)
        let second = await service.metadata(for: video)

        XCTAssertNil(first)
        XCTAssertNil(second)
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    /// Not being able to ask is different from having asked and been told no.
    func testAFailedRequestIsNotRemembered() async throws {
        let video = videoURL(named: "Arrival.2016.1080p.mkv")
        let calls = CallCounter()
        let service = makeService(calls: calls) { _ in
            throw TMDBClient.TMDBError.badStatus(503)
        }

        _ = await service.metadata(for: video)
        _ = await service.metadata(for: video)

        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testANameThatSaysNothingNeverReachesTheNetwork() async throws {
        let video = temporaryDirectory
            .appendingPathComponent("1080p", isDirectory: true)
            .appendingPathComponent("1080p.mkv")
        let calls = CallCounter()
        let service = makeService(calls: calls) { _ in Data(#"{"results": []}"#.utf8) }

        let found = await service.metadata(for: video)

        XCTAssertNil(found)
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testForgettingAFileMakesTheNextLookAskAgain() async throws {
        let video = videoURL(named: "Arrival.2016.1080p.mkv")
        let calls = CallCounter()
        let service = makeService(calls: calls) { _ in
            Data(#"{"results": [{"title": "Arrival"}]}"#.utf8)
        }

        _ = await service.metadata(for: video)
        await service.forget(video)
        _ = await service.metadata(for: video)

        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    /// Without a key there is nothing to sync with, and the browser hides the
    /// switch rather than offering one that cannot work.
    func testAServiceWithoutAKeyIsUnavailable() async {
        let service = OnlineMetadataService(client: nil, store: makeStore())

        XCTAssertFalse(service.isAvailable)
        let found = await service.metadata(for: videoURL(named: "Arrival.2016.mkv"))
        XCTAssertNil(found)
    }

    // MARK: - Helpers

    private var sample: OnlineMetadata {
        OnlineMetadata(
            title: "Arrival",
            overview: "A linguist.",
            year: 2_016,
            episodeLabel: nil,
            artworkPath: "/wide.jpg"
        )
    }

    private func makeStore() -> OnlineMetadataStore {
        OnlineMetadataStore(
            directory: temporaryDirectory.appendingPathComponent("Store", isDirectory: true)
        )
    }

    private func videoURL(named name: String) -> URL {
        temporaryDirectory.appendingPathComponent(name)
    }

    private func makeService(
        calls: CallCounter,
        respond: @escaping @Sendable (URLRequest) async throws -> Data
    ) -> OnlineMetadataService {
        let client = TMDBClient(apiKey: "secret") { request in
            await calls.increment()
            return try await respond(request)
        }
        return OnlineMetadataService(client: client, store: makeStore())
    }
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
