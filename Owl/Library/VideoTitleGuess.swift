import Foundation

/// What a file name appears to be naming, so an online catalogue can be asked
/// about it.
///
/// Downloaded video is named for the people who share it rather than for the
/// people who watch it: `The.Expanse.S01E02.1080p.WEB-DL.x265-GROUP.mkv` says
/// what the episode is, but only after the resolution, the source, the codec
/// and the group have been taken back off. This turns such a name into the
/// small number of facts a search needs — a title, and either a year or a
/// season and episode.
struct VideoTitleGuess: Equatable, Sendable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?

    /// Whether this names one episode of a series rather than a film. The two
    /// go to different searches, so the distinction is the season and episode
    /// being there at all.
    var isEpisode: Bool {
        season != nil && episode != nil
    }

    /// Tokens that describe the encode rather than the work. Anything from the
    /// first of these onwards is dropped, because everything a release name
    /// carries after the title is of this kind.
    private static let noiseTokens: Set<String> = [
        "1080p", "1080i", "2160p", "720p", "480p", "576p", "4k", "8k", "uhd",
        "hd", "sd", "hdr", "hdr10", "sdr", "dv", "10bit",
        "8bit", "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx",
        "bluray", "blueray", "brrip", "bdrip", "bdremux", "remux", "webrip",
        "web", "webdl", "hdtv", "pdtv", "dvdrip", "dvdscr", "dvd", "hdrip",
        "cam", "camrip", "telesync", "screener", "proper", "repack", "internal",
        "limited", "extended", "unrated", "uncut", "remastered", "directors",
        "aac", "aac2", "ac3", "eac3", "dts", "dtshd", "truehd", "atmos", "flac",
        "mp3", "opus", "2ch", "6ch", "amzn", "nf", "netflix", "hulu",
        "dsnp", "hmax", "atvp", "ita", "eng", "multi", "dual", "subs", "sub",
        "dubbed", "complete", "season",
    ]

    /// Reads a file's name, and where the name says too little, the name of the
    /// folder holding it.
    ///
    /// A series is often stored as a folder named for the show with files named
    /// only for their episode number, so `Show Name/03.mkv` has to borrow its
    /// title from one level up. The same borrowing answers `.../Movie (2014)/
    /// video_ts.mp4`, where the file name says nothing at all.
    static func parse(_ url: URL) -> VideoTitleGuess? {
        let name = url.deletingPathExtension().lastPathComponent
        let own = parse(name: name)

        let parentName = url.deletingLastPathComponent().lastPathComponent
        let folder = parentName.isEmpty ? nil : parse(name: parentName)
        guard let folder, !folder.title.isEmpty else { return own }

        // A file named for nothing but its number — "03.mkv" — is an episode of
        // whatever the folder names. Checked before the file's own reading,
        // because that reading takes the number for a title.
        if let number = bareNumber(name) {
            return VideoTitleGuess(
                title: folder.title,
                year: folder.year,
                season: own?.season ?? folder.season ?? 1,
                episode: number
            )
        }

        guard let own else { return folder }
        if !own.title.isEmpty { return own }

        // A file that carries an episode marker and nothing else — "S02E05.mkv"
        // — keeps its numbers and takes the show's name from the folder.
        return VideoTitleGuess(
            title: folder.title,
            year: folder.year ?? own.year,
            season: own.season,
            episode: own.episode
        )
    }

    /// Reads one name, with nothing else to fall back on.
    static func parse(name rawName: String) -> VideoTitleGuess? {
        let name = stripBracketedGroups(rawName)
        let separated = separateWords(name)

        if let episode = parseEpisode(separated) {
            return episode
        }

        let tokens = separated.split(separator: " ").map(String.init)
        var titleTokens: [String] = []
        var year: Int?

        for token in tokens {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}-–—.,"))
            if cleaned.isEmpty { continue }
            if let value = releaseYear(cleaned) {
                // The first year that follows at least one word of title. A
                // name that opens with a year — "2012.2009.1080p.mkv" — is
                // naming the film 2012, not the year 2012.
                if !titleTokens.isEmpty {
                    year = value
                    break
                }
            }
            if noiseTokens.contains(cleaned.lowercased()) {
                break
            }
            titleTokens.append(cleaned)
        }

        let title = trimSeparators(titleTokens.joined(separator: " "))
        guard !title.isEmpty else { return nil }
        return VideoTitleGuess(title: title, year: year, season: nil, episode: nil)
    }

    /// The `S01E02`, `1x02` and `Season 1 Episode 2` forms, which is nearly all
    /// of what episodes are named as. Everything before the marker is the show.
    private static func parseEpisode(_ name: String) -> VideoTitleGuess? {
        let patterns = [
            #"(?i)\bs\s?(\d{1,2})\s?[\s._-]?\s?e\s?(\d{1,3})\b"#,
            #"(?i)\b(\d{1,2})x(\d{1,3})\b"#,
            #"(?i)\bseason\s*(\d{1,2})\s*episode\s*(\d{1,3})\b"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: name,
                      range: NSRange(name.startIndex..., in: name)
                  ),
                  match.numberOfRanges == 3,
                  let seasonRange = Range(match.range(at: 1), in: name),
                  let episodeRange = Range(match.range(at: 2), in: name),
                  let season = Int(name[seasonRange]),
                  let episode = Int(name[episodeRange]),
                  let markerRange = Range(match.range, in: name)
            else {
                continue
            }

            let leading = String(name[name.startIndex..<markerRange.lowerBound])
            let split = splitTrailingYear(leading)
            return VideoTitleGuess(
                title: split.title,
                year: split.year,
                season: season,
                episode: episode
            )
        }
        return nil
    }

    /// Turns the separators release names use into spaces. Dots are the usual
    /// one, but only where the name is not already spaced: `Mr. Robot S01E01`
    /// would otherwise lose nothing, while `Mr.Robot.S01E01` has to be split.
    private static func separateWords(_ name: String) -> String {
        var value = name.replacingOccurrences(of: "_", with: " ")
        if !value.contains(" ") {
            value = value.replacingOccurrences(of: ".", with: " ")
        }
        return value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Drops `[group]` and `{edition}` runs wholesale. They are never part of a
    /// title and their contents are arbitrary enough that token matching cannot
    /// be relied on to catch them.
    private static func stripBracketedGroups(_ name: String) -> String {
        name.replacingOccurrences(
            of: #"[\[\{][^\]\}]*[\]\}]"#,
            with: " ",
            options: .regularExpression
        )
    }

    /// Separates a show's name from the year used to tell it from another show
    /// of the same name — "Mad Men (2007)" and "Doctor Who 2005" both name a
    /// series whose title is the part in front.
    ///
    /// The year is kept rather than merely dropped, because it is the same
    /// disambiguation the catalogue does. What matters more is that it leaves:
    /// searching for "Mad Men (2007" finds nothing at all, where "Mad Men"
    /// finds the show.
    private static func splitTrailingYear(_ raw: some StringProtocol) -> (title: String, year: Int?) {
        let title = trimSeparators(raw)
        guard let regex = try? NSRegularExpression(
                  pattern: #"^(.*?)[\s._-]*[(\[]?(\d{4})[)\]]?$"#
              ),
              let match = regex.firstMatch(
                  in: title,
                  range: NSRange(title.startIndex..., in: title)
              ),
              let headRange = Range(match.range(at: 1), in: title),
              let yearRange = Range(match.range(at: 2), in: title),
              let year = releaseYear(String(title[yearRange]))
        else {
            return (title, nil)
        }

        // "2012" is a title with nothing in front of it, not a year.
        let head = trimSeparators(title[headRange])
        guard !head.isEmpty else { return (title, nil) }
        return (head, year)
    }

    /// Tidies a stretch of a name into a title.
    ///
    /// Deliberately does not touch dots: `separateWords` has already turned
    /// them into spaces wherever they were separators, so any that remain are
    /// punctuation — the ones in "Mr. Robot". Nor does it trim brackets, which
    /// it used to do at one end only: that turned "Mad Men (2007) - " into
    /// "Mad Men (2007", an unbalanced fragment that matched nothing.
    private static func trimSeparators(_ raw: some StringProtocol) -> String {
        String(raw)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:.,"))
    }

    /// A four digit number that could be a release year rather than part of a
    /// title.
    ///
    /// The upper end is what keeps `Blade Runner 2049` whole: a year that has
    /// not arrived cannot be the year something was released, so it is read as
    /// part of the name — and the 2017 that follows it in a release name still
    /// is the release year. A couple of years of headroom covers a film
    /// announced before it is out.
    private static func releaseYear(_ token: String) -> Int? {
        guard token.count == 4, let value = Int(token) else { return nil }
        return (1_900...(currentYear + 2)).contains(value) ? value : nil
    }

    private static var currentYear: Int {
        Calendar(identifier: .gregorian).component(.year, from: Date())
    }

    /// The episode number in a file named only for it — "03", "Episode 3",
    /// "E03" — and nothing for a name that says more than that.
    private static func bareNumber(_ name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let pattern = #"(?i)^(?:e|ep|episode)?\s*[._-]?\s*(\d{1,3})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: trimmed,
                  range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let range = Range(match.range(at: 1), in: trimmed)
        else {
            return nil
        }
        return Int(trimmed[range])
    }
}
