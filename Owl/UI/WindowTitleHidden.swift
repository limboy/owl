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
