import Foundation

/// A change worth a word over the picture.
///
/// Every one of these can be made without opening a menu — from a key, the
/// menu bar, the media keys, or by dropping a file on the window — and a change
/// made where nothing on screen shows it has to say so. With the controls
/// hidden, and always in full screen, the volume, the speed and the subtitles
/// would otherwise appear to have shifted by themselves, and a seek would have
/// nothing to say where it landed. Carries the value rather than the sentence:
/// the wording belongs to the view that draws it.
enum PlayerNotice: Equatable, Sendable {
    case subtitleDelay(Double)
    case subtitleScale(Double)
    case subtitleTrack(String)
    /// The level asked for, 0 to 100, and whether sound is muted regardless.
    case volume(Double, isMuted: Bool)
    case speed(Double)
    /// Where playback is in the file. Carries nothing because the indicator
    /// reads the live position for as long as it is up: a seek is reported
    /// before mpv has finished it, and the clock keeps moving afterwards.
    case position
}
