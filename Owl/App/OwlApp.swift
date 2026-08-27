import AppKit
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct OwlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel: AppModel
    @StateObject private var windowState = WindowState()

    /// Held here rather than inside the model, because the browser is the
    /// window's and a window opened on one file has neither.
    private let library: FolderLibrary

    #if canImport(Sparkle)
    #if DEBUG
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #else
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif
    #endif

    init() {
        let library = FolderLibrary()
        self.library = library
        _appModel = StateObject(wrappedValue: AppModel(folderLibrary: library))
    }

    var body: some Scene {
        WindowGroup("Owl") {
            ContentView(appModel: appModel, windowState: windowState, library: library)
                .frame(minWidth: 720, minHeight: 560)
                .background {
                    WindowFrameAutosave(key: "MainWindowFrame")
                        .frame(width: 0, height: 0)
                    WindowTitleHidden()
                        .frame(width: 0, height: 0)
                }
        }
        .defaultSize(width: 1_080, height: 760)
        .windowStyle(.hiddenTitleBar)
        // A window group answers every file the app is asked to open by opening
        // one of itself, on top of the folder window already up and beside the
        // window the file is really going to. The files are the delegate's to
        // handle, so this group is told to expect none of them.
        .handlesExternalEvents(matching: [])
        .commands {
            FileCommands()
            PlaybackCommands()
            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif
        }
    }
}

/// Opening files from the Finder: a double click, a drop on the icon in the
/// Dock, or Open With.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where FolderLibrary.isVideo(url) {
            FilePlayerWindows.shared.open(url)
        }
    }
}

/// The "Check for Updates…" menu item.
///
/// Never disabled: a `disabled` in the main menu holds the value it was
/// first built with (see `PlaybackCommands`), and `canCheckForUpdates` starts
/// out false before Sparkle finishes its startup check, which would grey the
/// item out for the rest of the run. `checkForUpdates()` is safe to call
/// while a check isn't possible yet — it just does nothing.
#if canImport(Sparkle)
struct CheckForUpdatesView: View {
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
    }
}
#endif

/// The File menu.
///
/// It replaces the New Window item it is built on rather than joining it. The
/// folder window owns the library, the browser and one player, and there is only
/// ever one of it; a second copy would show the same picture in neither window.
/// Opening a file is what the second window is for.
struct FileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open File…") {
                FilePlayerWindows.shared.chooseFile()
            }
            .keyboardShortcut("o")
        }
    }
}

/// The Playback menu.
///
/// The items act on the player in the frontmost window, which is why they read
/// `ActivePlayer` rather than holding a model of their own: there is one menu bar
/// and there may be several players. The window is looked up when the item is
/// chosen, not when the menu is built, so an item chosen in one window never
/// reaches the player in another.
///
/// Nothing here is disabled when there is no player to act on. A `disabled` in
/// the main menu holds the value it was first built with — the menu is built
/// before any window has come to the front, so every item would stay grey for
/// the rest of the run. The actions do nothing when there is nothing to do,
/// which is the same as choosing them with no video open ever did.
///
/// Only full screen carries a key equivalent, and it is the system one. The
/// space bar, the arrows and a bare `f` all work too, but they are watched by
/// `PlayerKeyboardMonitor` instead of being bound here: a menu equivalent is
/// matched before the key event reaches the window, so binding an unmodified
/// key in the menu takes it away from every view in the app for good.
struct PlaybackCommands: Commands {
    @ObservedObject private var activePlayer = ActivePlayer.shared

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") {
                target?.appModel.togglePlayPause()
            }

            Button("Seek Backward 5 Seconds") {
                target?.appModel.seek(by: -5)
            }

            Button("Seek Forward 5 Seconds") {
                target?.appModel.seek(by: 5)
            }

            Button("Volume Up") {
                target?.appModel.changeVolume(by: 5)
            }

            Button("Volume Down") {
                target?.appModel.changeVolume(by: -5)
            }

            Divider()

            Button("Increase Speed") {
                target?.appModel.changeSpeed(by: 0.25)
            }

            Button("Decrease Speed") {
                target?.appModel.changeSpeed(by: -0.25)
            }

            Button("Reset Speed") {
                target?.appModel.setSpeed(1)
            }

            Divider()

            Button(isFullscreen ? "Exit Full Screen" : "Enter Full Screen") {
                target?.windowState.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }

    private var target: PlayerTarget? {
        activePlayer.target
    }

    private var isFullscreen: Bool {
        target?.windowState.isFullscreen == true
    }
}
