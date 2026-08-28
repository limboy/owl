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

    /// The floor a window is held to before the video's shape is taken into
    /// account: small enough to tuck a picture into a corner of the screen,
    /// large enough for the controls laid over it.
    private static let windowedStyleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable
    ]

    private static let minimumContentWidth: CGFloat = 480
    private static let minimumContentHeight: CGFloat = 270

    private let appModel: AppModel
    private let window: NSWindow
    private let onClose: () -> Void
    private var cancellables = Set<AnyCancellable>()

    /// The shape the window keeps outside fullscreen, once mpv has reported the
    /// picture's, and nil until then.
    private var videoAspectRatio: CGFloat?

    /// The window's own animation in and out of fullscreen — see the type for
    /// why the transition is not left to AppKit.
    private let fullScreenAnimator = FullScreenFrameAnimator()

    init(url: URL, onClose: @escaping () -> Void) {
        appModel = AppModel(folderLibrary: nil)
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: Self.windowedStyleMask,
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = url.lastPathComponent
        // Gives the title bar the file's icon, and its path under a click.
        window.representedURL = url
        window.contentMinSize = NSSize(
            width: Self.minimumContentWidth,
            height: Self.minimumContentHeight
        )
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

        observeVideoAspectRatio()
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
        cancellables.removeAll()
        ActivePlayer.shared.resign(appModel)
        appModel.shutdown()
        window.delegate = nil
        // Releases the hosting controller, and with it the video view the player
        // has just been detached from.
        window.contentViewController = nil
        onClose()
    }

    // MARK: - The video's shape

    /// Shapes the window like the picture in it, and keeps it that way.
    ///
    /// A window that matches the video has no black margin of its own: mpv's
    /// letterboxing then only appears where the shape of the thing showing the
    /// picture is not the picture's own, which is fullscreen and nowhere else.
    private func observeVideoAspectRatio() {
        appModel.playerState.$videoAspectRatio
            .removeDuplicates()
            .sink { [weak self] ratio in
                self?.applyVideoAspectRatio(ratio.map { CGFloat($0) })
            }
            .store(in: &cancellables)
    }

    private func applyVideoAspectRatio(_ ratio: CGFloat?) {
        videoAspectRatio = ratio
        guard let ratio, ratio.isFinite, ratio > 0 else {
            clearContentAspectRatio()
            window.contentMinSize = NSSize(
                width: Self.minimumContentWidth,
                height: Self.minimumContentHeight
            )
            return
        }

        window.contentMinSize = Self.minimumContentSize(for: ratio)
        // Fullscreen is the screen's shape, not the video's. The constraint,
        // and the frame that goes with it, are put back on the way out.
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.contentAspectRatio = NSSize(width: ratio, height: 1)
        window.setFrame(reshapedFrame(for: ratio), display: true)
    }

    /// Lets the window take any shape again.
    ///
    /// A ratio is dropped by asking for free resize increments rather than by
    /// assigning a zero ratio: a zero is what AppKit stores for "unconstrained",
    /// but assigning one leaves it dividing by it, and the next frame the window
    /// is given comes out as nothing a window can be.
    private func clearContentAspectRatio() {
        window.resizeIncrements = NSSize(width: 1, height: 1)
    }

    /// The smallest window of this shape, held above both floors so that a
    /// picture wider than it is tall is not also shorter than the controls.
    private static func minimumContentSize(for ratio: CGFloat) -> NSSize {
        NSSize(
            width: max(minimumContentWidth, minimumContentHeight * ratio),
            height: max(minimumContentHeight, minimumContentWidth / ratio)
        )
    }

    /// The window's frame with its content reshaped to `ratio`, holding the
    /// area it covers and the point it is centred on, and staying on screen.
    ///
    /// Holding the area rather than the width is what keeps a window opened on
    /// a tall video from becoming a tall window as wide as the last one was.
    private func reshapedFrame(for ratio: CGFloat) -> NSRect {
        let frame = window.frame
        // Measured against the windowed style rather than asked of the window:
        // on the way out of fullscreen the window still answers as a fullscreen
        // one, whose content is its whole frame, and the title bar would be
        // counted into the picture and the window grown by its height.
        let content = Self.contentSize(ofFrame: frame)
        guard content.width > 0, content.height > 0 else { return frame }
        guard abs(content.width / content.height - ratio) > 0.001 else { return frame }

        var width = (content.width * content.height * ratio).squareRoot()
        var height = width / ratio

        let minimum = window.contentMinSize
        if width < minimum.width || height < minimum.height {
            let scale = max(minimum.width / width, minimum.height / height)
            width *= scale
            height *= scale
        }

        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let limit = Self.contentSize(ofFrame: visible)
            if width > limit.width || height > limit.height {
                let scale = min(limit.width / width, limit.height / height)
                width *= scale
                height *= scale
            }
        }

        var reshaped = NSWindow.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: width.rounded(),
                height: height.rounded()
            ),
            styleMask: Self.windowedStyleMask
        )
        reshaped.origin = NSPoint(
            x: (frame.midX - reshaped.width / 2).rounded(),
            y: (frame.midY - reshaped.height / 2).rounded()
        )
        return keptOnScreen(reshaped)
    }

    private static func contentSize(ofFrame frame: NSRect) -> NSSize {
        NSWindow.contentRect(forFrameRect: frame, styleMask: windowedStyleMask).size
    }

    private func keptOnScreen(_ frame: NSRect) -> NSRect {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return frame
        }
        var frame = frame
        frame.origin.x = min(
            max(frame.minX, visible.minX),
            max(visible.maxX - frame.width, visible.minX)
        )
        frame.origin.y = min(
            max(frame.minY, visible.minY),
            max(visible.maxY - frame.height, visible.minY)
        )
        return frame
    }

    // MARK: - Fullscreen

    func windowWillEnterFullScreen(_ notification: Notification) {
        // A window is asked to be the size of the screen on the way in, which
        // is a size the video's shape would otherwise refuse.
        clearContentAspectRatio()
        // For the length of the fullscreen session the window's content is its
        // whole frame, with the title bar floating over the top of the picture
        // rather than sitting above it. It buys the picture the title bar's
        // height of screen in fullscreen, and — because AppKit measures a
        // window on its way in and out of fullscreen by its content — it is
        // what keeps the two animations from each landing a title bar's height
        // away from where the window really goes.
        window.styleMask.insert(.fullSizeContentView)
        // Noted after the style change, so it is the frame AppKit will hand
        // back on the way out and the exit animation can land exactly on it.
        fullScreenAnimator.rememberWindowedFrame(of: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // Puts the title bar back above the picture, which grows the frame by
        // its height and leaves the content — the video — where it was.
        window.styleMask.remove(.fullSizeContentView)
        applyVideoAspectRatio(videoAspectRatio)
    }

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    func window(
        _ window: NSWindow,
        startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval
    ) {
        fullScreenAnimator.animateIntoFullScreen(window, over: duration)
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    func window(
        _ window: NSWindow,
        startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval
    ) {
        fullScreenAnimator.animateOutOfFullScreen(window, over: duration)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenAnimator.settleWindowed(window)
        window.styleMask.remove(.fullSizeContentView)
        applyVideoAspectRatio(videoAspectRatio)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenAnimator.settleFullScreen(window)
    }
}
