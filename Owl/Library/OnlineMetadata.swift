import CryptoKit
import Foundation

/// What an online catalogue says a video is.
///
/// Everything here is optional to the browser: a row that has none of it shows
/// the file name and an extracted frame exactly as it always did, and each
/// piece that arrives replaces the corresponding piece of that.
struct OnlineMetadata: Codable, Equatable, Sendable {
    /// The work's own name — the film's title, or the episode's.
    var title: String

    /// A sentence or two describing it, as the catalogue writes it.
    var overview: String?

    /// The year it came out, where the catalogue gave one.
    var year: Int?

    /// The series and episode this belongs to, already written out for
    /// display — "The Expanse · S1E2". Nil for a film.
    var episodeLabel: String?

    /// Where the artwork lives on the catalogue's image host, as the path it
    /// hands back. Kept as a path rather than a full URL so the size to fetch
    /// stays the caller's decision.
    var artworkPath: String?

    /// The line the browser shows under the title when there is nothing more
    /// specific to show. The series comes first for an episode because that is
    /// what tells one row from the next in a folder of them.
    var subtitleLine: String? {
        if let episodeLabel { return episodeLabel }
        if let year { return String(year) }
        return nil
    }
}

/// One file's answer from the catalogue, including the answer "nothing
/// matched".
///
/// A miss is worth keeping. Most of what fails to match is named in a way that
/// will never match, and without recording the failure every visit to the
/// folder would ask again about every one of those files.
struct OnlineMetadataRecord: Codable, Equatable, Sendable {
    var metadata: OnlineMetadata?
    var fetchedAt: Date

    /// Which reading of file names produced this answer.
    ///
    /// The rules for turning a file name into something searchable get better,
    /// and an answer from an older set of them is worth asking again rather
    /// than standing for a fortnight — a miss is precisely what fixing those
    /// rules is meant to turn into a match. Bump this whenever
    /// `VideoTitleGuess` changes what it reads out of a name.
    ///
    /// Optional because records written before it existed have no value here;
    /// those read as nil, which is not the current generation, so they are
    /// asked again.
    static let currentGeneration = 2
    var generation: Int? = OnlineMetadataRecord.currentGeneration

    /// How long a miss stands before it is worth asking again. Catalogues do
    /// gain entries, and a file renamed into something searchable is caught by
    /// the key rather than by this, so the interval only has to be shorter than
    /// forever.
    static let missLifetime: TimeInterval = 14 * 24 * 60 * 60

    func isFresh(now: Date = Date()) -> Bool {
        guard generation == Self.currentGeneration else { return false }
        if metadata != nil { return true }
        return now.timeIntervalSince(fetchedAt) < Self.missLifetime
    }
}

/// Catalogue answers kept on disk between launches.
///
/// Unlike the parsed media facts, these are keyed by the file's path alone and
/// not by its size and modification date. What a file *is* does not change when
/// it is re-encoded or its timestamp is touched, and re-asking the network
/// because a file was copied would be the whole cost of the feature paid twice.
/// Renaming a file does change the key, which is correct: the name is the only
/// thing the match was ever made from.
actor OnlineMetadataStore {
    static let shared = OnlineMetadataStore()
    static let maximumEntryCount = 5_000

    private static let sweepInterval = 64

    private let directory: URL
    private let fileManager: FileManager
    private var hasSwept = false
    private var writesSinceSweep = 0

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.directory = caches
                .appendingPathComponent("Owl", isDirectory: true)
                .appendingPathComponent("OnlineMetadata", isDirectory: true)
        }
    }

    func record(for url: URL) -> OnlineMetadataRecord? {
        guard let data = try? Data(contentsOf: entryURL(for: url)) else { return nil }
        return try? JSONDecoder().decode(OnlineMetadataRecord.self, from: data)
    }

    func store(_ record: OnlineMetadataRecord, for url: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: entryURL(for: url), options: .atomic)
        } catch {
            // A failed write only means the file is looked up again later.
            return
        }

        writesSinceSweep += 1
        if !hasSwept || writesSinceSweep >= Self.sweepInterval {
            sweep()
        }
    }

    /// Forgets one file's answer, so the next look asks the catalogue again.
    func removeRecord(for url: URL) {
        try? fileManager.removeItem(at: entryURL(for: url))
    }

    private func entryURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".json"
        return directory.appendingPathComponent(name)
    }

    private func sweep() {
        hasSwept = true
        writesSinceSweep = 0

        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ), entries.count > Self.maximumEntryCount else {
            return
        }

        let dated = entries.map { url in
            let written = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            return (url: url, written: written ?? .distantPast)
        }
        .sorted { $0.written < $1.written }

        for entry in dated.prefix(entries.count - Self.maximumEntryCount) {
            try? fileManager.removeItem(at: entry.url)
        }
    }
}
