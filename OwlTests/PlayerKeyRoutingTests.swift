import AppKit
import SwiftUI
import XCTest
@testable import Owl

@MainActor
final class PlayerKeyRoutingTests: XCTestCase {
    func testBareKeysAreRecognisedAndModifiedOnesAreLeftAlone() {
        XCTAssertEqual(PlayerKeyRouting.key(for: keyEvent(" ")), .togglePlayPause)
        XCTAssertEqual(PlayerKeyRouting.key(for: arrowEvent(NSLeftArrowFunctionKey)), .seekBackward)
        XCTAssertEqual(PlayerKeyRouting.key(for: arrowEvent(NSRightArrowFunctionKey)), .seekForward)
        XCTAssertEqual(PlayerKeyRouting.key(for: arrowEvent(NSUpArrowFunctionKey)), .volumeUp)
        XCTAssertEqual(PlayerKeyRouting.key(for: arrowEvent(NSDownArrowFunctionKey)), .volumeDown)

        XCTAssertNil(PlayerKeyRouting.key(for: keyEvent("f")))
        XCTAssertNil(PlayerKeyRouting.key(for: keyEvent("F")))
        XCTAssertNil(PlayerKeyRouting.key(for: keyEvent("g")))
        // ⌘← belongs to whatever text is being edited.
        XCTAssertNil(
            PlayerKeyRouting.key(for: arrowEvent(NSLeftArrowFunctionKey, modifiers: .command))
        )

        // Arrow keys always carry these two, and neither is a modifier anybody
        // is holding down.
        XCTAssertEqual(
            PlayerKeyRouting.key(for: arrowEvent(NSUpArrowFunctionKey, modifiers: [.function, .numericPad])),
            .volumeUp
        )
    }

    func testAFocusedListKeepsTheVerticalArrowsAndNothingElse() {
        let table = NSTableView()

        XCTAssertFalse(PlayerKeyRouting.belongsToPlayer(.volumeUp, firstResponder: table))
        XCTAssertFalse(PlayerKeyRouting.belongsToPlayer(.volumeDown, firstResponder: table))

        // Seeking and play/pause mean nothing to a list, so they stay with the
        // player while a folder is being read through.
        XCTAssertTrue(PlayerKeyRouting.belongsToPlayer(.seekForward, firstResponder: table))
        XCTAssertTrue(PlayerKeyRouting.belongsToPlayer(.seekBackward, firstResponder: table))
        XCTAssertTrue(PlayerKeyRouting.belongsToPlayer(.togglePlayPause, firstResponder: table))
    }

    func testFocusInsideAListRowIsStillTheList() {
        let table = NSTableView()
        let cell = NSView()
        table.addSubview(cell)

        XCTAssertFalse(PlayerKeyRouting.belongsToPlayer(.volumeUp, firstResponder: cell))
    }

    func testTextBeingEditedKeepsEveryBareKeyIncludingTheSpaceBar() {
        let fieldEditor = NSTextView()

        for key in [PlayerKey.togglePlayPause, .seekForward, .volumeUp] {
            XCTAssertFalse(PlayerKeyRouting.belongsToPlayer(key, firstResponder: fieldEditor))
        }
    }

    func testKeysReachThePlayerWhenNothingElseWantsThem() {
        for key in [PlayerKey.togglePlayPause, .seekForward, .volumeUp] {
            XCTAssertTrue(PlayerKeyRouting.belongsToPlayer(key, firstResponder: NSView()))
            XCTAssertTrue(PlayerKeyRouting.belongsToPlayer(key, firstResponder: nil))
        }
    }

    /// The handoff above rests on SwiftUI's `List` being a table view
    /// underneath. If that ever stops being true, the vertical arrows go on
    /// changing the volume while the browser has focus, and this is where that
    /// shows up.
    func testTheBrowsersListIsBackedByATableView() {
        let list = List(selection: .constant(URL?.none)) {
            ForEach(["a", "b", "c"], id: \.self) { name in
                Text(name).tag(URL(fileURLWithPath: "/\(name)"))
            }
        }

        let hostingView = NSHostingView(rootView: list)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            containsTableView(hostingView),
            "SwiftUI List is no longer table-backed; PlayerKeyRouting cannot see the browser's focus"
        )
    }

    private func containsTableView(_ view: NSView) -> Bool {
        if view is NSTableView { return true }
        return view.subviews.contains(where: containsTableView)
    }

    private func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    private func arrowEvent(
        _ functionKey: Int,
        modifiers: NSEvent.ModifierFlags = [.function, .numericPad]
    ) -> NSEvent {
        keyEvent(String(UnicodeScalar(UInt32(functionKey))!), modifiers: modifiers)
    }
}
