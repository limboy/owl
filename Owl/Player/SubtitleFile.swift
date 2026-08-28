import AppKit
import Foundation
import UniformTypeIdentifiers

/// What Owl takes for a subtitle file.
///
/// The one list behind both ways of attaching one — the open panel and dropping
/// a file on the picture — so the two can never disagree about what counts.
/// Mirrors `FolderLibrary.videoExtensions` in shape and in purpose.
enum SubtitleFile {
    static let extensions: Set<String> = [
        "ass", "idx", "lrc", "sbv", "smi", "srt", "ssa", "sub", "sup", "ttml",
        "vtt"
    ]

    static func isSubtitle(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// The same list as content types, for an open panel to grey out everything
    /// else with.
    ///
    /// Empty means "every file", and that is deliberately what an unresolvable
    /// extension falls back to: the system has no declared type for several of
    /// these, and a panel that quietly refuses to open the file somebody came
    /// to it for is worse than one that offers too much.
    static var contentTypes: [UTType] {
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        return types.count == extensions.count ? types : []
    }

    /// Asks for a subtitle file and hands back what was chosen, or nothing if
    /// the panel was dismissed.
    ///
    /// Here rather than in the view that used to own it, because two places
    /// ask for one now — the Subtitles menu and, through it, whichever window
    /// is in front.
    @MainActor
    static func choose(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Subtitle"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes

        panel.presentAsSheet { urls in
            guard let url = urls.first else { return }
            completion(url)
        }
    }
}
