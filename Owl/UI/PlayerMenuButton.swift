import AppKit
import SwiftUI

/// One line of a `PlayerMenuButton`'s menu.
enum PlayerMenuItem {
    /// One of a set, checked when it is the one in effect.
    case choice(String, selected: Bool, action: () -> Void)
    case action(String, action: () -> Void)
    /// Text that cannot be chosen, such as there being nothing to choose.
    case note(String)
    case divider
}

/// A button over the picture whose menu opens upwards, above the button.
///
/// SwiftUI's `Menu` is an AppKit pull-down, which always drops below its
/// button and only flips when the screen runs out. The player's controls sit
/// at the bottom of the picture, so dropping down takes every menu out of the
/// player. This opens the same native menu, placed above the button instead;
/// AppKit still moves it back on screen if there is no room above.
struct PlayerMenuButton<Label: View>: View {
    let help: String
    /// Read when the button is clicked, so the checkmarks are always current.
    let items: () -> [PlayerMenuItem]
    @ViewBuilder let label: () -> Label

    @State private var anchor = PlayerMenuAnchor()

    var body: some View {
        Button {
            anchor.open(items())
        } label: {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(PlayerMenuAnchorView(anchor: anchor))
        .help(help)
    }
}

/// Holds the AppKit view the menu is opened from.
@MainActor
private final class PlayerMenuAnchor {
    weak var view: NSView?

    /// The space between the top of the button and the bottom of the menu.
    private static let gap: CGFloat = 6

    func open(_ items: [PlayerMenuItem]) {
        guard let view else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(Self.menuItem(for: item))
        }

        // `popUp` places the menu's top-left corner at the point given, so
        // to sit above the button it goes a whole menu's height above it,
        // centred across the button.
        let size = menu.size
        let x = view.bounds.midX - size.width / 2
        let y = view.isFlipped
            ? view.bounds.minY - Self.gap - size.height
            : view.bounds.maxY + Self.gap + size.height
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: view)
    }

    private static func menuItem(for item: PlayerMenuItem) -> NSMenuItem {
        switch item {
        case .choice(let title, let selected, let action):
            let menuItem = actionItem(title, action: action)
            menuItem.state = selected ? .on : .off
            return menuItem
        case .action(let title, let action):
            return actionItem(title, action: action)
        case .note(let title):
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            return menuItem
        case .divider:
            return .separator()
        }
    }

    private static func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let handler = PlayerMenuAction(action)
        let menuItem = NSMenuItem(
            title: title,
            action: #selector(PlayerMenuAction.run),
            keyEquivalent: ""
        )
        menuItem.target = handler
        // The target is held weakly; this keeps the handler alive as long as
        // the item.
        menuItem.representedObject = handler
        return menuItem
    }
}

private final class PlayerMenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}

private struct PlayerMenuAnchorView: NSViewRepresentable {
    let anchor: PlayerMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
