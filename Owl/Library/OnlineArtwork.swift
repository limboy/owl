import AppKit
import CryptoKit
import Foundation

/// The artwork the browser draws in place of an extracted frame, once a video
/// has been matched to a catalogue entry.
///
/// Shaped like `MediaThumbnailProvider`: an in-memory cache for the folder
/// being looked at, a disk cache underneath it so a second launch does not
/// re-download, and a single fetch per image however many rows want it.
@MainActor
final class OnlineArtworkProvider {
    static let shared = OnlineArtworkProvider()

    private let cache = NSCache<NSString, NSImage>()
    private let store: OnlineArtworkStore
    private let download: @Sendable (URL) async -> Data?

    /// Downloads in flight, so a folder where several episodes share a series
    /// backdrop fetches it once rather than once per row.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(
        store: OnlineArtworkStore = .shared,
        download: @escaping @Sendable (URL) async -> Data? = OnlineArtworkProvider.fetch
    ) {
        self.store = store
        self.download = download
    }

    /// The image for a catalogue artwork path, from memory, then disk, then the
    /// image host. Nil whenever it cannot be had, which leaves the caller with
    /// whatever it was drawing before.
    func image(forArtworkPath path: String) async -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let existing = inFlight[path] {
            return await existing.value
        }

        let task = Task { [store, download] () -> NSImage? in
            if let data = await store.data(forArtworkPath: path),
               let image = NSImage(data: data) {
                return image
            }
            guard let url = TMDBClient.artworkURL(path: path),
                  let data = await download(url),
                  let image = NSImage(data: data)
            else {
                return nil
            }
            await store.store(data, forArtworkPath: path)
            return image
        }
        inFlight[path] = task

        let image = await task.value
        inFlight[path] = nil
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    private static let fetch: @Sendable (URL) async -> Data? = { url in
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return data.isEmpty ? nil : data
    }
}

/// Downloaded artwork kept on disk between launches.
///
/// Keyed by the catalogue's own path for the image, which already identifies
/// one picture and never changes meaning, so nothing here has to look at the
/// video file at all.
actor OnlineArtworkStore {
    static let shared = OnlineArtworkStore()

    /// How many pictures to keep. Rather smaller than the frame cache's
    /// ceiling: these are shared between the episodes of a series, so a given
    /// number of entries covers a good deal more video, and what falls off the
    /// end costs one download rather than one decode.
    static let maximumEntryCount = 600

    private static let sweepInterval = 32

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
                .appendingPathComponent("Artwork", isDirectory: true)
        }
    }

    func data(forArtworkPath path: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(entryName(for: path)))
    }

    func store(_ data: Data, forArtworkPath path: String) {
        guard !data.isEmpty else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(
                to: directory.appendingPathComponent(entryName(for: path)),
                options: .atomic
            )
        } catch {
            // Artwork that cannot be written is downloaded again next time.
            return
        }

        writesSinceSweep += 1
        if !hasSwept || writesSinceSweep >= Self.sweepInterval {
            sweep()
        }
    }

    private func entryName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
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
