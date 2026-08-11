import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerContainerView: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: OwlVideoView
    @ObservedObject var windowState: WindowState
    let isVideoSurfaceActive: Bool

    /// Whether there is a queue to move through. A window opened on one file has
    /// nothing to go on to, so it is shown neither a way there nor a way to
    /// shuffle a list of one.
    let showsQueueControls: Bool

    @ObservedObject private var state: PlayerState
    @ObservedObject private var queue: PlaybackQueue
    @State private var controlsVisible = true
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var isCursorHidden = false
    @State private var subtitleDelayIndicatorVisible = false
    @State private var subtitleDelayDismissTask: Task<Void, Never>?

    init(
        appModel: AppModel,
        engine: MPVPlayerEngine,
        videoView: OwlVideoView,
        windowState: WindowState,
        isVideoSurfaceActive: Bool = true,
        showsQueueControls: Bool = true
    ) {
        self.appModel = appModel
        self.engine = engine
        self.videoView = videoView
        self.windowState = windowState
        self.isVideoSurfaceActive = isVideoSurfaceActive
        self.showsQueueControls = showsQueueControls
        _state = ObservedObject(wrappedValue: appModel.playerState)
        _queue = ObservedObject(wrappedValue: appModel.playbackQueue)
    }

    var body: some View {
        ZStack {
            Color.black

            VideoSurface(view: videoView, isActive: isVideoSurfaceActive)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    windowState.toggleFullscreen()
                }

            if state.hasMedia,
               !isVideoSurfaceActive,
               windowState.isFullscreenContentPresented {
                Button {
                    windowState.returnVideoFromFullscreen()
                } label: {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 34, weight: .semibold))
                        Text("Click to Exit Full Screen")
                            .font(.title3.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Returns the video to this window")
            }

            if !state.hasMedia {
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 46, weight: .light))
                    Text("Select an item below")
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }

            if state.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if subtitleDelayIndicatorVisible {
                subtitleDelayIndicator
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            VStack {
                if let error = state.errorMessage {
                    errorBanner(error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                if state.hasMedia, isVideoSurfaceActive {
                    PlayerControlsView(
                        appModel: appModel,
                        engine: engine,
                        windowState: windowState,
                        state: state,
                        queue: queue,
                        showsQueueControls: showsQueueControls,
                        isSeeking: $isSeeking,
                        seekValue: $seekValue
                    )
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 14)
                    .allowsHitTesting(controlsVisible)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: controlsVisible)
            .animation(.easeOut(duration: 0.18), value: state.hasMedia)
            .animation(.easeOut(duration: 0.18), value: state.errorMessage)
            .animation(.easeOut(duration: 0.18), value: subtitleDelayIndicatorVisible)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                revealControls()
            case .ended:
                scheduleControlsHide()
            }
        }
        .onChange(of: state.isPaused) { _, isPaused in
            if isPaused {
                hideTask?.cancel()
                controlsVisible = true
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: state.errorMessage) { _, message in
            scheduleErrorDismiss(for: message)
        }
        .onChange(of: state.subtitleDelayRevision) { _, _ in
            showSubtitleDelayIndicator()
        }
        .onChange(of: controlsVisible) { _, visible in
            updateCursorVisibility(controlsVisible: visible)
        }
        .onChange(of: windowState.isFullscreen) { _, isFullscreen in
            updateCursorVisibility(controlsVisible: controlsVisible)
        }
        .onDisappear {
            hideTask?.cancel()
            errorDismissTask?.cancel()
            subtitleDelayDismissTask?.cancel()
            showCursorIfHidden()
        }
        .background {
            PlayerKeyboardMonitor(handle: handle)
                .frame(width: 0, height: 0)
        }
    }

    private func handle(_ key: PlayerKey) {
        switch key {
        case .togglePlayPause:
            appModel.togglePlayPause()
        case .seekBackward:
            appModel.seek(by: -5)
        case .seekForward:
            appModel.seek(by: 5)
        case .volumeUp:
            appModel.changeVolume(by: 5)
        case .volumeDown:
            appModel.changeVolume(by: -5)
        case .toggleFullscreen:
            windowState.toggleFullscreen()
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button {
                state.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    /// Takes the error banner away on its own after a while.
    ///
    /// The banner covers the top of the picture and there is nothing left to do
    /// about most of what it reports — a file that would not open has already
    /// been replaced by the next one by the time it is read. The close button
    /// stays for anyone who wants it gone sooner, and the message is still
    /// selectable until then.
    private func scheduleErrorDismiss(for message: String?) {
        errorDismissTask?.cancel()
        guard message != nil else { return }
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, state.errorMessage == message else { return }
            state.errorMessage = nil
        }
    }

    private var subtitleDelayIndicator: some View {
        Text("Subtitle Delay: \(subtitleDelayLabel(state.subtitleDelay))")
            .font(.system(size: 20, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func subtitleDelayLabel(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        guard milliseconds != 0 else { return "0 ms" }
        return milliseconds > 0 ? "+\(milliseconds) ms" : "\(milliseconds) ms"
    }

    /// Shows the subtitle delay HUD and takes it away again after a beat, the
    /// same shape as `scheduleErrorDismiss`: cancel whatever timer is
    /// pending, so a burst of menu clicks keeps the HUD up rather than having
    /// it flicker off between them, then restart the clock.
    private func showSubtitleDelayIndicator() {
        subtitleDelayDismissTask?.cancel()
        subtitleDelayIndicatorVisible = true
        subtitleDelayDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            subtitleDelayIndicatorVisible = false
        }
    }

    private func revealControls() {
        controlsVisible = true
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideTask?.cancel()
        guard !state.isPaused, !isSeeking else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !state.isPaused, !isSeeking else { return }
            controlsVisible = false
        }
    }

    /// Keeps the pointer out of the way on the same schedule as the
    /// controller: it disappears with it and comes back the moment the
    /// controller does. Windowed playback never hides it — there is a title
    /// bar and surrounding chrome to reach there.
    ///
    /// `setHiddenUntilMouseMoves` rather than `hide()`/`unhide()`: the latter
    /// is a manually balanced counter that only ever un-hides through our own
    /// `onChange`, and our hover callback firing is not reliable enough for
    /// that to hold in a real (Spaces-backed) full screen window. The former
    /// is handled natively by AppKit, so a stray mouse move always brings the
    /// pointer back even if our own state falls out of sync.
    private func updateCursorVisibility(controlsVisible: Bool) {
        let shouldHide = windowState.isFullscreen && !controlsVisible
        guard shouldHide != isCursorHidden else { return }
        isCursorHidden = shouldHide
        NSCursor.setHiddenUntilMouseMoves(shouldHide)
    }

    private func showCursorIfHidden() {
        guard isCursorHidden else { return }
        isCursorHidden = false
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

private struct PlayerControlsView: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    @ObservedObject var windowState: WindowState
    @ObservedObject var state: PlayerState
    @ObservedObject var queue: PlaybackQueue
    let showsQueueControls: Bool
    @Binding var isSeeking: Bool
    @Binding var seekValue: Double
    @State private var isVolumePopoverPresented = false
    @AppStorage(SubtitlePreference.defaultsKey) private var subtitlesEnabledByDefault = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularControls
            compactControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var regularControls: some View {
        HStack(spacing: 12) {
            transportControls

            Divider()
                .frame(height: 18)

            volumeControl

            currentTimeLabel
            seekSlider
                .frame(minWidth: 120)
                .layoutPriority(1)
            durationLabel

            secondaryControls
        }
        // Including the surrounding padding, this layout is selected at
        // approximately 630 points or wider.
        .frame(minWidth: 560)
    }

    private var compactControls: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                HStack {
                    Text(timeString(isSeeking ? seekValue : state.currentTime))
                    Spacer()
                    Text(timeString(state.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                seekSlider
                    .frame(minWidth: 80)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 14) {
                transportControls

                volumeControl

                Spacer(minLength: 4)
                secondaryControls
            }
        }
    }

    @ViewBuilder
    private var transportControls: some View {
        Group {
            if showsQueueControls {
                controlButton("backward.end.fill", help: "Previous video") {
                    appModel.playPrevious()
                }
            }

            controlButton(
                state.isPaused ? "play.fill" : "pause.fill",
                size: 20,
                help: state.isPaused ? "Play" : "Pause"
            ) {
                appModel.togglePlayPause()
            }

            if showsQueueControls {
                controlButton("forward.end.fill", help: "Next video") {
                    appModel.playNext()
                }
            }
        }
    }

    private var currentTimeLabel: some View {
        Text(timeString(isSeeking ? seekValue : state.currentTime))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 54, alignment: .trailing)
    }

    private var seekSlider: some View {
        TimelinePreviewScrubber(
            currentTime: state.currentTime,
            duration: state.duration,
            url: state.currentURL,
            isSeeking: $isSeeking,
            seekValue: $seekValue
        ) { value in
            engine.seek(to: value)
        }
    }

    private var durationLabel: some View {
        Text(timeString(state.duration))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 54, alignment: .leading)
    }

    @ViewBuilder
    private var secondaryControls: some View {
        Group {
            speedMenu
            audioMenu
            subtitleMenu

            if showsQueueControls {
                controlButton(
                    "shuffle",
                    foregroundStyle: queue.isShuffled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary),
                    help: queue.isShuffled ? "Shuffle On" : "Shuffle Off"
                ) {
                    queue.isShuffled.toggle()
                }
            }

            if showsQueueControls {
                controlButton(
                    queue.repeatMode.symbolName,
                    foregroundStyle: queue.repeatMode == .off
                        ? AnyShapeStyle(Color.primary)
                        : AnyShapeStyle(Color.accentColor),
                    help: queue.repeatMode.label
                ) {
                    queue.cycleRepeatMode()
                }
            } else {
                controlButton(
                    "repeat",
                    foregroundStyle: queue.repeatMode == .off
                        ? AnyShapeStyle(Color.primary)
                        : AnyShapeStyle(Color.accentColor),
                    help: queue.repeatMode == .off ? "Repeat Off" : "Repeat On"
                ) {
                    queue.toggleRepeatOne()
                }
            }

            controlButton(
                windowState.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: windowState.isFullscreen ? "Exit Full Screen" : "Enter Full Screen"
            ) {
                windowState.toggleFullscreen()
            }
        }
    }

    private var volumeSymbol: String {
        if state.isMuted || state.volume <= 0 {
            return "speaker.slash"
        }
        if state.volume <= 33 {
            return "speaker.wave.1"
        }
        if state.volume <= 66 {
            return "speaker.wave.2"
        }
        return "speaker.wave.3"
    }

    private var volumeControl: some View {
        Button {
            isVolumePopoverPresented.toggle()
        } label: {
            Image(systemName: volumeSymbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isVolumePopoverPresented, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        engine.toggleMute()
                    } label: {
                        Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(state.isMuted ? "Unmute" : "Mute")

                    Text("Volume")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(state.volume.rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: Binding(
                    get: { state.volume },
                    set: {
                        state.volume = $0
                        engine.setVolume($0)
                    }
                ), in: 0...100)
                .frame(width: 190)
            }
            .padding(14)
            .frame(width: 220)
        }
        .help("Volume")
    }

    private static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speedPresets, id: \.self) { preset in
                trackToggle(
                    speedLabel(preset),
                    selected: abs(state.speed - preset) < 0.001
                ) {
                    appModel.setSpeed(preset)
                }
            }
        } label: {
            Text(speedLabel(state.speed))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 26, minHeight: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback Speed")
    }

    private func speedLabel(_ speed: Double) -> String {
        let rounded = (speed * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))x"
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return "\(text)x"
    }

    private static let subtitleDelayStep: Double = 0.25

    private var subtitleMenu: some View {
        Menu {
            trackToggle("Off", selected: state.selectedSubtitleID == nil) {
                engine.setSubtitle(id: nil)
            }

            if !state.subtitles.isEmpty {
                Divider()
                ForEach(state.subtitles) { track in
                    trackToggle(
                        track.displayName + (track.isExternal ? " — External" : ""),
                        selected: track.isSelected
                    ) {
                        engine.setSubtitle(id: track.id)
                    }
                }
            }

            Divider()
            Button("Load Subtitle…") {
                chooseSubtitle()
            }
            Toggle("Show Subtitles Automatically", isOn: $subtitlesEnabledByDefault)

            Divider()
            Button("Increase Subtitle Delay") {
                appModel.changeSubtitleDelay(by: Self.subtitleDelayStep)
            }
            Button("Decrease Subtitle Delay") {
                appModel.changeSubtitleDelay(by: -Self.subtitleDelayStep)
            }
            Button("Reset Subtitle Delay") {
                appModel.resetSubtitleDelay()
            }
        } label: {
            Image(systemName: "captions.bubble")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Subtitles")
    }

    private var audioMenu: some View {
        Menu {
            if state.audioTracks.isEmpty {
                Text("No alternate audio tracks")
            } else {
                ForEach(state.audioTracks) { track in
                    trackToggle(
                        track.displayName + (track.isExternal ? " — External" : ""),
                        selected: track.isSelected
                    ) {
                        engine.setAudio(id: track.id)
                    }
                }
            }
        } label: {
            Image(systemName: "waveform")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Audio Tracks")
    }

    /// Track pickers read as radio buttons, but menus draw their selection with a
    /// checkmark, the same one the preference toggle below them gets.
    private func trackToggle(
        _ title: String,
        selected: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { selected },
            set: { if $0 { select() } }
        ))
    }

    private func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.title = "Choose Subtitle"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub", "idx"]
            .compactMap { UTType(filenameExtension: $0) }

        panel.presentAsSheet { urls in
            guard let url = urls.first else { return }
            engine.loadSubtitle(url)
        }
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat = 15,
        foregroundStyle: AnyShapeStyle = AnyShapeStyle(Color.primary),
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
