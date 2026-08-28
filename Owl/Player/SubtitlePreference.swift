import Foundation

/// How subtitles should behave before this particular file has anything to say
/// about it. Per-file choices live in `SubtitleStateStore`; what is here is
/// what applies to a file being opened for the first time.
enum SubtitlePreference {
    /// Whether a file nobody has watched yet should open with a subtitle
    /// showing.
    ///
    /// Not a setting anybody sets: it is the last answer given to the subtitle
    /// button, which is the same question. Choosing Disabled says subtitles are
    /// not wanted; choosing a track says they are; and a file opened for the
    /// first time has nothing else to go on. Somebody who never wants them
    /// chooses Disabled once rather than once per file, and one track picked by
    /// hand undoes it.
    ///
    /// Which track shows stays mpv's decision — this only says whether it gets
    /// to make one. A file that has been watched before overrules it either
    /// way, from `SubtitleStateStore`.
    static let defaultsKey = "SubtitlesEnabledByDefault"

    /// The language of the last subtitle track chosen by hand, if it had one.
    ///
    /// Choosing the Japanese track on episode one says something about episode
    /// two, which no per-file memory can carry: the second episode has never
    /// been opened. Handing the code to mpv as `slang` lets mpv apply it the
    /// way it applies every other track preference — this is a hint about
    /// language, not an instruction to select a particular track, so a forced
    /// or default flag still wins where one exists.
    static let languageKey = "PreferredSubtitleLanguage"

    /// A multiplier on however large mpv would draw subtitles, mirroring
    /// mpv's `sub-scale`. One preference for the app rather than one per file:
    /// how big text has to be to be read from the sofa is about the sofa.
    static let scaleKey = "SubtitleScale"

    /// How far one press or one menu item moves the subtitle delay.
    static let delayStep: Double = 0.25

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var preferredLanguage: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: languageKey)?
                .trimmingCharacters(in: .whitespaces)
            guard let stored, !stored.isEmpty else { return nil }
            return stored
        }
        set {
            // Empty rather than removed, because the view's @AppStorage
            // binding writes the same key and reads a missing value as empty.
            UserDefaults.standard.set(newValue ?? "", forKey: languageKey)
        }
    }

    static let scaleRange: ClosedRange<Double> = 0.5...3
    static let scaleStep: Double = 0.1

    static var scale: Double {
        get {
            guard let stored = UserDefaults.standard.object(forKey: scaleKey) as? Double,
                  stored > 0
            else {
                return 1
            }
            return min(max(stored, scaleRange.lowerBound), scaleRange.upperBound)
        }
        set {
            let clamped = min(max(newValue, scaleRange.lowerBound), scaleRange.upperBound)
            // Rounded to the step, so a run of ten increases lands on exactly
            // 2 rather than on 1.9999999999999998.
            let stepped = (clamped / scaleStep).rounded() * scaleStep
            UserDefaults.standard.set(stepped, forKey: scaleKey)
        }
    }
}
