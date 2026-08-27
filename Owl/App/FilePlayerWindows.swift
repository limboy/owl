import AppKit
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
    private var controllers: [URL: FilePlayerWindowController] = [:]

    /// Where the next window goes, so a second file does not land exactly on top
    /// of the first.
    private var cascadePoint: NSPoint?

    private init() {}

    func open(_ rawURL: URL) {
        let url = rawURL.standardizedFileURL
        if let existing = controllers[url] {
            existing.show()
            return
        }

        let controller = FilePlayerWindowController(url: url) { [weak self] in
            self?.controllers[url] = nil
        }
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

/// One window showing one file, with the player it is playing through.
@MainActor
private final class FilePlayerWindowController: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "FilePlayerWindowFrame"

    private let appModel: AppModel
    private let window: NSWindow
    private let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        appModel = AppModel(folderLibrary: nil)
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = url.lastPathComponent
        // Gives the title bar the file's icon, and its path under a click.
        window.representedURL = url
        window.contentMinSize = NSSize(width: 480, height: 300)
        window.backgroundColor = .black
        window.isOpaque = true
        window.tabbingMode = .disallowed
        // The controller outlives the close, and takes the window down with it.
        window.isReleasedWhenClosed = false
        window.delegate = self

        let hostingController = NSHostingController(
            rootView: FilePlayerView(
                url: url,
                appModel: appModel
            )
        )
        // A hosting controller otherwise pins the window to the size its view
        // asks for, which for a player is the smallest one it will accept —
        // there is no natural size for a video, only the size it is watched at.
        // The window keeps its own frame, and `contentMinSize` above the floor.
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
    }

    /// Sizes and places the window: where the last window of this kind was left,
    /// or stepped down from `cascadePoint` if one is already open. Returns the
    /// corner the window after this should step down from.
    ///
    /// It runs after the view is installed, not during init, because a hosting
    /// controller sizes its window to the view it is given and would undo any
    /// frame set before it.
    func place(after cascadePoint: NSPoint?) -> NSPoint {
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setContentSize(NSSize(width: 960, height: 540))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        // Cascading from the zero point leaves the window where it is and only
        // reports where the next one goes, which is what the first window wants.
        return window.cascadeTopLeft(from: cascadePoint ?? .zero)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    func windowWillClose(_ notification: Notification) {
        ActivePlayer.shared.resign(appModel)
        appModel.shutdown()
        window.delegate = nil
        // Releases the hosting controller, and with it the video view the player
        // has just been detached from.
        window.contentViewController = nil
        onClose()
    }
}
