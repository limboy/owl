import Foundation

/// The language codes mpv puts on subtitle tracks, in the words a menu should
/// use for them.
enum SubtitleLanguage {
    /// mpv reports whatever the container says, which is an ISO 639 code far
    /// more often than not: "eng", "chi", sometimes "zh-Hans". A code is what
    /// mpv matches on, so it is what gets stored; this is only for reading.
    static func displayName(for code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return Locale.current.localizedString(forIdentifier: trimmed) ?? trimmed.uppercased()
    }

    /// Whether a code says anything about what language a track is in.
    ///
    /// "und" is the code for a track whose language nobody recorded. Taking it
    /// as a preference would teach mpv to look for undefined tracks on every
    /// later file, which is worse than having learned nothing.
    static func isMeaningful(_ code: String?) -> Bool {
        guard let code = code?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return !code.isEmpty && code != "und" && code != "unknown"
    }
}
