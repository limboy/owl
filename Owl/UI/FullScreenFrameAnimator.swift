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

    /// Runs `body` once the window has stopped moving: now, or when the
    /// animation in flight lands.
    ///
    /// AppKit ends the transition once the duration it handed out has passed,
    /// not when the animation does, and on a main thread busy enough for the
    /// animation to fall behind it reports the window out of fullscreen while
    /// the frame is still on its way. A frame set then is overwritten by the
    /// animation's own last step.
    func whenSettled(_ body: @escaping @MainActor () -> Void) {
        if animationsInFlight == 0 {
            body()
        } else {
            pendingUntilSettled.append(body)
        }
    }

    private var animationsInFlight = 0
    private var pendingUntilSettled: [@MainActor () -> Void] = []

    private func animate(_ window: NSWindow, to frame: NSRect, over duration: TimeInterval) {
        let videoViews = videoViews(in: window.contentView)
        videoViews.forEach { $0.beginAnimatedResize() }
        animationsInFlight += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                videoViews.forEach { $0.endAnimatedResize() }
                guard let self else { return }
                self.animationsInFlight -= 1
                guard self.animationsInFlight == 0 else { return }
                let pending = self.pendingUntilSettled
                self.pendingUntilSettled.removeAll()
                pending.forEach { $0() }
            }
        }
    }

    private func videoViews(in view: NSView?) -> [OwlVideoView] {
        guard let view else { return [] }
        if let videoView = view as? OwlVideoView { return [videoView] }
        return view.subviews.flatMap { videoViews(in: $0) }
    }
}
