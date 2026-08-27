import AppKit
import Combine
import SwiftUI

/// One window's player, as the menu bar sees it.
struct PlayerTarget {
    let appModel: AppModel
}

/// Which window the Playback menu acts on.
///
/// There is one menu bar and there may be several players — the folder window
/// and a window per file opened on its own — so the menu cannot be bound to any
/// one of them. Each player window claims this as it comes to the front and
/// gives it up as it closes, and the menu reads whatever is claimed when the
/// item is chosen.
@MainActor
final class ActivePlayer: ObservableObject {
    static let shared = ActivePlayer()

    @Published private(set) var target: PlayerTarget?

    private init() {}

    func claim(_ target: PlayerTarget) {
        guard self.target?.appModel !== target.appModel else { return }
        // `claim` can be reached synchronously from an NSViewRepresentable's
        // `updateNSView`, i.e. from within a SwiftUI view update. Publishing
        // `target` right there trips "Publishing changes from within view
        // updates is not allowed", so the actual mutation is pushed to the
        // next run loop turn instead.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.target?.appModel !== target.appModel else { return }
            self.target = target
        }
    }

    /// Releases the menu if `appModel` holds it. A window closing while another
    /// one has already claimed the menu leaves that claim alone.
    func resign(_ appModel: AppModel) {
        guard target?.appModel === appModel else { return }
        target = nil
    }
}

/// Hands `ActivePlayer` the window this view sits in, whenever that window comes
/// to the front.
struct ActivePlayerTracker: NSViewRepresentable {
    let target: PlayerTarget

    func makeNSView(context: Context) -> ActivePlayerTrackerView {
        let view = ActivePlayerTrackerView()
        view.target = target
        return view
    }

    func updateNSView(_ nsView: ActivePlayerTrackerView, context: Context) {
        nsView.target = target
    }

    static func dismantleNSView(_ nsView: ActivePlayerTrackerView, coordinator: Void) {
        nsView.stopObserving()
    }
}

@MainActor
final class ActivePlayerTrackerView: NSView {
    var target: PlayerTarget? {
        didSet { claimIfKey() }
    }

    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.claim() }
        }

        // A window that is already key when the view lands in it, which is the
        // usual case for a window opened by the app itself, sends no
        // notification of its own.
        claimIfKey()
    }

    func stopObserving() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }

    private func claimIfKey() {
        guard window?.isKeyWindow == true else { return }
        claim()
    }

    private func claim() {
        guard let target else { return }
        ActivePlayer.shared.claim(target)
    }
}
