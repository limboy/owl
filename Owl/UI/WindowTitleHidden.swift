import AppKit
import SwiftUI

/// Hides the host window's title text while keeping the title bar controls.
///
/// `WindowGroup`'s title also names the window in the Window menu and
/// Mission Control, so it can't simply be left blank; this hides only its
/// on-screen rendering.
struct WindowTitleHidden: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        hide(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        hide(on: nsView)
    }

    private func hide(on view: NSView) {
        guard let window = view.window else {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                hide(on: view)
            }
            return
        }

        window.titleVisibility = .hidden
    }
}

/// Fades the host window's title bar — traffic lights, title and all — in and
/// out, for a window whose picture runs up under it.
///
/// Once faded out it is also taken out of the window, so a click in the strip
/// it covered goes to the picture rather than to a close button nobody can
/// see. In fullscreen the title bar is the system's to show and hide, and is
/// left alone.
struct TitleBarAutoHide: NSViewRepresentable {
    let isShown: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view, isShown: isShown)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView, isShown: isShown)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setShown(true, animated: false)
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var isShown = true
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        /// Counts fades, so a fade-out finishing after a fade-in has begun
        /// does not take the title bar away from under it.
        private var generation = 0

        func attach(to view: NSView, isShown: Bool) {
            guard let window = view.window else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, view.window != nil else { return }
                    attach(to: view, isShown: isShown)
                }
                return
            }
            if self.window !== window {
                self.window = window
                observe(window)
            }
            setShown(isShown, animated: true)
        }

        func setShown(_ shown: Bool, animated: Bool) {
            isShown = shown
            apply(animated: animated)
        }

        private func apply(animated: Bool) {
            guard let window, let titleBar = Self.titleBar(of: window) else { return }
            let shown = isShown || window.styleMask.contains(.fullScreen)
            generation += 1
            let current = generation

            if shown {
                titleBar.isHidden = false
                guard titleBar.alphaValue < 1 else { return }
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18
                        titleBar.animator().alphaValue = 1
                    }
                } else {
                    titleBar.alphaValue = 1
                }
            } else {
                guard !titleBar.isHidden else { return }
                guard animated else {
                    titleBar.alphaValue = 0
                    titleBar.isHidden = true
                    return
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    titleBar.animator().alphaValue = 0
                } completionHandler: { [weak self, weak titleBar] in
                    MainActor.assumeIsolated {
                        guard let self, current == self.generation, !self.isShown else { return }
                        titleBar?.isHidden = true
                    }
                }
            }
        }

        /// Fullscreen brings the title bar back for the system to manage, and
        /// leaving it puts it back the way the controls have it.
        private func observe(_ window: NSWindow) {
            observers.forEach(NotificationCenter.default.removeObserver)
            let center = NotificationCenter.default
            observers = [
                NSWindow.willEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.apply(animated: false)
                    }
                }
            }
        }

        /// The view holding the traffic lights and the title: the close
        /// button's grandparent, which AppKit offers no more direct way to.
        private static func titleBar(of window: NSWindow) -> NSView? {
            window.standardWindowButton(.closeButton)?.superview?.superview
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
