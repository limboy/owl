import AppKit
import SwiftUI

/// The frame animation in and out of fullscreen, for a window to hand its
/// transition to.
///
/// AppKit's own transition is a snapshot of the window stretched to the shape
/// of the screen and crossfaded into the resized window, which for a window
/// showing a video means the picture is the wrong shape for as long as the
/// animation lasts and only springs back to the right one at the end of it —
/// the resize that appears to happen after the window has already arrived.
/// Animating the window's frame instead resizes the video view every step of
/// the way, so mpv draws the picture at the shape it really is throughout, and
/// the black bars fullscreen puts around it grow rather than appear.
///
/// A delegate hands its transition over by returning its window from
/// `customWindowsToEnterFullScreen` and `customWindowsToExitFullScreen` and
/// calling `animateIntoFullScreen` and `animateOutOfFullScreen` from the
/// animation methods that follow them. Taking the animation on also means
/// answering for the window ending up where it was going when the transition is
/// abandoned partway, which is what `settleWindowed` and `settleFullScreen` are
/// for in `windowDidFailToEnterFullScreen` and `windowDidFailToExitFullScreen`.
@MainActor
final class FullScreenFrameAnimator {
    /// Where the window was before fullscreen took it, for the animation out of
    /// fullscreen to bring it back to.
    private var frameBeforeFullScreen: NSRect?
    private var screenBeforeFullScreen: NSScreen?

    /// Notes where the window stands, from `windowWillEnterFullScreen` and
    /// after whatever the window changes about itself for the fullscreen
    /// session: this is the frame AppKit hands back on the way out, and the
    /// frame the exit animation has to land exactly on.
    func rememberWindowedFrame(of window: NSWindow) {
        screenBeforeFullScreen = window.screen
        frameBeforeFullScreen = window.frame
    }

    func animateIntoFullScreen(_ window: NSWindow, over duration: TimeInterval) {
        guard let screen = screen(for: window) else { return }
        animate(window, to: Self.fullScreenFrame(on: screen), over: duration)
    }

    func animateOutOfFullScreen(_ window: NSWindow, over duration: TimeInterval) {
        guard let frame = frameBeforeFullScreen else { return }
        animate(window, to: frame, over: duration)
    }

    func settleWindowed(_ window: NSWindow) {
        guard let frame = frameBeforeFullScreen else { return }
        window.setFrame(frame, display: true)
    }

    func settleFullScreen(_ window: NSWindow) {
        guard let screen = screen(for: window) else { return }
        window.setFrame(Self.fullScreenFrame(on: screen), display: true)
    }

    /// The display the window left for fullscreen, which is the one it is on
    /// for as long as the session lasts.
    private func screen(for window: NSWindow) -> NSScreen? {
        screenBeforeFullScreen ?? window.screen ?? NSScreen.main
    }

    /// Where a fullscreen window on `screen` ends up.
    ///
    /// Not the whole screen: AppKit keeps a strip along the top for the title
    /// bar it hides there, and on a display with a notch the room the notch
    /// takes on top of that. Animating to the whole screen instead would leave
    /// the window to be dropped down by that much the moment the animation
    /// ended, which is the jolt the animation is here to avoid.
    private static func fullScreenFrame(on screen: NSScreen) -> NSRect {
        var frame = screen.frame
        frame.size.height -= screen.safeAreaInsets.top
        return frame
    }

    private func animate(_ window: NSWindow, to frame: NSRect, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}

/// Gives the host window the fullscreen transition `FullScreenFrameAnimator`
/// describes, the one a window opened on a single file animates for itself.
///
/// The window here is SwiftUI's, and its delegate is SwiftUI's too, so this
/// stands a delegate of its own in front of that one rather than replacing it:
/// the fullscreen methods are answered here and everything else — closing,
/// becoming key, the rest of the window's life — is passed straight through.
struct FullScreenTransition: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        FullScreenTransitionDelegate.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        FullScreenTransitionDelegate.install(on: nsView)
    }
}

/// The window's delegate, forwarding to the delegate it displaced.
///
/// Only the methods below are answered here. Anything else a delegate is asked
/// for is reported as understood and handed on by the runtime, so SwiftUI's
/// delegate goes on hearing everything it did before — including the two
/// fullscreen notifications it does implement, which are forwarded by hand
/// because a method answered here is one the runtime no longer forwards.
///
/// The delegate is owned by a registry keyed on the window, since a window
/// holds its delegate weakly and this one has nothing else to keep it alive.
@MainActor
private final class FullScreenTransitionDelegate: NSObject, NSWindowDelegate {
    private static var delegates: [ObjectIdentifier: FullScreenTransitionDelegate] = [:]

    static func install(on view: NSView) {
        guard let window = view.window else {
            // The view has no window during the first layout pass.
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                install(on: view)
            }
            return
        }

        let identifier = ObjectIdentifier(window)
        guard delegates[identifier] == nil else { return }
        let delegate = FullScreenTransitionDelegate(displacing: window.delegate)
        delegates[identifier] = delegate
        window.delegate = delegate
    }

    private let base: NSWindowDelegate?
    private let animator = FullScreenFrameAnimator()

    private init(displacing base: NSWindowDelegate?) {
        self.base = base
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || base?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        base
    }

    // MARK: - Fullscreen

    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            animator.rememberWindowedFrame(of: window)
        }
        base?.windowWillEnterFullScreen?(notification)
    }

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    func window(
        _ window: NSWindow,
        startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval
    ) {
        animator.animateIntoFullScreen(window, over: duration)
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    func window(
        _ window: NSWindow,
        startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval
    ) {
        animator.animateOutOfFullScreen(window, over: duration)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        animator.settleWindowed(window)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        animator.settleFullScreen(window)
    }

    // MARK: - The window's life

    func windowWillClose(_ notification: Notification) {
        base?.windowWillClose?(notification)
        guard let window = notification.object as? NSWindow else { return }
        Self.delegates[ObjectIdentifier(window)] = nil
    }
}
