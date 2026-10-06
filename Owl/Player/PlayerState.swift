import Foundation

struct SubtitleTrack: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let language: String?
    let codec: String?
    let isExternal: Bool
    let isSelected: Bool
    /// The file an external track was loaded from, nil for an embedded one.
    /// mpv's own track ids are only meaningful while a file is open, so this
    /// is what a remembered sidecar choice is matched against on the next
    /// viewing. Mirrors mpv's `external-filename`.
    let externalURL: URL?

    init(
        id: Int64,
        title: String,
        language: String?,
        codec: String?,
        isExternal: Bool,
        isSelected: Bool,
        externalURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.codec = codec
        self.isExternal = isExternal
        self.isSelected = isSelected
        self.externalURL = externalURL
    }

    var displayName: String {
        displayName(playing: nil)
    }

    /// The name of the track beside `video`, the file it is a subtitle for.
    ///
    /// A sidecar is usually named after its video, and the video's name is
    /// most of it — the whole release name of an episode, in front of the
    /// "chs&eng" that is the only part that differs. Beside the video playing,
    /// only the part after the video's name is shown.
    func displayName(playing video: URL?) -> String {
        if !title.isEmpty {
            return title
        }
        // A sidecar mpv found on its own carries no title, and its file name
        // is the only thing that tells two of them apart — "Movie.en.srt"
        // against "Movie.zh.srt", where both would otherwise read "SRT
        // subtitle".
        if let externalURL {
            if let video, let suffix = Self.suffix(of: externalURL, after: video) {
                return suffix
            }
            return externalURL.lastPathComponent
        }
        if let language, !language.isEmpty {
            return SubtitleLanguage.displayName(for: language)
        }
        if let codec, !codec.isEmpty {
            return "\(codec.uppercased()) subtitle"
        }
        return "Subtitle \(id)"
    }

    /// What `sidecar`'s name adds to `video`'s: "chs&eng" for
    /// "Show.S01E06.chs&eng.ass" beside "Show.S01E06.mkv". Nil when the
    /// sidecar is not named after the video, or adds nothing but its type.
    private static func suffix(of sidecar: URL, after video: URL) -> String? {
        let stem = sidecar.deletingPathExtension().lastPathComponent
        let videoStem = video.deletingPathExtension().lastPathComponent
        guard !videoStem.isEmpty,
              stem.count > videoStem.count,
              stem.lowercased().hasPrefix(videoStem.lowercased())
        else { return nil }
        let rest = stem.dropFirst(videoStem.count)
        // Only at a break in the name: "Show.S01E06" is not the video of
        // "Show.S01E067.srt".
        guard let separator = rest.first, ".-_ ".contains(separator) else { return nil }
        let suffix = rest.trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
        return suffix.isEmpty ? nil : suffix
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
    /// Whether the controls over the picture are up. The window's title bar
    /// comes and goes with them, so it is published for the window to follow.
    @Published var areControlsShown = true
    @Published var isMuted = false
    @Published var isLoading = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 100
    @Published var speed: Double = 1
    /// Seconds subtitles are shifted relative to the video, positive meaning
    /// subtitles show later. Mirrors mpv's `sub-delay`.
    @Published var subtitleDelay: Double = 0
    /// What the last adjustment was, for the indicator that flashes over the
    /// picture.
    @Published var notice: PlayerNotice = .subtitleDelay(0)
    /// Bumped every time something sets `notice`, even when the new notice
    /// equals the old one (e.g. Reset at a delay of 0, or a second press of
    /// the key that shows the position). A view wanting to flash the indicator
    /// on every such action — not only when the value actually moves —
    /// observes this instead of the notice itself.
    @Published var noticeRevision = 0
    @Published var currentURL: URL?
    /// The picture's display aspect ratio — its width over its height, as it
    /// will be drawn — or nil while there is no video to take one from.
    /// Mirrors mpv's `video-out-params/aspect`.
    @Published var videoAspectRatio: Double?
    /// The picture's width and height in pixels as it will be drawn, aspect
    /// corrected, or nil while there is no video. Mirrors mpv's
    /// `video-out-params/dw` and `video-out-params/dh`.
    @Published var videoDisplayWidth: Double?
    @Published var videoDisplayHeight: Double?
    @Published var subtitles: [SubtitleTrack] = []
    @Published var audioTracks: [AudioTrack] = []
    /// The file's chapters in order, empty for a file that marks none.
    /// Mirrors mpv's `chapter-list`.
    @Published var chapters: [Chapter] = []
    @Published var errorMessage: String?

    var hasMedia: Bool {
        currentURL != nil
    }

    /// What is playing, in the words the file itself gives: its name without
    /// the extension. The player's title and the system's Now Playing panel
    /// both read this, so the two can never name the same video differently.
    var currentTitle: String? {
        currentURL?.deletingPathExtension().lastPathComponent
    }

    var selectedSubtitleID: Int64? {
        selectedSubtitle?.id
    }

    var selectedSubtitle: SubtitleTrack? {
        subtitles.first(where: \.isSelected)
    }

    /// The chapter playback is in, if the file has any.
    var currentChapter: Chapter? {
        ChapterNavigation.chapter(at: currentTime, in: chapters)
    }

    /// Announces an adjustment to the indicator. Every path that changes the
    /// subtitles, the volume or the speed, or moves the position, from
    /// anywhere but the controls that already show it goes through here, so
    /// none of them can change what is seen or heard with no word of why.
    func announce(_ notice: PlayerNotice) {
        self.notice = notice
        noticeRevision += 1
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
        chapters = []
    }

    func reset() {
        isPaused = true
        isLoading = false
        currentTime = 0
        duration = 0
        currentURL = nil
        videoAspectRatio = nil
        videoDisplayWidth = nil
        videoDisplayHeight = nil
        subtitles = []
        audioTracks = []
        chapters = []
        errorMessage = nil
    }
}
