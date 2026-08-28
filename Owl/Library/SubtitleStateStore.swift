import Foundation

struct SubtitleStateEntry: Codable, Equatable, Sendable {
    let url: URL
    var delaySeconds: Double
    /// The track chosen by hand for this file, or nil if the choice was never
    /// taken away from mpv.
    var selection: SubtitleSelection?
    var lastUpdated: Date

    /// Whether the entry says anything worth keeping. A file watched with
    /// whatever mpv picked, unshifted, is the ordinary case and needs no row
    /// of its own.
    var isDefault: Bool {
        delaySeconds == 0 && selection == nil
    }
}

/// Remembers how subtitles were set up for each file — which track, and how far
/// it was shifted — so reopening one that needed fixing does not need fixing
/// again.
///
/// Mirrors `PlaybackProgressStore` in shape — one JSON file in Application
/// Support, keyed by standardized URL, capped and trimmed the same way — but
/// kept separate rather than folded into `PlaybackProgress`: a choice can be
/// made (or reset) before that file's position has ever been recorded, and
/// this store should not have to fake a position and duration to hold it.
@MainActor
final class SubtitleStateStore: ObservableObject {
    /// The app's store. Every window shares this one, the same reasoning as
    /// `PlaybackProgressStore.shared`.
    static let shared = SubtitleStateStore()

    @Published private(set) var entries: [SubtitleStateEntry] = []

    private var entriesByURL: [URL: SubtitleStateEntry] = [:]

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
                // Named for the delay because that is all it once held. The
                // file is somebody's existing adjustments, and a new name
                // would silently throw them away for a tidier one.
                .appendingPathComponent("subtitle-delay.json")
        }
        restore()
    }

    func delay(for url: URL) -> Double? {
        entriesByURL[url.standardizedFileURL]?.delaySeconds
    }

    func selection(for url: URL) -> SubtitleSelection? {
        entriesByURL[url.standardizedFileURL]?.selection
    }

    func recordDelay(url: URL, delaySeconds: Double) {
        update(url: url) { $0.delaySeconds = delaySeconds }
    }

    func recordSelection(url: URL, selection: SubtitleSelection?) {
        update(url: url) { $0.selection = selection }
    }

    func remove(url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard entriesByURL[normalizedURL] != nil else { return }
        entries.removeAll { $0.url.standardizedFileURL == normalizedURL }
        entriesByURL[normalizedURL] = nil
        persist()
    }

    /// Applies `change` to this file's entry, making one if there is none, and
    /// dropping it again if what is left is what a file gets anyway — keeping
    /// the file from growing by a row for every video merely opened and closed
    /// with Reset never touched.
    private func update(url: URL, change: (inout SubtitleStateEntry) -> Void) {
        let normalizedURL = url.standardizedFileURL
        var entry = entriesByURL[normalizedURL] ?? SubtitleStateEntry(
            url: normalizedURL,
            delaySeconds: 0,
            selection: nil,
            lastUpdated: Date()
        )
        change(&entry)
        guard !entry.isDefault else {
            remove(url: normalizedURL)
            return
        }
        entry.lastUpdated = Date()

        if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == normalizedURL }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.lastUpdated > $1.lastUpdated }
        entriesByURL[normalizedURL] = entry
        trimToLimit()
        persist()
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storageURL),
              let values = try? JSONDecoder().decode([SubtitleStateEntry].self, from: data)
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
