import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel
    let library: FolderLibrary

    var body: some View {
        Group {
            if let engine = appModel.engine, let videoView = appModel.videoView {
                PlayerLayout(
                    appModel: appModel,
                    engine: engine,
                    videoView: videoView,
                    library: library
                )
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

private struct PlayerLayout: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: OwlVideoView
    let library: FolderLibrary

    @ObservedObject private var state: PlayerState

    /// Set while the picture is on its way out, so that the overlay leaves
    /// before playback is torn down rather than after it.
    @State private var isDismissing = false

    private static let playerTransition = Animation.spring(response: 0.42, dampingFraction: 0.88)

    init(
        appModel: AppModel,
        engine: MPVPlayerEngine,
        videoView: OwlVideoView,
        library: FolderLibrary
    ) {
        self.appModel = appModel
        self.engine = engine
        self.videoView = videoView
        self.library = library
        _state = ObservedObject(wrappedValue: appModel.playerState)
    }

    var body: some View {
        ZStack {
            FolderBrowserView(appModel: appModel, library: library)

            if state.hasMedia, !isDismissing {
                playerOverlay
                    .zIndex(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(Self.playerTransition, value: state.hasMedia)
    }

    /// Sends the picture off the bottom of the window with playback still
    /// running, and only stops it once the overlay has left. Closing the video
    /// first would blank the surface and slide an empty black panel away.
    private func dismissPlayer() {
        guard !isDismissing else { return }
        withAnimation(Self.playerTransition, completionCriteria: .removed) {
            isDismissing = true
        } completion: {
            appModel.closeVideo()
            isDismissing = false
        }
    }

    private var playerOverlay: some View {
        PlayerContainerView(
            appModel: appModel,
            engine: engine,
            videoView: videoView,
            showsQueueControls: true,
            onClose: dismissPlayer
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The window follows the system, but the picture is always on black,
        // and controls laid over black are read in the dark.
        .environment(\.colorScheme, .dark)
        // The picture takes the whole window, title bar strip included. The
        // browser's header and toolbar are what the video is playing instead
        // of, so it covers them rather than sitting below them.
        .ignoresSafeArea()
    }
}
