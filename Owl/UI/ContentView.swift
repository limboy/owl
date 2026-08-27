import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var windowState: WindowState
    let library: FolderLibrary

    var body: some View {
        Group {
            if let engine = appModel.engine, let videoView = appModel.videoView {
                PlayerLayout(
                    appModel: appModel,
                    engine: engine,
                    videoView: videoView,
                    windowState: windowState,
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
                target: PlayerTarget(appModel: appModel, windowState: windowState)
            )
            .frame(width: 0, height: 0)
        }
    }
}

private struct PlayerLayout: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: OwlVideoView
    @ObservedObject var windowState: WindowState
    let library: FolderLibrary

    @ObservedObject private var state: PlayerState

    init(
        appModel: AppModel,
        engine: MPVPlayerEngine,
        videoView: OwlVideoView,
        windowState: WindowState,
        library: FolderLibrary
    ) {
        self.appModel = appModel
        self.engine = engine
        self.videoView = videoView
        self.windowState = windowState
        self.library = library
        _state = ObservedObject(wrappedValue: appModel.playerState)
    }

    var body: some View {
        ZStack {
            FolderBrowserView(appModel: appModel, library: library)

            if state.hasMedia {
                playerOverlay
                    .zIndex(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: state.hasMedia)
        .onAppear {
            windowState.attachVideoView(videoView)
        }
        .background {
            FullscreenPlayerLayer(
                appModel: appModel,
                engine: engine,
                videoView: videoView,
                windowState: windowState,
                showsQueueControls: true
            )
        }
    }

    private var playerOverlay: some View {
        PlayerContainerView(
            appModel: appModel,
            engine: engine,
            videoView: videoView,
            windowState: windowState,
            isVideoSurfaceActive: !windowState.isFullscreen,
            showsQueueControls: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                    appModel.closeVideo()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close Video")
            .accessibilityLabel("Close Video")
            .padding(16)
        }
        // The window follows the system, but the picture is always on black,
        // and controls laid over black are read in the dark.
        .environment(\.colorScheme, .dark)
        // The picture takes the whole window, title bar strip included. The
        // browser's header and toolbar are what the video is playing instead
        // of, so it covers them rather than sitting below them.
        .ignoresSafeArea()
    }
}
