import Foundation

struct SubtitleDelayEntry: Codable, Equatable, Sendable {
    let url: URL
    var delaySeconds: Double
    var lastUpdated: Date
}

/// Remembers the subtitle delay chosen for each file, so reopening one that
/// needed shifting does not need re-shifting.
///
/// Mirrors `PlaybackProgressStore` in shape — one JSON file in Application
/// Support, keyed by standardized URL, capped and trimmed the same way — but
/// kept separate rather than folded into `PlaybackProgress`: a delay can be
/// set (or reset) before that file's position has ever been recorded, and
/// this store should not have to fake a position and duration to hold it.
@MainActor
final class SubtitleDelayStore: ObservableObject {
    /// The app's store. Every window shares this one, the same reasoning as
    /// `PlaybackProgressStore.shared`.
    static let shared = SubtitleDelayStore()

    @Published private(set) var entries: [SubtitleDelayEntry] = []

    private var entriesByURL: [URL: SubtitleDelayEntry] = [:]

    /// See `PlaybackProgressStore.maximumEntryCount` — same ceiling, same
    /// reasoning: entries only ever accumulate, and losing the oldest costs
    /// at most one re-adjustment.
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
                .appendingPathComponent("subtitle-delay.json")
        }
        restore()
    }

    func delay(for url: URL) -> Double? {
        entriesByURL[url.standardizedFileURL]?.delaySeconds
    }

    /// A delay of exactly zero is indistinguishable from "never set", and
    /// costs nothing to leave unset, so it is dropped rather than stored —
    /// keeping the file from growing by one entry for every video anyone
    /// merely opens and closes with Reset never touched.
    func record(url: URL, delaySeconds: Double) {
        guard delaySeconds != 0 else {
            remove(url: url)
            return
        }
        let normalizedURL = url.standardizedFileURL
        let value = SubtitleDelayEntry(
            url: normalizedURL,
            delaySeconds: delaySeconds,
            lastUpdated: Date()
        )
        if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == normalizedURL }) {
            entries[index] = value
        } else {
            entries.append(value)
        }
        entries.sort { $0.lastUpdated > $1.lastUpdated }
        entriesByURL[normalizedURL] = value
        trimToLimit()
        persist()
    }

    func remove(url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard entriesByURL[normalizedURL] != nil else { return }
        entries.removeAll { $0.url.standardizedFileURL == normalizedURL }
        entriesByURL[normalizedURL] = nil
        persist()
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storageURL),
              let values = try? JSONDecoder().decode([SubtitleDelayEntry].self, from: data)
        else {
            return
        }
        entries = values.sorted { $0.lastUpdated > $1.lastUpdated }
        entriesByURL = Dictionary(
            entries.map { ($0.url.standardizedFileURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        trimToLimit()
    }

    private func trimToLimit() {
        guard entries.count > Self.maximumEntryCount else { return }
        for dropped in entries[Self.maximumEntryCount...] {
            let key = dropped.url.standardizedFileURL
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
            // Best-effort, same as PlaybackProgressStore: losing this write
            // should never interrupt playback.
        }
    }
}
