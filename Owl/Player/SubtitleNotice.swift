import Foundation

/// A subtitle change worth a word over the picture.
///
/// Every one of these can be made without opening a menu — from a key, or by
/// dropping a file on the window — and a change nobody asked to see happen has
/// to say so, or the subtitles appear to have shifted, resized or swapped
/// themselves. Carries the value rather than the sentence: the wording belongs
/// to the view that draws it.
enum SubtitleNotice: Equatable, Sendable {
    case delay(Double)
    case scale(Double)
    case track(String)
}
