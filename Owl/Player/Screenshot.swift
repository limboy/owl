import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where a screenshot of the picture goes, what it is called, and whether the
/// subtitles are in it.
enum Screenshot {
    /// Whether a screenshot has the subtitles drawn on it, the way they show
    /// over the picture, or is the bare frame. One preference for the app:
    /// whether a still is wanted with its line or without is about what the
    /// stills are for, not about any one file.
    static let includesSubtitlesKey = "ScreenshotIncludesSubtitles"

    static var includesSubtitles: Bool {
        get { UserDefaults.standard.object(forKey: includesSubtitlesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: includesSubtitlesKey) }
    }

    /// The folder macOS saves its own screenshots to — the one chosen in the
    /// Screenshot app's Options, which is the Desktop until somebody picks
    /// another — so a still of a video lands beside every other screenshot.
    static func folder(
        screencaptureDefaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture"),
        fileManager: FileManager = .default
    ) -> URL {
        if let location = screencaptureDefaults?.string(forKey: "location"),
           !location.isEmpty {
            let url = URL(
                fileURLWithPath: (location as NSString).expandingTildeInPath,
                isDirectory: true
            )
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url
            }
        }
        return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    /// A PNG in `folder` named for the video and the moment in it, such as
    /// "Smoke Gets in Your Eyes 0.12.34.png", numbered after the first so a
    /// second still of the same frame never replaces the first. Periods rather
    /// than colons between the numbers, as macOS names its own screenshots:
    /// Finder shows a colon in a file name as a slash.
    static func fileURL(
        for video: URL,
        at seconds: Double,
        in folder: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let name = "\(video.deletingPathExtension().lastPathComponent) \(timestamp(seconds))"
        var candidate = folder.appendingPathComponent("\(name).png")
        var number = 2
        while fileExists(candidate) {
            candidate = folder.appendingPathComponent("\(name) \(number).png")
            number += 1
        }
        return candidate
    }

    /// Writes `image` to `url` as a PNG, saying whether it could.
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%d.%02d.%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }
}
