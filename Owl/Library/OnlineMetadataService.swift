import Foundation

/// Whether the browser should look up what its videos are.
///
/// Off by default. Looking a folder up means telling a third party the names of
/// the files in it, which is not something to start doing on somebody's behalf.
enum MetadataSyncPreference {
    static let defaultsKey = "MetadataSyncEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: defaultsKey)
    }
}

/// Turns a file into what an online catalogue says it is, going to the network
/// only for what is not already known.
///
/// The disk store is consulted first and written last, including for files
/// nothing matched, so a folder that has been looked at once costs nothing to
/// look at again.
final class OnlineMetadataService: Sendable {
    /// The one the app uses, talking to whichever catalogue this build was
    /// given a key for — or to nothing at all, when it was given none.
    static let shared = OnlineMetadataService(
        client: isHostingTests ? nil : TMDBCredentials.apiKey().map { TMDBClient(apiKey: $0) }
    )

    /// Whether this process is hosting the test suite rather than serving
    /// somebody who opened the app.
    ///
    /// The test action launches Owl.app for real — browser, restored library
    /// and all — so a developer with syncing switched on and a key in the
    /// bundle had the suite look up their own library over the network, and
    /// write the answers into the real cache. Tests that mean to exercise a
    /// catalogue hand one in; nothing should reach a live one by default.
    private static var isHostingTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    private let client: TMDBClient?
    private let store: OnlineMetadataStore

    init(client: TMDBClient?, store: OnlineMetadataStore = .shared) {
        self.client = client
        self.store = store
    }

    /// Whether there is anything to sync with. A build with no catalogue key
    /// can still show everything Owl reads out of the files themselves, so the
    /// browser hides the switch rather than offering one that cannot work.
    var isAvailable: Bool {
        client != nil
    }

    func metadata(for url: URL) async -> OnlineMetadata? {
        if let record = await store.record(for: url), record.isFresh() {
            return record.metadata
        }
        guard let client else { return nil }

        // A request that failed says nothing about the file, so it is not
        // recorded at all: a network that was down for a moment should not
        // keep a folder blank for a fortnight. Only an answer — including the
        // answer "nothing matched" — is written down.
        guard let found = try? await lookUp(url, with: client) else { return nil }
        guard !Task.isCancelled else { return found.metadata }
        await store.store(
            OnlineMetadataRecord(metadata: found.metadata, fetchedAt: Date()),
            for: url
        )
        return found.metadata
    }

    /// Drops what is known about a file so the next look starts over.
    func forget(_ url: URL) async {
        await store.removeRecord(for: url)
    }

    /// The catalogue's answer, wrapped so that "nothing matched" and "could
    /// not ask" stay apart: the first is a result worth remembering, the second
    /// is a thrown error.
    private struct Answer {
        var metadata: OnlineMetadata?
    }

    private func lookUp(_ url: URL, with client: TMDBClient) async throws -> Answer {
        guard let guess = VideoTitleGuess.parse(url), !guess.title.isEmpty else {
            // A name nothing can be read out of will not read differently next
            // time, so this counts as an answer.
            return Answer(metadata: nil)
        }

        if let season = guess.season, let episode = guess.episode {
            return Answer(
                metadata: try await client.episode(
                    series: guess.title,
                    season: season,
                    episode: episode
                )
            )
        }
        return Answer(metadata: try await client.movie(title: guess.title, year: guess.year))
    }
}
