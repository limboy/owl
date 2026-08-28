import AppKit
import SwiftUI

struct PlayerContainerView: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: OwlVideoView

    /// Whether there is a queue to move through. A window opened on one file has
    /// nothing to go on to, so it is shown neither previous nor next controls.
    let showsQueueControls: Bool

    /// Dismisses the current video, if this host has somewhere to dismiss it
    /// to. Hosts that pass nothing are shown no close button.
    ///
    /// The player owns the request but not the teardown: a host that slides
    /// the picture away wants the video to travel with it, so it runs its own
    /// animation and stops playback once that has finished.
    let onClose: (@MainActor () -> Void)?

    @ObservedObject private var state: PlayerState
    @State private var controlsVisible = true
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var subtitleNoticeVisible = false
    @State private var subtitleNoticeDismissTask: Task<Void, Never>?
    @State private var isDropTargeted = false

    /// How many menus are open over the picture.
    ///
    /// A menu is its own window, so opening one takes the pointer off this one
    /// and the controls begin their two-and-a-half seconds to hiding — taking
    /// the button the menu is attached to with them, out from under a menu
    /// still being read. Counted rather than flagged because a submenu opens
    /// while its parent is still open, and the parent's controls have to
    /// survive the submenu closing.
    @State private var openMenuCount = 0

    init(
        appModel: AppModel,
        engine: MPVPlayerEngine,
        videoView: OwlVideoView,
        showsQueueControls: Bool = true,
        onClose: (@MainActor () -> Void)? = nil
    ) {
        self.appModel = appModel
        self.engine = engine
        self.videoView = videoView
        self.showsQueueControls = showsQueueControls
        self.onClose = onClose
        _state = ObservedObject(wrappedValue: appModel.playerState)
    }

    var body: some View {
        ZStack {
            Color.black

            VideoSurface(view: videoView)
                .contentShape(Rectangle())

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

            if subtitleNoticeVisible {
                subtitleNoticeIndicator
                    .transition(.opacity)
                    .allowsHitTesting(false)
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
            .animation(.easeOut(duration: 0.18), value: subtitleNoticeVisible)
        }
        .overlay(alignment: .topTrailing) {
            if let onClose, state.hasMedia {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background {
                            Circle()
                                .fill(Color.black.opacity(0.72))
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay {
                                    Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                                }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close Video")
                .accessibilityLabel("Close Video")
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .padding(16)
            }
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
                revealControls()
            case .ended:
                scheduleControlsHide()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            openMenuCount += 1
            hideTask?.cancel()
            controlsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            openMenuCount = max(0, openMenuCount - 1)
            scheduleControlsHide()
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
        .onChange(of: state.subtitleNoticeRevision) { _, _ in
            showSubtitleNotice()
        }
        .onDisappear {
            hideTask?.cancel()
            errorDismissTask?.cancel()
            subtitleNoticeDismissTask?.cancel()
        }
        // A subtitle file is dropped on the picture far more readily than it is
        // found through an open panel, and the picture is the only part of the
        // window still on screen once the player is up.
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                isDropTargeted = targeted
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
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
        case .increaseSubtitleDelay:
            appModel.changeSubtitleDelay(by: SubtitlePreference.delayStep)
        case .decreaseSubtitleDelay:
            appModel.changeSubtitleDelay(by: -SubtitlePreference.delayStep)
        case .cycleSubtitle:
            appModel.cycleSubtitle()
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
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.75))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                }
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
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

    private var subtitleNoticeIndicator: some View {
        Text(subtitleNoticeText)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.75))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    }
            }
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private var subtitleNoticeText: String {
        switch state.subtitleNotice {
        case .delay(let seconds):
            let milliseconds = Int((seconds * 1000).rounded())
            let value = milliseconds > 0 ? "+\(milliseconds) ms" : "\(milliseconds) ms"
            return "Subtitle Delay: \(value)"
        case .scale(let scale):
            return "Subtitle Size: \(Int((scale * 100).rounded()))%"
        case .track(let name):
            return "Subtitle: \(name)"
        }
    }

    private func showSubtitleNotice() {
        subtitleNoticeDismissTask?.cancel()
        subtitleNoticeVisible = true
        subtitleNoticeDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            subtitleNoticeVisible = false
        }
    }

    private func revealControls() {
        controlsVisible = true
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideTask?.cancel()
        guard !state.isPaused, !isSeeking, openMenuCount == 0 else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !state.isPaused, !isSeeking else { return }
            controlsVisible = false
        }
    }
}

private struct PlayerControlsView: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    @ObservedObject var state: PlayerState
    let showsQueueControls: Bool
    @Binding var isSeeking: Bool
    @Binding var seekValue: Double
    @State private var isVolumePopoverPresented = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularControls
            compactControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.72))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                }
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
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
                .foregroundStyle(Color.white.opacity(0.75))
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
            .foregroundStyle(Color.white.opacity(0.75))
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
            .foregroundStyle(Color.white.opacity(0.75))
            .monospacedDigit()
            .frame(width: 54, alignment: .leading)
    }

    @ViewBuilder
    private var secondaryControls: some View {
        Group {
            speedMenu
            if state.audioTracks.count > 1 {
                audioMenu
            }
            subtitleMenu
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
            Image(systemName: "gauge.with.dots.needle.67percent")
                .frame(width: 22, height: 22)
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

    /// What the subtitle button offers: whether subtitles are showing, which
    /// track, and a way to bring in a file that is not in the folder.
    ///
    /// Nothing else. Everything that is a setting rather than a choice about
    /// the file being watched — the timing, the size, the track after this one
    /// — is in the Subtitles menu in the menu bar. This one opens over the
    /// picture, mid-film, and what is wanted then is which subtitle to read.
    private var subtitleMenu: some View {
        Menu {
            // Radio behaviour with the tracks below it: checking this clears
            // whichever track was checked, because mpv only ever has one
            // subtitle selected and the checkmarks read straight from that.
            trackToggle("Disabled", selected: state.selectedSubtitleID == nil) {
                appModel.selectSubtitle(nil)
            }

            Divider()

            if state.subtitles.isEmpty {
                Text("No subtitles in this file")
            } else {
                ForEach(state.subtitles) { track in
                    trackToggle(
                        track.displayName + (track.isExternal ? " — External" : ""),
                        selected: track.isSelected
                    ) {
                        appModel.selectSubtitle(track)
                    }
                }
            }

            Divider()

            Button("Load Subtitle…") {
                SubtitleFile.choose { url in
                    appModel.loadExternalSubtitle(url)
                }
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
