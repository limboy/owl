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
    @State private var isPlayerPresented = false
    @State private var isVideoSurfaceActive = false
    @State private var presentationID = UUID()

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
            FolderBrowserView(appModel: appModel, library: library, hasMedia: state.hasMedia)

            if isPlayerPresented {
                playerOverlay
                    .zIndex(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: state.hasMedia, initial: true) { _, hasMedia in
            guard !isDismissing else { return }
            let id = UUID()
            presentationID = id
            isVideoSurfaceActive = false
            withAnimation(Self.playerTransition, completionCriteria: .removed) {
                isPlayerPresented = hasMedia
            } completion: {
                guard presentationID == id, state.hasMedia, !isDismissing else { return }
                // AppKit must not keep moving a live OpenGL drawable while the
                // render worker is holding its context to present a frame.
                // Mount it at its final size, outside the insertion animation.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isVideoSurfaceActive = true
                }
            }
        }
    }

    /// Sends the picture off the bottom of the window with the current frame
    /// frozen on screen, pausing playback so the dismiss animation does not
    /// contend with continuous decoding and frame drawing. Closing the video
    /// first would blank the surface and slide an empty black panel away.
    private func dismissPlayer() {
        guard !isDismissing else { return }
        presentationID = UUID()
        appModel.yieldPlayback()
        isDismissing = true
        withAnimation(Self.playerTransition, completionCriteria: .removed) {
            isPlayerPresented = false
        } completion: {
            isVideoSurfaceActive = false
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
            isVideoSurfaceActive: isVideoSurfaceActive,
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
