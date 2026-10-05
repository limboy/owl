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
        RecentFiles.shared.record(url)
        PlaybackProgressStore.shared.setQueueDirectory(nil, for: url)
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

    /// The picture runs the full height of the window, with the title bar
    /// laid over its top, so the title bar can fade with the controls rather
    /// than leave a strip of window behind it.
    private static let windowedStyleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView
    ]

    /// The floor a window is held to before the video's shape is taken into
    /// account: small enough to tuck a picture into a corner of the screen,
    /// large enough for the controls laid over it.
    private static let minimumContentWidth: CGFloat = 480
    private static let minimumContentHeight: CGFloat = 270

    private let appModel: AppModel
    private let window: NSWindow
    private let onClose: () -> Void
    private var cancellables = Set<AnyCancellable>()

    /// The smallest the window's content may be, kept here rather than only
    /// read back from `contentMinSize`: something in AppKit or the hosting
    /// controller resets that to zero after it is set, and a window held to
    /// the video's ratio can then be dragged down to its traffic lights.
    private var minimumContentSize = NSSize(
        width: minimumContentWidth,
        height: minimumContentHeight
    ) {
        didSet { window.contentMinSize = minimumContentSize }
    }

    /// The shape the window keeps outside fullscreen, once mpv has reported the
    /// picture's, and nil until then.
    private var videoAspectRatio: CGFloat?
    /// How many pixels the picture covers once drawn, and nil until mpv has
    /// reported both sides of it.
    private var videoPixelArea: CGFloat?
    /// Whether the window has been given its opening size, which it takes once
    /// both the picture's shape and its size are known.
    private var hasSizedForVideo = false

    /// Whether the window can be seen yet. Until it has its opening size it is
    /// on screen but transparent — as IINA holds its window back — so it first
    /// appears already at that size, rather than at the saved frame and then
    /// jumping to it. It has to be on screen all the same: the renderer is only
    /// made on the video view's first draw, and nothing plays before it is.
    private var isRevealed = false
    /// Shows the window anyway should the video's size never come: for a file
    /// with no picture, one mpv cannot open, or a load that hangs.
    private var revealFallback: DispatchWorkItem?

    /// How long a loaded file is given to report a picture before the window
    /// is shown without one, and how long a load is given at all.
    private static let revealGraceAfterLoad: TimeInterval = 1
    private static let revealDeadline: TimeInterval = 5

    /// The window's own animation in and out of fullscreen — see the type for
    /// why the transition is not left to AppKit.
    private let fullScreenAnimator = FullScreenFrameAnimator()

    /// The window's frame, title bar and all, as fullscreen found it — the
    /// frame it goes back to on the way out.
    private var frameBeforeFullScreen: NSRect?

    /// Counts fullscreen sessions, so a restore left waiting on the exit
    /// animation is dropped if the window heads back into fullscreen first.
    private var fullScreenSession = 0

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
        window.alphaValue = 0
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

        appModel.holdPlayback()
        observeVideoAspectRatio()
        observeRevealFallbacks()
    }

    /// Sizes and places the window: where the last window of this kind was left,
    /// or stepped down from `cascadePoint` if one is already open. Returns the
    /// corner the window after this should step down from.
    ///
    /// It runs after the view is installed, not during init, because a hosting
    /// controller sizes its window to the view it is given and would undo any
    /// frame set before it.
    func place(after cascadePoint: NSPoint?) -> NSPoint {
        if window.setFrameUsingName(Self.frameAutosaveName) {
            // A frame saved below the floor — by a version that did not hold
            // the window to it — would open with the controls cut off.
            window.setFrame(heldAboveMinimum(window.frame), display: false)
        } else {
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

    /// Makes the window visible and lets its file play. Once only.
    private func reveal() {
        guard !isRevealed else { return }
        isRevealed = true
        revealFallback?.cancel()
        revealFallback = nil
        window.alphaValue = 1
        appModel.releasePlayback()
    }

    private func scheduleReveal(after delay: TimeInterval) {
        revealFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reveal() }
        revealFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func observeRevealFallbacks() {
        scheduleReveal(after: Self.revealDeadline)

        let state = appModel.playerState
        // The picture's size arrives a moment after the file opens, once the
        // first frame is decoded; a file with none never reports one.
        state.$isLoading
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                guard let self, !isRevealed else { return }
                scheduleReveal(after: Self.revealGraceAfterLoad)
            }
            .store(in: &cancellables)
        state.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] _ in self?.reveal() }
            .store(in: &cancellables)
        // No libmpv: the window shows how to install it rather than a video.
        appModel.$startupError
            .compactMap { $0 }
            .sink { [weak self] _ in self?.reveal() }
            .store(in: &cancellables)
    }

    /// Holds a resize to `minimumContentSize`.
    ///
    /// AppKit leaves the minimum to the window while it keeps the video's
    /// shape, and gives way on it: dragged by a corner, a window held to a
    /// ratio goes below its minimum, and the controls over the picture are
    /// cut off at both sides.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !sender.styleMask.contains(.fullScreen) else { return frameSize }
        return heldAboveMinimum(NSRect(origin: sender.frame.origin, size: frameSize)).size
    }

    /// `frame` grown until its content is no smaller than `minimumContentSize`,
    /// anchored at its top-left corner, where the title bar the window is
    /// dragged by sits. Held to the video's shape, the minimum already has
    /// that shape and is taken whole; the size being dragged to need not.
    private func heldAboveMinimum(_ frame: NSRect) -> NSRect {
        let content = Self.contentSize(ofFrame: frame)
        let minimum = minimumContentSize
        guard content.width < minimum.width || content.height < minimum.height else {
            return frame
        }

        let held = videoAspectRatio == nil
            ? NSSize(width: max(content.width, minimum.width), height: max(content.height, minimum.height))
            : minimum
        var grown = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(
                width: held.width.rounded(.up),
                height: held.height.rounded(.up)
            )),
            styleMask: Self.windowedStyleMask
        )
        grown.origin = NSPoint(x: frame.minX, y: frame.maxY - grown.height)
        return keptOnScreen(grown)
    }

    func windowWillClose(_ notification: Notification) {
        revealFallback?.cancel()
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
        let state = appModel.playerState
        Publishers.CombineLatest3(
            state.$videoAspectRatio,
            state.$videoDisplayWidth,
            state.$videoDisplayHeight
        )
        .removeDuplicates(by: ==)
        .sink { [weak self] ratio, width, height in
            guard let self else { return }
            if let width, let height {
                videoPixelArea = CGFloat(width * height)
            } else {
                videoPixelArea = nil
            }
            applyVideoAspectRatio(ratio.map { CGFloat($0) })
        }
        .store(in: &cancellables)
    }

    private func applyVideoAspectRatio(_ ratio: CGFloat?) {
        videoAspectRatio = ratio
        guard let ratio, ratio.isFinite, ratio > 0 else {
            clearContentAspectRatio()
            minimumContentSize = NSSize(
                width: Self.minimumContentWidth,
                height: Self.minimumContentHeight
            )
            return
        }

        minimumContentSize = Self.minimumContentSize(for: ratio)
        // Fullscreen is the screen's shape, not the video's. The constraint,
        // and the frame that goes with it, are put back on the way out.
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.contentAspectRatio = NSSize(width: ratio, height: 1)
        if !hasSizedForVideo, let videoPixelArea {
            window.setFrame(reshapedFrame(for: ratio, openingOn: videoPixelArea), display: true)
            hasSizedForVideo = true
            reveal()
        } else {
            window.setFrame(reshapedFrame(for: ratio), display: true)
        }
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
    /// Given `pixelArea`, the window is opening on the video: it is centred on
    /// the screen, and covers that area instead: the picture at its own size, a pixel to a pixel of the display
    /// — so half that in points on a Retina one — as IINA opens a file. The
    /// area rather than the two sides is what is taken from mpv, so the shape
    /// comes from `ratio` alone and a rotated picture cannot disagree with it.
    ///
    /// Holding the area rather than the width is what keeps a window opened on
    /// a tall video from becoming a tall window as wide as the last one was.
    private func reshapedFrame(for ratio: CGFloat, openingOn pixelArea: CGFloat? = nil) -> NSRect {
        let frame = window.frame
        // Measured against the windowed style rather than asked of the window:
        // on the way out of fullscreen the window still answers as a fullscreen
        // one, whose content is its whole frame, and the title bar would be
        // counted into the picture and the window grown by its height.
        let content = Self.contentSize(ofFrame: frame)
        guard content.width > 0, content.height > 0 else { return frame }
        guard pixelArea != nil || abs(content.width / content.height - ratio) > 0.001 else { return frame }

        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame

        var width: CGFloat
        if let pixelArea {
            let scale = screen?.backingScaleFactor ?? window.backingScaleFactor
            width = (pixelArea * ratio).squareRoot() / scale
        } else {
            width = (content.width * content.height * ratio).squareRoot()
        }
        var height = width / ratio

        let minimum = minimumContentSize
        if width < minimum.width || height < minimum.height {
            let scale = max(minimum.width / width, minimum.height / height)
            width *= scale
            height *= scale
        }

        if let visible {
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
        // A window opening on the video is centred on the screen, as IINA
        // places one, rather than on wherever the saved frame left it.
        var centre = NSPoint(x: frame.midX, y: frame.midY)
        if pixelArea != nil, let visible {
            centre = NSPoint(x: visible.midX, y: visible.midY)
        }
        reshaped.origin = NSPoint(
            x: (centre.x - reshaped.width / 2).rounded(),
            y: (centre.y - reshaped.height / 2).rounded()
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
        fullScreenSession += 1
        // Still set if the last exit's restore never got to run, in which case
        // the frame now is not a windowed one.
        if frameBeforeFullScreen == nil {
            frameBeforeFullScreen = window.frame
        }
        fullScreenAnimator.rememberWindowedFrame(of: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // The exit animation can still be running here; a frame set before it
        // lands would be undone by its last step.
        let session = fullScreenSession
        fullScreenAnimator.whenSettled { [weak self] in
            guard let self, session == fullScreenSession else { return }
            restoreWindowedFrame()
            applyVideoAspectRatio(videoAspectRatio)
        }
    }

    /// Puts the window back on the frame it had before fullscreen, which the
    /// custom exit animation does not leave it on reliably by itself.
    private func restoreWindowedFrame() {
        if let frame = frameBeforeFullScreen {
            window.setFrame(frame, display: true)
        }
        frameBeforeFullScreen = nil
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
        restoreWindowedFrame()
        applyVideoAspectRatio(videoAspectRatio)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenAnimator.settleFullScreen(window)
    }
}
