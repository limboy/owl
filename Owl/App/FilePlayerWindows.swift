import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The windows opened on a single file.
///
/// A file opened from the File menu, from the Finder, or by dropping it on the
/// browser gets a window of its own instead of taking over the folder window.
/// The folder window keeps its queue, its place in it, and whatever it was
/// playing; only what can be heard is given up, since two soundtracks at once
/// are worth less than either.
///
/// These windows are built by hand rather than declared as a `WindowGroup`.
/// Opening one has to work from the app delegate, where the Finder's files
/// arrive and where SwiftUI's `openWindow` cannot be reached, and each window
/// owns a player — an mpv handle, a GL surface — that has to be torn down in a
/// definite order as the window closes.
@MainActor
final class FilePlayerWindows {
    static let shared = FilePlayerWindows()

    /// Keyed on the file, so asking for the same one twice raises the window
    /// that already has it rather than decoding it a second time.
    private var controllers: [URL: PlayerWindowController] = [:]

    /// Where the next window goes, so a second file does not land exactly on top
    /// of the first.
    private var cascadePoint: NSPoint?

    private init() {}

    func open(_ rawURL: URL) {
        let url = rawURL.standardizedFileURL
        RecentFiles.shared.record(url)
        PlaybackProgressStore.shared.setQueueDirectory(nil, for: url)
        if let existing = controllers[url] {
            existing.show()
            return
        }

        let appModel = AppModel(folderLibrary: nil)
        let controller = PlayerWindowController(
            appModel: appModel,
            ownership: .owned,
            frameAutosaveName: "FilePlayerWindowFrame",
            rootView: FilePlayerView(url: url, appModel: appModel)
        ) { [weak self] in
            self?.controllers[url] = nil
        }
        controller.setTitle(for: url)
        // The first window of the run takes the frame the last one was left at;
        // the ones opened while it is still up step down from it instead.
        let previousCorner = controllers.isEmpty ? nil : cascadePoint
        controllers[url] = controller
        cascadePoint = controller.place(after: previousCorner)
        controller.show()
    }

    /// Asks for a file and opens it. The panel lists what the browser would list
    /// in a folder: the containers the system knows are video, and the ones only
    /// mpv does.
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audiovisualContent]
            + FolderLibrary.videoExtensions.compactMap { UTType(filenameExtension: $0) }

        panel.presentAsSheet { urls in
            guard let url = urls.first else { return }
            self.open(url)
        }
    }
}
