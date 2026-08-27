import SwiftUI

/// A window showing one file: the player, and nothing else.
///
/// There is no browser under it and no queue beside it. What was asked for was
/// this file, so the window plays this file and stops, and the folder window
/// carries on with its own.
struct FilePlayerView: View {
    let url: URL
    @ObservedObject var appModel: AppModel

    var body: some View {
        Group {
            if let engine = appModel.engine, let videoView = appModel.videoView {
                PlayerContainerView(
                    appModel: appModel,
                    engine: engine,
                    videoView: videoView,
                    showsQueueControls: false
                )
            } else {
                LibMPVSetupView(
                    errorMessage: appModel.startupError,
                    retry: appModel.retryLibMPV
                )
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .background(Color.black)
        .preferredColorScheme(.dark)
        // In fullscreen the window's content is the whole screen, title bar
        // strip included, and the picture is what belongs under it. Laid out
        // inside the safe area instead, the video would keep a bar's worth of
        // black above it and sit off-centre on the screen.
        .ignoresSafeArea()
        .background {
            ActivePlayerTracker(
                target: PlayerTarget(appModel: appModel)
            )
            .frame(width: 0, height: 0)
        }
        .onAppear(perform: start)
        // A window that opened onto the setup screen has nothing to play until
        // libmpv is found; playing then is what the retry was for.
        .onChange(of: appModel.engine == nil) { _, _ in start() }
    }

    private func start() {
        guard appModel.engine != nil, appModel.playerState.currentURL == nil else {
            return
        }
        appModel.play(url, from: [url], directory: nil)
    }
}
