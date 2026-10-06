import AppKit
import SwiftUI

struct PlayerContainerView: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: OwlVideoView

    let isVideoSurfaceActive: Bool

    @ObservedObject private var state: PlayerState
    @State private var controlsVisible = true
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var noticeVisible = false
    @State private var noticeDismissTask: Task<Void, Never>?

    /// How many menus are open over the picture.
    ///
    /// A menu is its own window, so opening one takes the pointer off this one
    /// and the controls begin their two-and-a-half seconds to hiding — taking
    /// the button the menu is attached to with them, out from under a menu
    /// still being read. Counted rather than flagged because a submenu opens
    /// while its parent is still open, and the parent's controls have to
    /// survive the submenu closing.
    @State private var openMenuCount = 0

    /// Whether the pointer is over the control bar, which keeps it up for as
    /// long as it rests there.
    @State private var isPointerOverControls = false

    /// Whether the pointer is over the player at all. Leaving it takes the
    /// controls away almost at once rather than after the usual wait: they
    /// are for the picture, and the pointer has gone elsewhere.
    @State private var isPointerInPlayer = false

    /// Which panel is open over the picture from its button in the controls,
    /// if any. The controls stay up under it, since it hangs off them and
    /// would go when they do.
    @State private var openPanel: PlayerPanel?

    /// Whether the Live Text button has the paused picture's text picked out.
    /// The controls stay down for as long as it does — the text being read is
    /// in the picture, some of it under where the controls would be — and come
    /// back once it is switched off.
    @State private var isPickingOutText = false

    init(
        appModel: AppModel,
        engine: MPVPlayerEngine,
        videoView: OwlVideoView,
        isVideoSurfaceActive: Bool = true
    ) {
        self.appModel = appModel
        self.engine = engine
        self.videoView = videoView
        self.isVideoSurfaceActive = isVideoSurfaceActive
        _state = ObservedObject(wrappedValue: appModel.playerState)
    }

    var body: some View {
        ZStack {
            Color.black

            VideoSurface(view: videoView, isActive: isVideoSurfaceActive)
                .contentShape(Rectangle())

            LiveTextOverlay(
                videoView: videoView,
                isActive: isVideoSurfaceActive
                    && state.hasMedia
                    && state.isPaused
                    && !state.isLoading
                    && state.errorMessage == nil,
                frame: LiveTextFrame(
                    url: state.currentURL,
                    time: state.currentTime,
                    subtitleID: state.selectedSubtitleID,
                    subtitleDelay: state.subtitleDelay
                ),
                onHighlightChange: { isPickingOutText = $0 }
            )

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

            if noticeVisible {
                noticeIndicator
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if openPanel != nil {
                // Takes a click anywhere on the picture to put the panel away,
                // as a click outside a menu would.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { openPanel = nil }
            }

            VStack {
                if let error = state.errorMessage {
                    errorBanner(error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                if state.hasMedia {
                    PlayerControlsView(
                        appModel: appModel,
                        engine: engine,
                        state: state,
                        isSeeking: $isSeeking,
                        seekValue: $seekValue,
                        openPanel: $openPanel
                    )
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 14)
                    .allowsHitTesting(controlsVisible)
                    .onHover(perform: pointerOverControlsChanged)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: controlsVisible)
            .animation(.easeOut(duration: 0.18), value: state.hasMedia)
            .animation(.easeOut(duration: 0.18), value: state.errorMessage)
            .animation(.easeOut(duration: 0.18), value: noticeVisible)
        }
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                // The pointer is over the picture, which a tracking menu would
                // have taken for itself: whatever the count says, no menu is
                // open, and this is what puts it right if an end of tracking
                // ever goes missing.
                openMenuCount = 0
                isPointerInPlayer = true
                revealControls()
            case .ended:
                // The window's title bar lies over the top of the picture
                // but is not part of this view; moving onto it is not leaving.
                isPointerInPlayer = isPointerInWindow
                scheduleControlsHide(soon: !isPointerInPlayer)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            openMenuCount += 1
            hideTask?.cancel()
            // A menu over picked-out text is the text's own: copy, look up.
            if !isPickingOutText {
                controlsVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            openMenuCount = max(0, openMenuCount - 1)
            scheduleControlsHide()
        }
        // Pausing or playing shows the controls, to show which it is now,
        // and they go again after the usual wait — paused or not, the picture
        // is what is being looked at.
        .onChange(of: state.isPaused) { _, _ in
            revealControls()
        }
        .onChange(of: isPickingOutText) { _, isPicking in
            if isPicking {
                hideTask?.cancel()
                controlsVisible = false
            } else {
                revealControls()
            }
        }
        .onChange(of: openPanel) { _, panel in
            if panel != nil {
                hideTask?.cancel()
                controlsVisible = true
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: state.errorMessage) { _, message in
            scheduleErrorDismiss(for: message)
        }
        .onChange(of: state.noticeRevision) { _, _ in
            showNotice()
        }
        .onChange(of: controlsVisible, initial: true) { _, isVisible in
            updateCursorVisibility()
            state.areControlsShown = isVisible
        }
        .onDisappear {
            hideTask?.cancel()
            errorDismissTask?.cancel()
            noticeDismissTask?.cancel()
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        // A subtitle file is dropped on the picture far more readily than it is
        // found through an open panel, and the picture is the only part of the
        // window still on screen once the player is up. The drag cursor's copy
        // badge is the whole affordance here: a border and a tint would sit
        // over the very picture the drop is aimed at.
        // The empty `isTargeted` picks the overload whose action reports back
        // whether the drop was taken; there is nothing to show while it hovers.
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls)
        } isTargeted: { _ in }
        .background {
            PlayerKeyboardMonitor(handle: handle)
                .frame(width: 0, height: 0)
            WindowPointerMonitor { isInside in
                isPointerInPlayer = isInside
                if isInside {
                    revealControls()
                } else {
                    scheduleControlsHide(soon: true)
                }
            }
            .frame(width: 0, height: 0)
        }
    }

    private func handle(_ key: PlayerKey) {
        switch key {
        case .togglePlayPause:
            appModel.togglePlayPause()
        case .seekBackward:
            appModel.seek(by: -10)
        case .seekForward:
            appModel.seek(by: 10)
        case .volumeUp:
            appModel.changeVolume(by: 5)
        case .volumeDown:
            appModel.changeVolume(by: -5)
        case .increaseSubtitleDelay:
            appModel.changeSubtitleDelay(by: SubtitlePreference.delayStep)
        case .decreaseSubtitleDelay:
            appModel.changeSubtitleDelay(by: -SubtitlePreference.delayStep)
        case .cycleSubtitle:
            appModel.cycleSubtitle()
        case .showPosition:
            appModel.showPosition()
        case .nextChapter:
            appModel.playNextChapter()
        case .previousChapter:
            appModel.playPreviousChapter()
        }
    }

    /// Takes a subtitle file for the video that is playing, or a video to play
    /// instead of it. Anything else is refused rather than quietly swallowed.
    private func accept(_ urls: [URL]) -> Bool {
        if let subtitle = urls.first(where: SubtitleFile.isSubtitle) {
            appModel.loadExternalSubtitle(subtitle)
            return true
        }
        let videos = urls.filter(FolderLibrary.isVideo)
        guard let video = videos.first else { return false }
        // One video on its own is the same ask as File ▸ Open Video: it gets a
        // window of its own and a place in Open Recent. This window is quieted
        // first so the two are not heard at once — unless the file dropped is
        // the one already playing here, which only raises this window again.
        if videos.count == 1 {
            if appModel.playerState.currentURL?.standardizedFileURL != video.standardizedFileURL {
                appModel.yieldPlayback()
            }
            FilePlayerWindows.shared.open(video)
            return true
        }
        appModel.play(video, from: videos, directory: video.deletingLastPathComponent())
        return true
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .foregroundStyle(.white)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button {
                state.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .playerPanel(cornerRadius: 10)
        .padding()
    }

    private func scheduleErrorDismiss(for message: String?) {
        errorDismissTask?.cancel()
        guard message != nil else { return }
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, state.errorMessage == message else { return }
            state.errorMessage = nil
        }
    }

    /// The word over the picture, with a bar under it for the notices that
    /// are a place on a scale: how loud, and how far in.
    private var noticeIndicator: some View {
        HStack(spacing: 14) {
            Image(systemName: noticeSymbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                Text(noticeText)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                if let fraction = noticeFraction {
                    noticeBar(fraction)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .playerPanel(cornerRadius: 14)
    }

    private func noticeBar(_ fraction: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.25))
            Capsule()
                .fill(Color.white)
                .frame(width: 180 * min(max(fraction, 0), 1))
        }
        .frame(width: 180, height: 4)
    }

    private var noticeSymbol: String {
        switch state.notice {
        case .subtitleDelay, .subtitleScale, .subtitleTrack:
            return "captions.bubble"
        case .volume(let volume, let isMuted):
            return Self.volumeSymbol(volume: volume, isMuted: isMuted)
        case .speed(let speed):
            return Self.speedSymbol(speed: speed)
        case .chapter:
            return "list.bullet.rectangle"
        case .position:
            return state.isPaused ? "pause.fill" : "play.fill"
        }
    }

    private var noticeText: String {
        switch state.notice {
        case .subtitleDelay(let seconds):
            let milliseconds = Int((seconds * 1000).rounded())
            let value = milliseconds > 0 ? "+\(milliseconds) ms" : "\(milliseconds) ms"
            return "Subtitle Delay: \(value)"
        case .subtitleScale(let scale):
            return "Subtitle Size: \(Int((scale * 100).rounded()))%"
        case .subtitleTrack(let name):
            return "Subtitle: \(name)"
        case .volume(let volume, let isMuted):
            let level = "\(Int(volume.rounded()))%"
            return isMuted ? "Volume: \(level) (Muted)" : "Volume: \(level)"
        case .speed(let speed):
            return "Speed: \(playerSpeedLabel(speed))"
        case .chapter(let name):
            return name
        case .position:
            guard state.duration > 0 else { return playerTimeString(state.currentTime) }
            return "\(playerTimeString(state.currentTime)) / \(playerTimeString(state.duration))"
        }
    }

    private var noticeFraction: Double? {
        switch state.notice {
        case .volume(let volume, _):
            return volume / MPVPlayerEngine.volumeRange.upperBound
        case .position where state.duration > 0:
            return state.currentTime / state.duration
        default:
            return nil
        }
    }

    /// The speaker for a level, shared by the volume button and the notice so
    /// the two always draw the same one.
    static func volumeSymbol(volume: Double, isMuted: Bool) -> String {
        if isMuted || volume <= 0 {
            return "speaker.slash"
        }
        if volume <= 33 {
            return "speaker.wave.1"
        }
        if volume <= 66 {
            return "speaker.wave.2"
        }
        return "speaker.wave.3"
    }

    /// The gauge for a speed, its needle straight up at normal speed and
    /// leaning left or right of it as playback slows down or speeds up.
    /// Shared by the speed button and the notice, as the speaker is.
    static func speedSymbol(speed: Double) -> String {
        let needle: String
        if speed < 0.75 - 0.001 {
            needle = "0"
        } else if speed < 1 - 0.001 {
            needle = "33"
        } else if speed <= 1 + 0.001 {
            needle = "50"
        } else if speed <= 1.5 + 0.001 {
            needle = "67"
        } else {
            needle = "100"
        }
        return "gauge.with.dots.needle.\(needle)percent"
    }

    private func showNotice() {
        noticeDismissTask?.cancel()
        noticeVisible = true
        noticeDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            noticeVisible = false
        }
    }

    private func pointerOverControlsChanged(_ isOver: Bool) {
        isPointerOverControls = isOver
        // Hidden, the bar still reports the pointer over where it would be.
        if isOver, !isPickingOutText {
            hideTask?.cancel()
            controlsVisible = true
        } else {
            // Off the bar and out of the player in the same move.
            scheduleControlsHide(soon: !isPointerInPlayer)
        }
    }

    private var isPointerInWindow: Bool {
        guard let window = videoView.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    private func revealControls() {
        guard !isPickingOutText else { return }
        controlsVisible = true
        scheduleControlsHide()
    }

    /// Takes the pointer away with the controls, and gives it back with them.
    ///
    /// Only in fullscreen. In a window the pointer has a title bar, a dock and
    /// the rest of the desktop to be wanted for, and the picture has no claim
    /// on it there; fullscreen there is nothing else on the screen for it to
    /// point at. `setHiddenUntilMouseMoves` is what brings it back, and any
    /// movement is also what brings the controls back, so the two return
    /// together without this having to watch for the movement itself.
    private func updateCursorVisibility() {
        let isFullScreen = videoView.window?.styleMask.contains(.fullScreen) ?? false
        NSCursor.setHiddenUntilMouseMoves(!controlsVisible && isFullScreen)
    }

    /// Hides the controls after a while, or — `soon`, for the pointer leaving
    /// the player — after a moment. Not at once even then: opening a menu
    /// takes the pointer out of the window too, and the menu is only known
    /// about a moment after the pointer has gone.
    private func scheduleControlsHide(soon: Bool = false) {
        hideTask?.cancel()
        guard !isSeeking, openMenuCount == 0, !isPointerOverControls, openPanel == nil
        else { return }
        let delay: Duration = soon ? .milliseconds(150) : .seconds(2.5)
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !isSeeking, !isPointerOverControls, openPanel == nil
            else { return }
            controlsVisible = false
        }
    }
}

private struct PlayerControlsView: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    @ObservedObject var state: PlayerState
    @Binding var isSeeking: Bool
    @Binding var seekValue: Double
    @Binding var openPanel: PlayerPanel?

    /// The panel button the pointer is over, whose click is its own toggle.
    @State private var hoveredPanelButton: PlayerPanel?

    var body: some View {
        VStack(spacing: 6) {
            buttonRow
            seekSlider
                .frame(minWidth: 80)
                // Its preview of a frame rises over the buttons above it, and
                // has to be drawn over them, not under.
                .zIndex(1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .playerPanel(cornerRadius: 14)
        // A click anywhere on the bar puts the panel away too, alongside
        // whatever the click was for. Not a panel button's: that is its own
        // toggle.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if openPanel != nil, hoveredPanelButton == nil {
                openPanel = nil
            }
        })
        .overlay(alignment: .top) {
            // Drawn over the picture rather than in a popover, so it is the
            // same dark panel as the controls it opens from. It hangs from a
            // line along the top of the bar, and so grows upwards from there,
            // at the bar's right-hand end, above the button that opens it.
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        switch openPanel {
                        case .queue where appModel.playbackQueue.videos.count > 1:
                            PlayerQueueList(appModel: appModel, queue: appModel.playbackQueue) {
                                openPanel = nil
                            }
                        case .subtitles:
                            PlayerSubtitlePanel(appModel: appModel, state: state) {
                                openPanel = nil
                            }
                        default:
                            EmptyView()
                        }
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
        }
        .animation(.easeOut(duration: 0.15), value: openPanel)
    }

    /// Play/pause and the time on the left; volume, tracks, speed, subtitles
    /// and the folder's videos on the right. The window's title bar names the
    /// video.
    private var buttonRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                playPauseButton
                timeLabel
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                volumeMenu
                secondaryControls
                if appModel.playbackQueue.videos.count > 1 {
                    queueButton
                }
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Lists the videos around this one, playing through a folder, with
    /// shuffle and repeat beside them.
    private var queueButton: some View {
        panelButton(.queue, symbol: "list.bullet", size: 15, weight: .semibold, help: "Videos in This Folder")
    }

    /// Opens the panel of subtitle tracks, which stays up while tracks are
    /// picked — two of them, for Dual Subtitles — until a click elsewhere.
    private var subtitleButton: some View {
        panelButton(.subtitles, symbol: "captions.bubble", size: 16, weight: .regular, help: "Subtitles")
    }

    /// A button that opens `panel` over the picture, and closes it again.
    /// Lit while the panel is open.
    private func panelButton(
        _ panel: PlayerPanel,
        symbol: String,
        size: CGFloat,
        weight: Font.Weight,
        help: String
    ) -> some View {
        let isLit = hoveredPanelButton == panel || openPanel == panel
        return Button {
            openPanel = openPanel == panel ? nil : panel
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white)
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(isLit ? 0.14 : 0))
                        .padding(-3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isOver in
            if isOver {
                hoveredPanelButton = panel
            } else if hoveredPanelButton == panel {
                hoveredPanelButton = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: isLit)
        .help(help)
        .accessibilityLabel(help)
    }

    private var playPauseButton: some View {
        controlButton(
            state.isPaused ? "play.fill" : "pause.fill",
            size: 20,
            help: state.isPaused ? "Play" : "Pause"
        ) {
            appModel.togglePlayPause()
        }
    }

    /// "12:34 / 48:39": the time played, following a drag on the timeline,
    /// and the length.
    private var timeLabel: some View {
        Text("\(playerTimeString(isSeeking ? seekValue : state.currentTime)) / \(playerTimeString(state.duration))")
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.75))
            .monospacedDigit()
    }

    private var seekSlider: some View {
        TimelinePreviewScrubber(
            currentTime: state.currentTime,
            duration: state.duration,
            url: state.currentURL,
            chapters: state.chapters,
            isSeeking: $isSeeking,
            seekValue: $seekValue
        ) { value in
            engine.seek(to: value)
        }
    }

    @ViewBuilder
    private var secondaryControls: some View {
        Group {
            if state.audioTracks.count > 1 {
                audioMenu
            }
            speedMenu
            subtitleButton
        }
    }

    private var volumeSymbol: String {
        PlayerContainerView.volumeSymbol(volume: state.volume, isMuted: state.isMuted)
    }

    /// The levels the volume menu offers, loudest first.
    private static let volumeLevels: [Double] = [100, 75, 50, 25, 0]

    /// The speaker, which opens the levels to choose from.
    private var volumeMenu: some View {
        PlayerMenuButton(help: "Volume") {
            Self.volumeLevels.map { level in
                .choice("\(Int(level))%", selected: level == selectedVolumeLevel) {
                    selectVolume(level)
                }
            }
        } label: {
            Image(systemName: volumeSymbol + ".fill")
                .font(.system(size: 14, weight: .regular))
                // Wide enough for the loudest speaker, its back edge pinned,
                // so the buttons beside it stay put as the waves come and go.
                .frame(width: 24, height: 22, alignment: .leading)
        }
    }

    /// The level nearest the volume as it is, a mute counting as none, so
    /// a volume set some other way still checks one of them.
    private var selectedVolumeLevel: Double {
        let volume = state.isMuted ? 0 : state.volume
        return Self.volumeLevels.min { abs($0 - volume) < abs($1 - volume) } ?? 0
    }

    private func selectVolume(_ level: Double) {
        // A level above none is meant to be heard, so it lifts a mute too.
        if state.isMuted, level > 0 {
            engine.toggleMute()
        }
        state.volume = level
        engine.setVolume(level)
    }

    private static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// A gauge whose needle shows the current speed, which opens the speeds
    /// to choose from. The exact speed is in the menu and the button's help.
    private var speedMenu: some View {
        PlayerMenuButton(help: "Playback Speed: \(playerSpeedLabel(state.speed))") {
            Self.speedPresets.map { preset in
                .choice(playerSpeedLabel(preset), selected: abs(state.speed - preset) < 0.001) {
                    appModel.setSpeed(preset)
                }
            }
        } label: {
            Image(systemName: PlayerContainerView.speedSymbol(speed: state.speed))
                .font(.system(size: 15))
                .frame(width: 24, height: 22)
                .accessibilityLabel("Playback Speed")
                .accessibilityValue(playerSpeedLabel(state.speed))
        }
    }

    private var audioMenu: some View {
        PlayerMenuButton(help: "Audio Tracks") {
            if state.audioTracks.isEmpty {
                return [.note("No alternate audio tracks")]
            }
            return state.audioTracks.map { track in
                .choice(
                    track.displayName + (track.isExternal ? " — External" : ""),
                    selected: track.isSelected
                ) {
                    engine.setAudio(id: track.id)
                }
            }
        } label: {
            Image(systemName: "waveform")
                .frame(width: 22, height: 22)
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
}

/// The videos of the queue that is playing, opened from the title, with the
/// queue's shuffle and repeat at the top.
///
/// Listed in the folder's own order rather than the shuffled one: it is for
/// finding a video, and a folder is found by its order.
private struct PlayerQueueList: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var queue: PlaybackQueue
    let onPick: () -> Void

    @State private var hoveredVideo: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(queue.videos.enumerated()), id: \.element) { index, video in
                            row(video, number: index + 1)
                                .id(video)
                        }
                    }
                    .padding(6)
                }
                .onAppear {
                    if let current = queue.current {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 340, height: listHeight)
        .playerPanel(cornerRadius: 14)
    }

    /// Tall enough for the whole queue, up to a point.
    private var listHeight: CGFloat {
        let rows = CGFloat(min(queue.videos.count, 10))
        return 44 + 12 + rows * 30
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(positionText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)

            Spacer(minLength: 8)

            toggleButton(
                "shuffle",
                isOn: queue.isShuffled,
                help: queue.isShuffled ? "Shuffle On" : "Shuffle Off"
            ) {
                queue.isShuffled.toggle()
            }

            toggleButton(
                queue.repeatMode.symbolName,
                isOn: queue.repeatMode != .off,
                help: queue.repeatMode.label
            ) {
                queue.cycleRepeatMode()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
    }

    /// "3 of 12", or just the count before anything in it is playing.
    private var positionText: String {
        if let current = queue.current, let index = queue.videos.firstIndex(of: current) {
            return "\(index + 1) of \(queue.videos.count)"
        }
        return "\(queue.videos.count) Videos"
    }

    private func toggleButton(
        _ symbol: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isOn ? 1 : 0.45))
                .frame(width: 28, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(isOn ? 0.14 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func row(_ video: URL, number: Int) -> some View {
        let isCurrent = video == queue.current
        return Button {
            appModel.playFromQueue(video)
            onPick()
        } label: {
            HStack(spacing: 10) {
                Group {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(number)")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.5))
                            .monospacedDigit()
                    }
                }
                .frame(width: 24, alignment: .trailing)

                Text(video.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(Color.white.opacity(isCurrent ? 1 : 0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowFill(isCurrent: isCurrent, isHovered: hoveredVideo == video))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isOver in
            if isOver {
                hoveredVideo = video
            } else if hoveredVideo == video {
                hoveredVideo = nil
            }
        }
        .help(video.lastPathComponent)
    }

    /// The same white wash as the title's hover: lighter for the pointer,
    /// fuller for the video that is playing.
    private func rowFill(isCurrent: Bool, isHovered: Bool) -> Color {
        Color.white.opacity(isCurrent ? 0.14 : isHovered ? 0.08 : 0)
    }
}

/// "1.5x", "2x": a speed as the menu and the indicator both write it.
private func playerSpeedLabel(_ speed: Double) -> String {
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

private func playerTimeString(_ seconds: Double) -> String {
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

extension View {
    /// The panel every floating piece of the player is drawn on: the controls,
    /// the list of the queue, the error banner, the indicator, the preview of a
    /// frame over the timeline. One recipe rather than five copies of it, so
    /// they cannot drift apart.
    ///
    /// Liquid Glass, tinted dark and drawn in its dark appearance: the text
    /// and symbols on it are white, and have to stay legible over a bright
    /// frame as much as over a black one. The glass's own rim all but
    /// disappears against black — a letterbox, a dark scene — so a light
    /// line traces it.
    ///
    /// The glass and its line are a background, under the panel's contents,
    /// rather than an effect applied to them: glass draws what it is applied
    /// to in a layer of its own, and anything rising out of the panel — the
    /// preview of a frame over the timeline — then had the line across it.
    func playerPanel(cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(.black.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
                .environment(\.colorScheme, .dark)
                .allowsHitTesting(false)
        }
    }
}

/// Tells when the pointer comes into the window and leaves it, from anywhere
/// in it.
///
/// The player's own hover only covers the player: the title bar laid over the
/// top of the picture is not part of it, and a pointer that comes in or goes
/// out across the title bar never tells the player.
private struct WindowPointerMonitor: NSViewRepresentable {
    let onChange: @MainActor (_ isInside: Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onChange = onChange
    }

    final class MonitorView: NSView {
        var onChange: @MainActor (_ isInside: Bool) -> Void = { _ in }
        private var trackingArea: NSTrackingArea?
        private weak var trackedView: NSView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let trackingArea {
                trackedView?.removeTrackingArea(trackingArea)
            }
            trackingArea = nil
            // The window's frame view, which takes in the title bar as well
            // as the content: the whole window, edge to edge.
            guard let frameView = window?.contentView?.superview else { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            frameView.addTrackingArea(area)
            trackingArea = area
            trackedView = frameView
        }

        override func mouseEntered(with event: NSEvent) {
            onChange(true)
        }

        override func mouseExited(with event: NSEvent) {
            onChange(false)
        }

        override func removeFromSuperview() {
            if let trackingArea {
                trackedView?.removeTrackingArea(trackingArea)
            }
            trackingArea = nil
            super.removeFromSuperview()
        }
    }
}
