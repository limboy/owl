import Foundation

struct SubtitleTrack: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let language: String?
    let codec: String?
    let isExternal: Bool
    let isSelected: Bool

    var displayName: String {
        if !title.isEmpty {
            return title
        }
        if let language, !language.isEmpty {
            return language.uppercased()
        }
        if let codec, !codec.isEmpty {
            return "\(codec.uppercased()) subtitle"
        }
        return "Subtitle \(id)"
    }
}

struct AudioTrack: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let language: String?
    let codec: String?
    let isExternal: Bool
    let isSelected: Bool

    var displayName: String {
        if !title.isEmpty {
            return title
        }
        if let language, !language.isEmpty {
            return language.uppercased()
        }
        if let codec, !codec.isEmpty {
            return codec.uppercased()
        }
        return "Audio \(id)"
    }
}

@MainActor
final class PlayerState: ObservableObject {
    @Published var isPaused = true
    @Published var isMuted = false
    @Published var isLoading = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 100
    @Published var speed: Double = 1
    /// Seconds subtitles are shifted relative to the video, positive meaning
    /// subtitles show later. Mirrors mpv's `sub-delay`.
    @Published var subtitleDelay: Double = 0
    /// Bumped every time the subtitle delay menu changes `subtitleDelay`,
    /// even when the new value equals the old one (e.g. Reset at 0). A view
    /// wanting to flash a "delay changed" indicator on every such action —
    /// not only when the number actually moves — observes this instead of
    /// `subtitleDelay` itself.
    @Published var subtitleDelayRevision = 0
    @Published var currentURL: URL?
    /// The picture's display aspect ratio — its width over its height, as it
    /// will be drawn — or nil while there is no video to take one from.
    /// Mirrors mpv's `video-out-params/aspect`.
    @Published var videoAspectRatio: Double?
    @Published var subtitles: [SubtitleTrack] = []
    @Published var audioTracks: [AudioTrack] = []
    @Published var errorMessage: String?

    var hasMedia: Bool {
        currentURL != nil
    }

    var selectedSubtitleID: Int64? {
        subtitles.first(where: \.isSelected)?.id
    }

    /// `startAt` is where the file is about to resume, if anywhere, so the
    /// clock reads that immediately rather than at 0 for the moment before
    /// mpv reports the real position it opened at.
    func resetForLoad(_ url: URL, startAt seconds: Double? = nil) {
        currentURL = url
        currentTime = seconds ?? 0
        duration = 0
        // Loading a file always asks mpv for `pause=no`, but mpv only reports
        // `pause` when the value actually flips, so an already-unpaused player
        // answers with silence. Seed the mirror here or a stale `true` left by
        // reset() survives into playback and the button keeps showing "Play".
        isPaused = false
        isLoading = true
        errorMessage = nil
        subtitles = []
        audioTracks = []
    }

    func reset() {
        isPaused = true
        isLoading = false
        currentTime = 0
        duration = 0
        currentURL = nil
        videoAspectRatio = nil
        subtitles = []
        audioTracks = []
        errorMessage = nil
    }
}
