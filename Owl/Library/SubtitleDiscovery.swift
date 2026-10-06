import Foundation

/// Finds the subtitle files beside a video that mpv does not find itself.
///
/// mpv takes a sidecar whose name contains the video's: `Movie.en.srt` for
/// `Movie.mkv`. Subtitles fetched separately are named for a different
/// release of the same thing — `Mad.Men.S01E01.….NOGRP.chs&eng.ass` beside
/// `Mad Men.S01E01 - Smoke Gets in Your Eyes (… LION).mkv` — and share no
/// more of the name than the show and the episode. Those are what this
/// matches on: the title read out of both names, and the season and episode,
/// or the year for a film.
enum SubtitleDiscovery {
    /// The folders beside a video that are searched along with its own: the
    /// ones mpv is told to look in as well.
    static let subtitleFolderNames: Set<String> = [
        "sub", "subs", "subtitle", "subtitles"
    ]

    /// The subtitle files near `video` that name the same episode or film and
    /// that mpv will not have loaded by itself. Reads the disk.
    static func subtitles(for video: URL) -> [URL] {
        let directory = video.deletingLastPathComponent()
        var files = contents(of: directory)
        for folder in files where subtitleFolderNames.contains(folder.lastPathComponent.lowercased()) {
            files += contents(of: folder)
        }
        return matches(for: video, among: files)
    }

    /// The files out of `files` that are subtitles for `video`, in name order.
    static func matches(for video: URL, among files: [URL]) -> [URL] {
        guard let guess = VideoTitleGuess.parse(video) else { return [] }
        let videoStem = video.deletingPathExtension().lastPathComponent.lowercased()

        return files
            .filter(SubtitleFile.isSubtitle)
            // mpv's own fuzzy match: a name with the video's in it is loaded
            // already, and adding it again would list it twice.
            .filter { !$0.lastPathComponent.lowercased().contains(videoStem) }
            .filter { subtitle in
                guard let other = VideoTitleGuess.parse(
                    name: subtitle.deletingPathExtension().lastPathComponent
                ) else { return false }
                return names(other, sameAs: guess)
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    /// Whether a subtitle's name and a video's name are of the same thing.
    ///
    /// An episode has to be the same episode, and the same show unless the
    /// subtitle names only the episode — "S01E01.srt" in a show's folder. A
    /// film has to have the same title, and the same year where both say.
    private static func names(_ subtitle: VideoTitleGuess, sameAs video: VideoTitleGuess) -> Bool {
        let subtitleTitle = normalized(subtitle.title)
        let videoTitle = normalized(video.title)

        if video.isEpisode {
            guard subtitle.season == video.season, subtitle.episode == video.episode else {
                return false
            }
            return subtitleTitle.isEmpty || subtitleTitle == videoTitle
        }

        guard !subtitle.isEpisode, !videoTitle.isEmpty, subtitleTitle == videoTitle else {
            return false
        }
        if let subtitleYear = subtitle.year, let videoYear = video.year {
            return subtitleYear == videoYear
        }
        return true
    }

    /// A title with only its letters and digits, in lower case, so that
    /// "Mad.Men", "Mad Men" and "mad_men" are one title.
    private static func normalized(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}
