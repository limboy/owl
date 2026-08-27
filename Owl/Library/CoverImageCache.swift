import CryptoKit
import Foundation

/// The still frames the browser draws as covers, kept on disk between launches.
///
/// A cover costs a decode of the file it belongs to, and for the containers
/// AVFoundation will not open, a whole ffmpeg process per file. Holding those
/// only in memory meant a folder of a hundred videos paid the full cost again
/// on every launch. Entries are keyed by what the video looked like when the
/// frame was taken, so a file that has been re-encoded or replaced renders a
/// new cover instead of showing the old one.
///
/// This deals in encoded bytes rather than images so that nothing has to hand
/// an `NSImage` across an isolation boundary; the caller does the encoding.
actor CoverImageCache {
    static let shared = CoverImageCache()

    /// How many covers to keep. Entries are only ever added, and nothing
    /// notices when a video is deleted or a volume goes away, so without a
    /// ceiling the directory grows for as long as the app is used. At a few
    /// tens of kilobytes each this is a small directory, and what falls off
    /// the end costs one re-render the next time it is looked at.
    static let maximumEntryCount = 1000

    /// How many writes to let by between sweeps. Counting the directory on
    /// every stored cover would stat the whole cache while the browser is
    /// filling in, which is exactly when it is busiest.
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
                .appendingPathComponent("Covers", isDirectory: true)
        }
    }

    /// The stored cover for `url`, or `nil` when there is none for the file as
    /// it stands right now.
    func data(for url: URL, at seconds: Int) -> Data? {
        guard let name = entryName(for: url, at: seconds) else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    func store(_ data: Data, for url: URL, at seconds: Int) {
        guard !data.isEmpty, let name = entryName(for: url, at: seconds) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            // A cover that cannot be written is simply rendered again later;
            // a full or read-only cache directory is not worth reporting.
            return
        }

        writesSinceSweep += 1
        if !hasSwept || writesSinceSweep >= Self.sweepInterval {
            sweep()
        }
    }

    /// The file name a cover lives under, or `nil` when the video cannot be
    /// measured — a file that is gone or unreadable has no identity to key on,
    /// and keying on its path alone would serve a stale frame after an edit.
    private func entryName(for url: URL, at seconds: Int) -> String? {
        // Measured through a URL built here rather than the one passed in: a
        // URL caches the resource values it has been asked for, and one held by
        // the browser since launch would report the size and date the file had
        // back then, which is exactly the staleness this key exists to catch.
        let path = url.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else {
            return nil
        }

        let identity = [
            path,
            String(size),
            String(modified.timeIntervalSince1970),
            String(seconds),
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// Drops the oldest covers once the directory is over its ceiling. Age is
    /// taken from when a cover was written rather than when it was last read:
    /// reading is the common case, and touching a file on every browser draw
    /// would turn a cache hit back into a write.
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

/// Which file inside a folder supplied that folder's cover.
///
/// Finding one means walking the folder until a video turns up, and for a deep
/// tree on a slow volume that walk, not the frame extraction, is the expensive
/// part of drawing a browser row. The answer barely changes, so it is
/// remembered across launches and only looked for again once the file it names
/// has gone.
actor FolderCoverIndex {
    static let shared = FolderCoverIndex()

    /// How many folders to remember, oldest answers first out. Deliberately
    /// generous: an entry is two paths, and a browser that has to rescan a
    /// folder is back to the walk this exists to avoid.
    static let maximumEntryCount = 500

    private struct Entry: Codable {
        let folder: String
        let video: String
    }

    private let storageURL: URL
    private let fileManager: FileManager
    private var entries: [Entry] = []
    private var hasRestored = false

    init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.storageURL = caches
                .appendingPathComponent("Owl", isDirectory: true)
                .appendingPathComponent("Covers", isDirectory: true)
                .appendingPathComponent("folders.json")
        }
    }

    /// The remembered video for `folder`, if it is still there. A file that has
    /// been moved or deleted is dropped so the caller walks the folder again.
    func video(for folder: URL) -> URL? {
        restoreIfNeeded()
        let key = folder.standardizedFileURL.path
        guard let index = entries.firstIndex(where: { $0.folder == key }) else { return nil }

        let video = URL(fileURLWithPath: entries[index].video)
        guard fileManager.fileExists(atPath: video.path) else {
            entries.remove(at: index)
            persist()
            return nil
        }
        return video
    }

    func setVideo(_ video: URL, for folder: URL) {
        restoreIfNeeded()
        let key = folder.standardizedFileURL.path
        entries.removeAll { $0.folder == key }
        entries.insert(
            Entry(folder: key, video: video.standardizedFileURL.path),
            at: 0
        )
        if entries.count > Self.maximumEntryCount {
            entries.removeSubrange(Self.maximumEntryCount...)
        }
        persist()
    }

    private func restoreIfNeeded() {
        guard !hasRestored else { return }
        hasRestored = true
        guard let data = try? Data(contentsOf: storageURL),
              let restored = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            return
        }
        entries = Array(restored.prefix(Self.maximumEntryCount))
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Losing the index only costs another walk on the next launch.
        }
    }
}
