import Foundation

/// A subtitle choice somebody made by hand, in a form that survives the file
/// being closed.
///
/// mpv's track ids only mean anything while a file is open, so a choice is
/// stored with enough beside the id to find the same track again: the language
/// and title for an embedded one, the path for a sidecar. Turning subtitles off
/// is a choice like any other and is remembered the same way.
enum SubtitleSelection: Codable, Equatable, Sendable {
    case off
    case embedded(id: Int64, language: String?, title: String)
    case external(url: URL)

    static func of(_ track: SubtitleTrack) -> SubtitleSelection {
        if let externalURL = track.externalURL {
            return .external(url: externalURL.standardizedFileURL)
        }
        return .embedded(id: track.id, language: track.language, title: track.title)
    }

    /// The language to prefer on later files, or nil if this choice says
    /// nothing about language.
    var language: String? {
        guard case .embedded(_, let language, _) = self,
              SubtitleLanguage.isMeaningful(language)
        else {
            return nil
        }
        return language
    }
}

/// What restoring a remembered choice asks of the player.
enum SubtitleRestoreAction: Equatable, Sendable {
    /// Nothing to do: no choice was remembered, what was remembered is already
    /// showing, or the track it named is not in this file any more. The last
    /// case leaves mpv's own pick alone rather than turning subtitles off,
    /// which is the better of the two guesses.
    case none
    case turnOff
    case select(id: Int64)
    case loadExternal(url: URL)
}

extension SubtitleSelection {
    /// What to do to make `selection` true of `tracks`.
    ///
    /// Kept apart from the player so the matching can be reasoned about — and
    /// tested — without a running mpv: which track a remembered choice lands on
    /// is the whole of the behaviour, and it has to be right on files that have
    /// been re-muxed, renamed or moved since.
    static func action(
        restoring selection: SubtitleSelection?,
        in tracks: [SubtitleTrack]
    ) -> SubtitleRestoreAction {
        guard let selection else { return .none }

        switch selection {
        case .off:
            return tracks.contains(where: \.isSelected) ? .turnOff : .none

        case .external(let url):
            guard let match = tracks.first(where: {
                $0.externalURL?.standardizedFileURL == url.standardizedFileURL
            }) else {
                // Not loaded yet — the usual case on the first tracks of a
                // fresh viewing, and what re-adds a sidecar mpv did not find
                // on its own.
                return .loadExternal(url: url)
            }
            return match.isSelected ? .none : .select(id: match.id)

        case .embedded(let id, let language, let title):
            let embedded = tracks.filter { !$0.isExternal }
            // The id first, because for the same file it is the same track. A
            // re-encode renumbers the tracks but usually keeps how they
            // describe themselves, and that is the next best thing to go on.
            let match = embedded.first { $0.id == id }
                ?? embedded.first { $0.language == language && $0.title == title }
            guard let match else { return .none }
            return match.isSelected ? .none : .select(id: match.id)
        }
    }

    /// The choice after `current`, going through the tracks in mpv's order and
    /// then off, which is where cycling from the last track lands.
    static func next(after current: SubtitleTrack?, in tracks: [SubtitleTrack]) -> SubtitleTrack? {
        guard !tracks.isEmpty else { return nil }
        guard let current, let index = tracks.firstIndex(where: { $0.id == current.id }) else {
            return tracks.first
        }
        let next = tracks.index(after: index)
        return next < tracks.endIndex ? tracks[next] : nil
    }
}
