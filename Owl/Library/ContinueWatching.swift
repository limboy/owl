import Foundation

enum BrowserDestination: Hashable, Codable {
    case continueWatching
    case folder(UUID)
}

struct BrowserLocation: Codable, Equatable {
    var destination: BrowserDestination
    var path: [URL]

    private static let key = "BrowserLocation"

    static func load(defaults: UserDefaults = .standard) -> Self? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Rebuild the original folder queue, never a queue made from unrelated history.
/// A nil directory means the file was opened on its own (also the safe fallback
/// for records from releases that did not save playback context).
struct ContinueWatchingQueue: Equatable, Sendable {
    var videos: [URL]
    var directory: URL?

    static func resolve(for progress: PlaybackProgress) throws -> Self {
        let url = progress.url.standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard let directory = progress.queueDirectory?.standardizedFileURL,
              directory == url.deletingLastPathComponent() else {
            return Self(videos: [url], directory: nil)
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        let videos = urls.filter {
            FolderLibrary.isVideo($0)
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map(\.standardizedFileURL).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return Self(videos: videos.contains(url) ? videos : [url], directory: directory)
    }
}
