import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let playerState = PlayerState()

    /// The browser's library, or nil in a window that was opened on a single
    /// file and has no browser of its own.
    let folderLibrary: FolderLibrary?

    let playbackQueue: PlaybackQueue
    let progressStore: PlaybackProgressStore
    let subtitleStore: SubtitleStateStore

    @Published private(set) var engine: MPVPlayerEngine?
    @Published private(set) var videoView: OwlVideoView?
    @Published private(set) var startupError: String?
    @Published private(set) var progressRevision = 0

    private var queueDirectory: URL?
    private var cancellables = Set<AnyCancellable>()

    /// A file asked for before there was anything to draw it with.
    ///
    /// mpv initializes a file's video stream against the render context as the
    /// file is opened, and the context only exists once the video view has
    /// drawn. A window that opens onto a file asks for it while the window is
    /// still being built, which is well before that: the file would play with no
    /// picture, or — having no audio to fall back on — end at once with
    /// `MPV_ERROR_NOTHING_TO_PLAY`. It waits here instead, and goes to mpv on
    /// the first draw.
    private var pendingLoad: (url: URL, startAt: Double?)?

    /// The choice remembered for the file being opened, waiting for mpv to say
    /// what tracks it actually has.
    ///
    /// A track cannot be selected until the track list exists, and the list
    /// arrives after the file is loaded — sometimes in the same breath,
    /// sometimes a moment later when a sidecar finishes being read. Held here
    /// until one of those two moments can act on it, and dropped the instant
    /// another file is asked for, so a choice never lands on the wrong video.
    private var pendingSubtitleSelection: SubtitleSelection?

    /// Held while a video is playing, to keep the display awake. Nil whenever
    /// nothing is playing, which is also how the state is read.
    private var playbackActivity: NSObjectProtocol?

    init(
        folderLibrary: FolderLibrary?,
        playbackQueue: PlaybackQueue = PlaybackQueue(),
        progressStore: PlaybackProgressStore = .shared,
        subtitleStore: SubtitleStateStore = .shared
    ) {
        self.folderLibrary = folderLibrary
        self.playbackQueue = playbackQueue
        self.progressStore = progressStore
        self.subtitleStore = subtitleStore

        folderLibrary?.onVisibleVideosChanged = { [weak self] directory, videos in
            guard let self else { return }
            guard let directory else {
                self.closeVideo()
                return
            }
            guard directory == self.queueDirectory else { return }
            self.playbackQueue.updateVideos(videos)
        }
        observePlayerState()
        retryLibMPV()
    }

    func retryLibMPV() {
        teardownPlayer()
        startupError = nil
        do {
            let engine = try MPVPlayerEngine(state: playerState)
            engine.onPlaybackEnded = { [weak self] generation in
                self?.advanceAfterEnd(generation: generation)
            }
            engine.onFileLoaded = { [weak self] in
                self?.applyStoredSubtitleState()
            }
            engine.setSubtitleScale(SubtitlePreference.scale)
            self.engine = engine
            let videoView = OwlVideoView(engine: engine)
            videoView.onRendererReady = { [weak self] in
                self?.loadPendingVideo()
            }
            self.videoView = videoView
        } catch {
            startupError = error.localizedDescription
            engine = nil
            videoView = nil
        }
    }

    /// Lets go of everything the window owned, for a window that is closing.
    ///
    /// A window whose views simply disappeared would leave mpv decoding — and
    /// playing sound — behind a picture nobody can see, and would go on
    /// answering the media keys from nowhere.
    func shutdown() {
        closeVideo()
        NowPlayingCenter.shared.resign(self)
        teardownPlayer()
        cancellables.removeAll()
    }

    /// Pauses so that another window can be heard. Keeps the file and the
    /// position, so playing this window again carries on from here.
    func yieldPlayback() {
        guard playerState.hasMedia, !playerState.isPaused else { return }
        engine?.setPaused(true)
    }

    /// Releases the renderer before the engine, in that order. mpv holds an
    /// unretained pointer back to the video view for render updates, and
    /// mvp_mpv_destroy tears down the render context, so leaving either
    /// attached past this point leaves the render queue pointing at freed
    /// memory.
    private func teardownPlayer() {
        videoView?.detachRenderer()
        videoView = nil
        engine?.shutdown()
        engine = nil
    }

    func play(_ url: URL, from videos: [URL], directory: URL?) {
        guard engine != nil else { return }
        saveCurrentProgress()
        queueDirectory = directory
        folderLibrary?.selectVideo(url)
        playbackQueue.select(url, from: videos)
        loadVideo(url)
    }

    func playNext() {
        guard let next = playbackQueue.next() else { return }
        saveCurrentProgress()
        folderLibrary?.selectVideo(next)
        loadVideo(next)
    }

    /// Restarts the current file instead of moving back once there's enough
    /// played that "previous" more likely means "again" than "the last one" —
    /// the same threshold most players use before Previous stops chaining.
    private static let previousRestartThreshold: Double = 3

    func playPrevious() {
        if playerState.hasMedia, playerState.currentTime > Self.previousRestartThreshold {
            engine?.seek(to: 0)
            return
        }
        guard let previous = playbackQueue.previous() else { return }
        saveCurrentProgress()
        folderLibrary?.selectVideo(previous)
        loadVideo(previous)
    }

    func togglePlayPause() {
        guard playerState.hasMedia else { return }
        engine?.togglePause()
    }

    func seek(by seconds: Double) {
        guard playerState.hasMedia else { return }
        engine?.seek(by: seconds)
    }

    func changeVolume(by amount: Double) {
        engine?.setVolume(playerState.volume + amount)
    }

    func setSpeed(_ speed: Double) {
        engine?.setSpeed(speed)
    }

    func changeSpeed(by amount: Double) {
        engine?.setSpeed(playerState.speed + amount)
    }

    func changeSubtitleDelay(by seconds: Double) {
        setSubtitleDelay(playerState.subtitleDelay + seconds)
    }

    func resetSubtitleDelay() {
        setSubtitleDelay(0)
    }

    /// Applies immediately to `playerState` rather than waiting on mpv's own
    /// report of the property, so the indicator has the right number the
    /// instant the key or the menu item fires; the eventual mpv event just
    /// confirms the same value.
    private func setSubtitleDelay(_ seconds: Double) {
        playerState.subtitleDelay = seconds
        playerState.announce(.delay(seconds))
        engine?.setSubtitleDelay(seconds)
        guard let url = playerState.currentURL else { return }
        subtitleStore.recordDelay(url: url, delaySeconds: seconds)
    }

    func changeSubtitleScale(by amount: Double) {
        setSubtitleScale(SubtitlePreference.scale + amount)
    }

    func resetSubtitleScale() {
        setSubtitleScale(1)
    }

    /// Unlike the delay, this is not remembered per file: it is applied to
    /// this player now, and to every file any window opens after it.
    private func setSubtitleScale(_ scale: Double) {
        SubtitlePreference.scale = scale
        let applied = SubtitlePreference.scale
        playerState.announce(.scale(applied))
        engine?.setSubtitleScale(applied)
    }

    /// Shows `track`, or turns subtitles off when given nothing, and remembers
    /// the choice for this file.
    ///
    /// `SubtitlePreference` hears about it as well. Choosing by hand is the
    /// clearest statement anyone makes about what they want — whether subtitles
    /// at all, and in which language — and it is the only thing that can help
    /// the next episode, which has no memory of its own to restore.
    func selectSubtitle(_ track: SubtitleTrack?) {
        // A choice made by hand outranks whatever was still waiting to be
        // restored, which would otherwise undo it a moment later.
        pendingSubtitleSelection = nil
        engine?.setSubtitle(id: track?.id)

        let selection = track.map(SubtitleSelection.of) ?? .off
        if let url = playerState.currentURL {
            subtitleStore.recordSelection(url: url, selection: selection)
        }
        SubtitlePreference.isEnabled = track != nil
        if let language = selection.language {
            SubtitlePreference.preferredLanguage = language
        }
        playerState.announce(.track(track?.displayName ?? "Off"))
    }

    /// Steps through the file's subtitle tracks and then off, for the key that
    /// does this without opening a menu.
    func cycleSubtitle() {
        guard playerState.hasMedia else { return }
        guard !playerState.subtitles.isEmpty else {
            // Silence would read as a key that does nothing.
            playerState.announce(.track("None available"))
            return
        }
        selectSubtitle(
            SubtitleSelection.next(
                after: playerState.selectedSubtitle,
                in: playerState.subtitles
            )
        )
    }

    /// Attaches a subtitle file to the video that is playing — from the open
    /// panel, or from one dropped on the picture.
    func loadExternalSubtitle(_ url: URL) {
        guard playerState.hasMedia else { return }

        // Dropping a file mpv already has — a sidecar it found by itself, or
        // the same file twice — selects that track instead of adding a second
        // copy of it to the menu.
        if let loaded = playerState.subtitles.first(where: {
            $0.externalURL == url.standardizedFileURL
        }) {
            selectSubtitle(loaded)
            return
        }

        pendingSubtitleSelection = nil
        engine?.loadSubtitle(url)
        SubtitlePreference.isEnabled = true
        if let current = playerState.currentURL {
            subtitleStore.recordSelection(url: current, selection: .external(url: url))
        }
        playerState.announce(.track(url.lastPathComponent))
    }

    /// Restores how this file was last watched: the delay it needed, and the
    /// track that was chosen for it. Runs on every load — including a file mpv
    /// is replaying — so nothing left over from the previous file in this same
    /// player can bleed into one that never needed it.
    private func applyStoredSubtitleState() {
        guard let url = playerState.currentURL else { return }
        engine?.setSubtitleDelay(subtitleStore.delay(for: url) ?? 0)
        pendingSubtitleSelection = subtitleStore.selection(for: url)
        // mpv reports the track list as part of loading the file, so it may
        // already be here; if it is not, `observePlayerState` is watching for
        // it. Whichever arrives second does the work.
        restoreSubtitleSelection(in: playerState.subtitles)
    }

    private func restoreSubtitleSelection(in tracks: [SubtitleTrack]) {
        guard let selection = pendingSubtitleSelection, !tracks.isEmpty else { return }

        switch SubtitleSelection.action(restoring: selection, in: tracks) {
        case .none:
            // Either it is already showing, or the track is not in this file
            // any more. Neither is worth undoing mpv's own pick over.
            break
        case .turnOff:
            engine?.setSubtitle(id: nil)
        case .select(let id):
            engine?.setSubtitle(id: id)
        case .loadExternal(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                // The sidecar has been moved or deleted since. Asking mpv for
                // it would only raise an error banner over the video, so the
                // choice is forgotten instead.
                if let current = playerState.currentURL {
                    subtitleStore.recordSelection(url: current, selection: nil)
                }
                break
            }
            engine?.loadSubtitle(url)
        }
        pendingSubtitleSelection = nil
    }

    func closeVideo() {
        if playerState.hasMedia {
            saveCurrentProgress()
        }
        queueDirectory = nil
        pendingLoad = nil
        pendingSubtitleSelection = nil
        folderLibrary?.selectedVideo = nil
        playbackQueue.clear()
        engine?.stop()
        videoView?.setVideoRenderingEnabled(false)
        playerState.reset()
        updateNowPlaying()
    }

    func playbackProgress(for url: URL) -> PlaybackProgress? {
        progressStore.progress(for: url)
    }

    func toggleWatched(for url: URL, duration: Double?) {
        let isWatched = progressStore.progress(for: url)?.isCompleted == true
        progressStore.setWatched(!isWatched, url: url, duration: duration)
    }

    /// Whether a file has been asked for that mpv has not been given yet,
    /// because the view it would be drawn in has not drawn once.
    var isWaitingForRenderer: Bool {
        pendingLoad != nil
    }

    /// Reacts to mpv reporting a file's natural end. `generation` is the one
    /// `load()` gave that file: if a manual Previous/Next has already loaded
    /// something else by the time this runs — end-of-file is detected on
    /// mpv's own queue and hops to the main actor to get here, and a click can
    /// land in that gap — advancing from `current` now would advance from the
    /// wrong file and undo what the user just chose. Stale end-of-file events
    /// are dropped instead.
    private func advanceAfterEnd(generation: Int) {
        guard engine?.isMostRecentLoad(generation) == true else { return }
        if let currentURL = playerState.currentURL {
            progressStore.markFinished(url: currentURL, duration: playerState.duration)
        }
        guard let next = playbackQueue.next(automatic: true) else { return }
        saveCurrentProgress()
        folderLibrary?.selectVideo(next)
        loadVideo(next)
    }

    private func loadVideo(_ url: URL) {
        // Opening a file is what makes this window the one being watched, and
        // so the one the media keys and the Now Playing panel belong to.
        NowPlayingCenter.shared.activate(self)
        videoView?.setVideoRenderingEnabled(true)

        let startAt = resumePosition(for: url)
        guard videoView?.isRendererReady == true else {
            pendingLoad = (url, startAt)
            // The file is what the window is showing from this moment, even
            // though mpv has not been given it yet: the title, the row's
            // highlight and the spinner all read this.
            playerState.resetForLoad(url, startAt: startAt)
            updateNowPlaying()
            return
        }

        pendingLoad = nil
        startPlayback(url, startAt: startAt)
        updateNowPlaying()
    }

    /// Hands mpv the file that was waiting for a renderer, once there is one.
    private func loadPendingVideo() {
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        startPlayback(pendingLoad.url, startAt: pendingLoad.startAt)
        updateNowPlaying()
    }

    /// Hands mpv a file along with what the last subtitle choice implies about
    /// this one: whether to show a subtitle at all, which language to lean
    /// towards when mpv has a choice to make, and how large to draw them. A
    /// file watched before overrules the first two once its own tracks arrive.
    private func startPlayback(_ url: URL, startAt: Double?) {
        // Nothing remembered for the file being replaced may reach this one.
        pendingSubtitleSelection = nil
        engine?.setSubtitleScale(SubtitlePreference.scale)
        engine?.load(
            url,
            startAt: startAt,
            selectsSubtitles: SubtitlePreference.isEnabled,
            preferredSubtitleLanguage: SubtitlePreference.preferredLanguage
        )
    }

    /// Where a video should pick up, or nil to start it from the beginning.
    ///
    /// The running time comes from the stored progress rather than from the
    /// player, because the decision is made before the file is open and mpv has
    /// not reported a duration yet. The store records both together, so it
    /// already knows how far in the position was.
    private func resumePosition(for url: URL) -> Double? {
        guard let progress = progressStore.progress(for: url) else { return nil }
        // Far enough in to be worth returning to, and far enough from the end
        // that there is something left to watch.
        guard progress.position >= 15, progress.duration > progress.position + 30 else {
            return nil
        }
        return progress.position
    }

    private func observePlayerState() {
        // The store is shared by every window, so the browser's ticks and bars
        // follow a file watched in a window of its own as closely as one watched
        // here. It is the only thing that writes progress, which makes it the
        // one place worth watching for a change to it.
        progressStore.objectWillChange
            .sink { [weak self] _ in
                self?.progressRevision &+= 1
            }
            .store(in: &cancellables)

        playerState.$currentTime
            .combineLatest(playerState.$duration, playerState.$currentURL)
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _, _, _ in
                self?.saveCurrentProgress()
                self?.updateNowPlaying()
            }
            .store(in: &cancellables)

        // A remembered track can only be applied once mpv says what the file
        // holds, which is its own event, after the file is loaded.
        playerState.$subtitles
            .sink { [weak self] tracks in
                self?.restoreSubtitleSelection(in: tracks)
            }
            .store(in: &cancellables)

        playerState.$isPaused
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &cancellables)
        playerState.$volume
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &cancellables)

        // The published values, not the properties: @Published fires before the
        // new value is stored, so reading playerState here would see the old one.
        playerState.$isPaused
            .combineLatest(playerState.$currentURL)
            .sink { [weak self] isPaused, url in
                self?.setPlaybackKeepingDisplayAwake(url != nil && !isPaused)
            }
            .store(in: &cancellables)
    }

    /// Keeps the display awake while a video is playing, and lets it sleep
    /// again as soon as one is not.
    private func setPlaybackKeepingDisplayAwake(_ isPlaying: Bool) {
        if isPlaying, playbackActivity == nil {
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .idleDisplaySleepDisabled,
                    .idleSystemSleepDisabled,
                    .userInitiated,
                    .latencyCritical
                ],
                reason: "Playing video"
            )
        } else if !isPlaying, let playbackActivity {
            ProcessInfo.processInfo.endActivity(playbackActivity)
            self.playbackActivity = nil
        }
    }

    private func saveCurrentProgress() {
        guard let url = playerState.currentURL,
              playerState.currentTime >= 0
        else { return }
        progressStore.record(
            url: url,
            position: playerState.currentTime,
            duration: playerState.duration
        )
    }

    private func updateNowPlaying() {
        NowPlayingCenter.shared.update(from: self)
    }
}
