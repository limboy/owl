import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MediaThumbnailProvider {
    static let shared = MediaThumbnailProvider()

    /// Which extractor produced a usable frame for a file. AVFoundation is
    /// tried first because it runs in process, but it cannot open many of the
    /// containers mpv plays, so those files fall back to the command line
    /// tools and remember that choice.
    private enum Extractor {
        case avFoundation
        case external
    }

    /// How far into a file a cover frame is taken from. Far enough in to clear
    /// a black leader or a studio logo, close enough that a short clip still
    /// has something there.
    static let coverSeconds = 10

    private let cache = NSCache<NSString, NSImage>()
    private let external: ExternalThumbnailRenderer
    private let coverCache: CoverImageCache
    private var extractors: [String: Extractor] = [:]
    private var filmstrips: [String: ThumbnailFilmstrip] = [:]

    init(
        external: ExternalThumbnailRenderer = ExternalThumbnailRenderer(),
        coverCache: CoverImageCache = .shared
    ) {
        self.external = external
        self.coverCache = coverCache
    }

    /// Starts filling a filmstrip for `url` so that previews are ready before
    /// anyone hovers the timeline. Calling this again for the same file is
    /// free; a different file drops the previous strip.
    func prepare(for url: URL, duration: Double) {
        guard duration.isFinite, duration > 0 else { return }
        let path = url.standardizedFileURL.path
        // The reported duration can settle by a fraction of a second after a
        // file opens. Restarting a pass over that would throw away the frames
        // it had already collected.
        if let existing = filmstrips[path], abs(existing.duration - duration) < 1 {
            return
        }
        for (key, strip) in filmstrips where key != path {
            strip.cancel()
            filmstrips[key] = nil
        }
        let filmstrip = ThumbnailFilmstrip(url: url, duration: duration, renderer: external)
        filmstrips[path] = filmstrip
        filmstrip.start()
    }

    func cancelPreparation() {
        for strip in filmstrips.values {
            strip.cancel()
        }
        filmstrips.removeAll()
    }

    /// A frame that is already in memory, or `nil` when one has to be
    /// extracted. Hovering asks for this first so the preview can follow the
    /// pointer without waiting on a process.
    func cachedImage(for url: URL, at seconds: Double) -> NSImage? {
        let path = url.standardizedFileURL.path
        if let cached = cache.object(forKey: Self.key(path: path, seconds: seconds)) {
            return cached
        }
        return filmstrips[path]?.frame(at: seconds)
    }

    /// The frame the browser shows for a file.
    ///
    /// Unlike a scrubbing frame, this is the same frame every launch for as
    /// long as the file is untouched, so it is worth keeping on disk: the
    /// browser can fill a folder from the cache instead of decoding, or
    /// spawning a process for, every file in it again.
    func coverImage(for url: URL) async -> NSImage? {
        let seconds = Double(Self.coverSeconds)
        let key = Self.key(path: url.standardizedFileURL.path, seconds: seconds)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        if let data = await coverCache.data(for: url, at: Self.coverSeconds),
           let stored = NSImage(data: data) {
            cache.setObject(stored, forKey: key)
            return stored
        }

        guard let image = await image(for: url, at: seconds) else { return nil }
        if let data = Self.jpegData(from: image) {
            await coverCache.store(data, for: url, at: Self.coverSeconds)
        }
        return image
    }

    func image(for url: URL, at seconds: Double) async -> NSImage? {
        let bucket = max(0, Int(seconds.rounded()))
        let path = url.standardizedFileURL.path
        let key = Self.key(path: path, seconds: seconds)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image: NSImage?
        switch extractors[path] {
        case .avFoundation:
            image = await Self.avFoundationImage(for: url, at: bucket)
        case .external:
            image = await external.image(for: url, at: bucket)
        case nil:
            image = await firstUsableImage(for: url, at: bucket, path: path)
        }

        guard let image else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// A cover encoded for disk. JPEG at the size these frames come back in
    /// costs a few tens of kilobytes, where the same frame as PNG runs to a
    /// megabyte, and a cover is shown small enough that the loss does not read.
    private static func jpegData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func key(path: String, seconds: Double) -> NSString {
        "\(path)#\(max(0, Int(seconds.rounded())))" as NSString
    }

    private func firstUsableImage(
        for url: URL,
        at seconds: Int,
        path: String
    ) async -> NSImage? {
        if Self.isAudiovisualType(url),
           let image = await Self.avFoundationImage(for: url, at: seconds) {
            extractors[path] = .avFoundation
            return image
        }
        guard !Task.isCancelled else { return nil }
        guard let image = await external.image(for: url, at: seconds) else { return nil }
        extractors[path] = .external
        return image
    }

    /// Whether AVFoundation claims the container at all. Asking it to open a
    /// file it does not handle, such as MKV, wastes a probe on every hover and
    /// logs decoder errors, so those files go straight to the external tool.
    static func isAudiovisualType(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        let identifiers = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
        if identifiers.contains(type.identifier) {
            return true
        }
        return type.supertypes.contains { identifiers.contains($0.identifier) }
    }

    private static func avFoundationImage(for url: URL, at seconds: Int) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: Double(seconds), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
