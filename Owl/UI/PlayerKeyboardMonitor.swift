import AppKit
import SwiftUI

/// A key the player answers to when nothing else is using it.
enum PlayerKey: Equatable {
    case togglePlayPause
    case seekBackward
    case seekForward
    case volumeUp
    case volumeDown
    case increaseSubtitleDelay
    case decreaseSubtitleDelay
    case cycleSubtitle

    /// Whether holding the key down should keep repeating the action. Seeking
    /// and volume are worth repeating; toggling anything on the same repeats
    /// only flickers. Nor is the subtitle delay: a quarter of a second per
    /// repeat at the rate a held key sends them would run the subtitles
    /// minutes out inside a second.
    var repeats: Bool {
        switch self {
        case .seekBackward, .seekForward, .volumeUp, .volumeDown:
            true
        case .togglePlayPause, .increaseSubtitleDelay, .decreaseSubtitleDelay, .cycleSubtitle:
            false
        }
    }
}

/// Which of the player's bare keys a key event is, and whether the player is
/// the one that should get it.
enum PlayerKeyRouting {
    static func key(for event: NSEvent) -> PlayerKey? {
        // Caps lock, and the flags every arrow key carries, are not somebody
        // holding a modifier down. Only these three are — shift is asked about
        // separately, because ⇧Z is a key of its own rather than a modified Z.
        let actionModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(actionModifiers).isEmpty else {
            return nil
        }
        guard let characters = event.charactersIgnoringModifiers,
              characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first
        else {
            return nil
        }
        let isShifted = event.modifierFlags.contains(.shift)

        switch Int(scalar.value) {
        case 0x20 where !isShifted:
            return .togglePlayPause
        case NSLeftArrowFunctionKey where !isShifted:
            return .seekBackward
        case NSRightArrowFunctionKey where !isShifted:
            return .seekForward
        case NSUpArrowFunctionKey where !isShifted:
            return .volumeUp
        case NSDownArrowFunctionKey where !isShifted:
            return .volumeDown
        default:
            break
        }

        // The letters mpv itself uses for subtitles, so anybody arriving from
        // mpv already knows them. Matched lowercased and against the shift key
        // rather than against "z" and "Z", or caps lock — which is not somebody
        // holding a modifier down — would swap the two.
        switch Character(scalar).lowercased() {
        case "z":
            return isShifted ? .increaseSubtitleDelay : .decreaseSubtitleDelay
        case "j" where !isShifted:
            return .cycleSubtitle
        default:
            return nil
        }
    }

    /// Whether `key` reaches the player, given whatever holds keyboard focus.
    ///
    /// The responder chain is walked rather than only the first responder
    /// itself, because a list hands focus to a view inside one of its rows and
    /// the table that would move its selection sits further up.
    ///
    /// Main actor because walking that chain reads `nextResponder`, and the
    /// only caller is a key event monitor, which AppKit runs on the main thread
    /// anyway.
    @MainActor
    static func belongsToPlayer(_ key: PlayerKey, firstResponder: NSResponder?) -> Bool {
        var responder = firstResponder
        while let current = responder {
            // Anything being typed into owns every unmodified key, the space
            // bar included. The field editor of an open panel's filename field
            // is the case that actually turns up here.
            if current is NSText || current is NSTextField {
                return false
            }
            // A list moves its selection with the vertical arrows. Seeking,
            // the space bar and the subtitle keys mean nothing to it, so those
            // stay with the player even while the folder browser is being read
            // through — and the player is what covers the browser whenever
            // these keys are being watched for at all.
            if current is NSTableView || current is NSOutlineView || current is NSCollectionView {
                return key != .volumeUp && key != .volumeDown
            }
            responder = current.nextResponder
        }
        return true
    }
}

/// Watches for the player's bare keys and reports the ones the focused view has
/// no use of its own for.
///
/// None of these keys can be a menu key equivalent. A menu matches its
/// equivalents before the event reaches the window, so an unmodified arrow
/// bound in the menu is taken from every view in the app, the folder list
/// included, and that list needs the arrows to move its own selection. Watching
/// the events here instead leaves the decision to whatever holds focus when the
/// key is pressed.
///
/// It has to be an event monitor rather than `onKeyPress`, because the video
/// surface is an `NSView` that never takes focus: there is no SwiftUI view in
/// the player to hang key handling off.
struct PlayerKeyboardMonitor: NSViewRepresentable {
    let handle: @MainActor (PlayerKey) -> Void

    func makeNSView(context: Context) -> PlayerKeyboardMonitorView {
        let view = PlayerKeyboardMonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ nsView: PlayerKeyboardMonitorView, context: Context) {
        nsView.handle = handle
    }

    static func dismantleNSView(
        _ nsView: PlayerKeyboardMonitorView,
        coordinator: Void
    ) {
        nsView.stopMonitoring()
    }
}

@MainActor
final class PlayerKeyboardMonitorView: NSView {
    var handle: (@MainActor (PlayerKey) -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, event.window === window else { return event }
            return consume(event) ? nil : event
        }
    }

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func consume(_ event: NSEvent) -> Bool {
        guard let key = PlayerKeyRouting.key(for: event),
              PlayerKeyRouting.belongsToPlayer(key, firstResponder: window?.firstResponder)
        else {
            return false
        }
        if !event.isARepeat || key.repeats {
            handle?(key)
        }
        return true
    }
}
