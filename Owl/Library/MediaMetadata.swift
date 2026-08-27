import AVFoundation
import CryptoKit
import Foundation

struct MediaMetadata: Codable, Equatable, Sendable {
    let fileSize: Int64
    let duration: Double?
    let width: Int?
    let height: Int?
    let frameRate: Double?

    /// What is worth saying about the file, in reading order, leaving out
    /// anything it did not answer for.
    ///
    /// Kept as pieces rather than one string because the status bar showing
    /// them drops the later ones when the window is too narrow to hold them
    /// all, and the running time is the one to keep longest.
    var summaryParts: [String] {
        var parts: [String] = []
        if let duration, duration.isFinite, duration > 0 {
            parts.append(Self.timeString(duration))
        }
        if let width, let height, width > 0, height > 0 {
            parts.append("\(width)×\(height)")
        }
        if let frameRate, frameRate.isFinite, frameRate > 0 {
            parts.append(String(format: "%.2g fps", frameRate))
        }
        if fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        }
        return parts
    }

    private static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    /// Reads what the file has to say about itself.
    ///
    /// AVFoundation answers first, and for a Matroska, AVI or WebM file it
    /// answers nothing at all: it cannot open those containers, so there is no
    /// duration and no video track to ask about the picture, however ordinary
    /// the contents. The row was left showing a file size and four blanks. When
    /// that happens the question goes to ffprobe or mpv instead, the same tools
    /// the thumbnails already fall back to. With neither installed the row
    /// keeps its file size, which is read from the filesystem and does not
    /// depend on anything being able to open the file.
    static func load(
        for url: URL,
        cache: MediaMetadataCache = .shared
    ) async -> MediaMetadata? {
        let url = url.standardizedFileURL
        if let cached = await cache.metadata(for: url) {
            return cached
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? .nan
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let videoTrack = videoTracks.first
        let naturalSize = try? await videoTrack?.load(.naturalSize)
        var width = naturalSize.map { Int(abs($0.width.rounded())) }
        var height = naturalSize.map { Int(abs($0.height.rounded())) }
        var frameRate = (try? await videoTrack?.load(.nominalFrameRate)).map(Double.init)
        var seconds = duration.isFinite && duration > 0 ? duration : nil

        if videoTrack == nil || seconds == nil,
           let probed = await ExternalMediaProbe.metadata(for: url) {
            seconds = seconds ?? probed.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            width = width ?? probed.width
            height = height ?? probed.height
            frameRate = frameRate ?? probed.frameRate
        }

        if fileSize == 0, seconds == nil, width == nil {
            return nil
        }
        let metadata = MediaMetadata(
            fileSize: fileSize,
            duration: seconds,
            width: width,
            height: height,
            frameRate: frameRate
        )
        // Do not make a temporary parser or tool failure persistent. A file
        // size alone is cheap to recover and is not parsed media metadata.
        if seconds != nil || width != nil || height != nil || frameRate != nil {
            await cache.store(metadata, for: url)
        }
        return metadata
    }
}

/// Parsed media facts kept on disk between launches.
///
/// Parsing can start an ffprobe or mpv process for every video in a folder.
/// The cache key includes the file's size and modification date, so reopening
/// an unchanged folder is cheap while a replaced or re-encoded file is parsed
/// again.
actor MediaMetadataCache {
    static let shared = MediaMetadataCache()
    static let maximumEntryCount = 2_000

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
                .appendingPathComponent("Metadata", isDirectory: true)
        }
    }

    func metadata(for url: URL) -> MediaMetadata? {
        guard let entryURL = entryURL(for: url),
              let data = try? Data(contentsOf: entryURL)
        else {
            return nil
        }
        return try? JSONDecoder().decode(MediaMetadata.self, from: data)
    }

    func store(_ metadata: MediaMetadata, for url: URL) {
        guard let entryURL = entryURL(for: url),
              let data = try? JSONEncoder().encode(metadata)
        else {
            return
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: entryURL, options: .atomic)
        } catch {
            // A failed cache write only means the file is parsed next time.
            return
        }

        writesSinceSweep += 1
        if !hasSwept || writesSinceSweep >= Self.sweepInterval {
            sweep()
        }
    }

    private func entryURL(for url: URL) -> URL? {
        // URL caches resource values. Rebuild it from the path so a URL kept by
        // the browser cannot make an edited file look unchanged.
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
            String(modified.timeIntervalSince1970)
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8))
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
