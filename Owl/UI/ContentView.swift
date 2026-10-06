import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel
    let library: FolderLibrary
    let player: LibraryPlayerWindow

    var body: some View {
        Group {
            if appModel.engine != nil {
                // The videos picked here play in a window of their own; this
                // one stays the browser.
                FolderBrowserView(appModel: appModel, library: library, player: player)
            } else {
                LibMPVSetupView(
                    errorMessage: appModel.startupError,
                    retry: appModel.retryLibMPV
                )
            }
        }
        .background {
            ActivePlayerTracker(
                target: PlayerTarget(appModel: appModel)
            )
            .frame(width: 0, height: 0)
        }
    }
}
