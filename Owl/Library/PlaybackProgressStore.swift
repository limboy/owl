import Foundation

struct PlaybackProgress: Codable, Equatable, Identifiable, Sendable {
    let url: URL
    var position: Double
    var duration: Double
    var lastPlayed: Date
    var isCompleted: Bool

    var id: URL { url }

    var fraction: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

@MainActor
final class PlaybackProgressStore: ObservableObject {
    /// The app's store. Every window records into this one: how far into a file
    /// the viewer is belongs to the file, not to the window it was watched in,
    /// and two stores over one file on disk would each overwrite the other.
    static let shared = PlaybackProgressStore()

    @Published private(set) var entries: [PlaybackProgress] = []

    /// The same entries keyed for lookup. The browser asks for progress once
    /// per visible row every time the list redraws, and scanning the array
    /// meant normalizing every stored URL on each of those calls.
    private var entriesByURL: [URL: PlaybackProgress] = [:]

    /// How many files to remember. Entries are only ever added, and nothing
    /// notices when a file is deleted or a volume goes away, so without a
    /// ceiling the store grows for as long as the app is used. Cutting the
    /// oldest is safe: `entries` is kept sorted by `lastPlayed`, so what falls
    /// off the end is whatever has gone longest without being watched, and
    /// losing a resume point that old costs the viewer a seek at worst.
    static let maximumEntryCount = 500

    private let storageURL: URL

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.storageURL = applicationSupport
                .appendingPathComponent("Owl", isDirectory: true)
                .appendingPathComponent("progress.json")
        }
        restore()
    }

    func progress(for url: URL) -> PlaybackProgress? {
        entriesByURL[url.standardizedFileURL]
    }

    func record(url: URL, position: Double, duration: Double) {
        guard position.isFinite, position >= 0 else { return }
        let normalizedURL = url.standardizedFileURL
        let normalizedDuration = duration.isFinite && duration > 0 ? duration : 0
        let completed = normalizedDuration > 0
            && (position >= normalizedDuration * 0.95 || normalizedDuration - position <= 30)
        let value = PlaybackProgress(
            url: normalizedURL,
            position: min(position, normalizedDuration > 0 ? normalizedDuration : position),
            duration: normalizedDuration,
            lastPlayed: Date(),
            isCompleted: completed
        )

        if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == normalizedURL }) {
            entries[index] = value
        } else {
            entries.append(value)
        }
        entries.sort { $0.lastPlayed > $1.lastPlayed }
        entriesByURL[normalizedURL] = value
        trimToLimit()
        persist()
    }

    func markFinished(url: URL, duration: Double) {
        record(url: url, position: duration, duration: duration)
    }

    func setWatched(_ isWatched: Bool, url: URL, duration: Double?) {
        guard isWatched else {
            remove(url: url)
            return
        }

        let normalizedURL = url.standardizedFileURL
        let existing = entriesByURL[normalizedURL]
        let knownDuration = [duration, existing?.duration]
            .compactMap { $0 }
            .first { $0.isFinite && $0 > 0 } ?? 0
        let value = PlaybackProgress(
            url: normalizedURL,
            position: knownDuration,
            duration: knownDuration,
            lastPlayed: Date(),
            isCompleted: true
        )

        if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == normalizedURL }) {
            entries[index] = value
        } else {
            entries.append(value)
        }
        entries.sort { $0.lastPlayed > $1.lastPlayed }
        entriesByURL[normalizedURL] = value
        trimToLimit()
        persist()
    }

    func remove(url: URL) {
        entries.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        entriesByURL[url.standardizedFileURL] = nil
        persist()
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storageURL),
              let values = try? JSONDecoder().decode([PlaybackProgress].self, from: data)
        else {
            return
        }
        entries = values.sorted { $0.lastPlayed > $1.lastPlayed }
        entriesByURL = Dictionary(
            entries.map { ($0.url.standardizedFileURL, $0) },
            // A file recorded twice under different spellings of the same path
            // keeps the more recent entry, which sorted first.
            uniquingKeysWith: { first, _ in first }
        )
        // A file written before the limit existed, or by a newer build, can be
        // over it. Trimming on the way in keeps the ceiling honest without
        // waiting for the next thing to be watched.
        trimToLimit()
    }

    /// Drops the least recently played entries once the store is over its
    /// ceiling. Relies on `entries` already being sorted.
    private func trimToLimit() {
        guard entries.count > Self.maximumEntryCount else { return }
        for dropped in entries[Self.maximumEntryCount...] {
            let key = dropped.url.standardizedFileURL
            // A restored file can hold the same path spelled two ways, and the
            // lookup kept the more recent of them. Only clear the key when the
            // entry being dropped is the one standing in it.
            if entriesByURL[key] == dropped {
                entriesByURL[key] = nil
            }
        }
        entries.removeSubrange(Self.maximumEntryCount...)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Playback progress is best-effort and should never interrupt playback.
        }
    }
}
