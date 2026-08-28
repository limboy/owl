import AppKit
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct OwlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel: AppModel

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
            ContentView(appModel: appModel, library: library)
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
            SubtitleCommands()
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
        }
    }

    private var target: PlayerTarget? {
        activePlayer.target
    }
}

/// The Subtitles menu: everything subtitles can be set to, in one place.
///
/// It acts on the frontmost window's player through `ActivePlayer`, and is
/// built and disabled on the same terms as `PlaybackCommands` — see the
/// reasoning there.
///
/// The keys here carry Option, where the player's own bare `Z` and `J` do not.
/// A key equivalent in the main menu is matched before the window sees the
/// event — see `PlayerKeyboardMonitor` — so a bare letter here would be taken
/// from every text field in the app, the search field of the very panel this
/// menu opens included. The bare keys keep working over the picture, where
/// nothing is being typed into.
///
/// Which track is showing is not here. That is a choice about the file being
/// watched rather than a setting, it changes as often as the file does, and it
/// belongs beside the picture: the subtitle button in the player controls keeps
/// it, along with the delay, which is the one adjustment made while watching.
struct SubtitleCommands: Commands {
    @ObservedObject private var activePlayer = ActivePlayer.shared
    @AppStorage(SubtitlePreference.scaleKey) private var subtitleScale = 1.0

    var body: some Commands {
        CommandMenu("Subtitles") {
            Button("Load Subtitle…") {
                guard let target else { return }
                SubtitleFile.choose { url in
                    target.appModel.loadExternalSubtitle(url)
                }
            }
            Button("Next Subtitle Track") {
                target?.appModel.cycleSubtitle()
            }
            .keyboardShortcut("j", modifiers: .option)

            Divider()

            Button("Increase Subtitle Delay") {
                target?.appModel.changeSubtitleDelay(by: SubtitlePreference.delayStep)
            }
            .keyboardShortcut("z", modifiers: [.shift, .option])
            Button("Decrease Subtitle Delay") {
                target?.appModel.changeSubtitleDelay(by: -SubtitlePreference.delayStep)
            }
            .keyboardShortcut("z", modifiers: .option)
            Button("Reset Subtitle Delay") {
                target?.appModel.resetSubtitleDelay()
            }

            Divider()

            // A label rather than an item, the way the audio menu says it has
            // nothing to offer. Nothing here is `disabled` at its limits: a
            // disabled state in the main menu holds the value the menu was
            // built with, and the size clamps itself anyway.
            Text("Subtitle Size — \(Int((subtitleScale * 100).rounded()))%")
            Button("Larger Subtitles") {
                target?.appModel.changeSubtitleScale(by: SubtitlePreference.scaleStep)
            }
            Button("Smaller Subtitles") {
                target?.appModel.changeSubtitleScale(by: -SubtitlePreference.scaleStep)
            }
            Button("Reset Subtitle Size") {
                target?.appModel.resetSubtitleScale()
            }
        }
    }

    private var target: PlayerTarget? {
        activePlayer.target
    }
}
