import AppKit
import MediaPlayer

/// The one place the media keys and the system's Now Playing panel are wired to,
/// however many player windows are open.
///
/// `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` belong to the process,
/// not to a window. Each window's model registering its own handlers would send
/// a single press of the play key to all of them at once, and each window's
/// clock would overwrite the panel several times a second. Windows report here
/// instead, and only the one that started playing most recently is listened to.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    /// Weak because a window that has gone away must not be kept alive by the
    /// system controls, and because the last player is nobody's to own.
    private weak var activeModel: AppModel?

    private init() {
        configureRemoteCommands()
    }

    /// Hands the system controls to `model`, and quiets whichever window held
    /// them before.
    ///
    /// Called when a window loads a file, which is the moment it becomes the one
    /// being watched. Two windows playing at once is never what was asked for:
    /// the second soundtrack lands on top of the first, and neither is
    /// listenable. The window that steps aside keeps its file and its position,
    /// so it carries on from there when it is played again.
    func activate(_ model: AppModel) {
        guard activeModel !== model else { return }
        activeModel?.yieldPlayback()
        activeModel = model
        update(from: model)
    }

    /// Gives up the system controls if `model` holds them, which leaves the
    /// panel empty until some window plays something.
    func resign(_ model: AppModel) {
        guard activeModel === model else { return }
        activeModel = nil
        clear()
    }

    /// What was last handed to the system, so that a position mpv reports can
    /// be checked against where the panel believes playback has got to.
    private var published: (url: URL, elapsed: Double, rate: Double, at: Date, chapter: Int?)?

    /// The artwork for the file being played, once it has been found, and the
    /// file it is being looked for on behalf of.
    private var artwork: (url: URL, artwork: MPMediaItemArtwork)?
    private var artworkRequestURL: URL?
    private var artworkTask: Task<Void, Never>?

    /// How far the panel's own clock may run from the player's before it is
    /// corrected. The panel moves its slider on by itself from the elapsed time
    /// and the rate it was last given, so a position only needs sending again
    /// when something other than playing has moved it: a seek, a stall, a
    /// resume.
    private static let positionTolerance: Double = 1.5

    /// Publishes what `model` is playing, or does nothing at all if some other
    /// window is the one the system is following.
    func update(from model: AppModel) {
        guard activeModel === model else { return }
        guard let url = model.playerState.currentURL else {
            clear()
            return
        }

        let state = model.playerState
        // The rate is what the panel advances its slider by between updates.
        // A paused player has to say 0, or the slider runs on without it; a
        // player at 2x has to say 2, or the slider falls behind and jumps back
        // into place every time it is corrected.
        let rate = state.isPaused ? 0 : state.speed
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.currentTitle ?? url.lastPathComponent,
            MPMediaItemPropertyAssetURL: url,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if state.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = state.duration
        }
        let queue = model.playbackQueue.videos
        if queue.count > 1, let index = queue.firstIndex(of: url) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        if let chapter = state.currentChapter {
            info[MPNowPlayingInfoPropertyChapterCount] = state.chapters.count
            info[MPNowPlayingInfoPropertyChapterNumber] = chapter.index
        }
        if let artwork, artwork.url == url {
            info[MPMediaItemPropertyArtwork] = artwork.artwork
        } else {
            loadArtwork(for: url, from: model)
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // A file that opens paused is not taken as something playing at all:
        // the panel goes back to whatever app played last, and the media keys
        // with it. Saying it is playing for a moment first, as IINA does, is
        // what keeps the panel on this one.
        if state.isPaused, published?.url != url {
            center.playbackState = .playing
        }
        center.playbackState = state.isPaused ? .paused : .playing
        published = (url, state.currentTime, rate, Date(), state.currentChapter?.index)

        let commandCenter = MPRemoteCommandCenter.shared()
        let hasQueue = queue.count > 1
        commandCenter.nextTrackCommand.isEnabled = hasQueue
        commandCenter.previousTrackCommand.isEnabled = hasQueue
    }

    /// Tells the panel about a position that is not where its own clock says
    /// playback should be, and says nothing about one that is.
    ///
    /// Called on every position mpv reports. Ordinary playback stays inside
    /// the tolerance and costs a subtraction; a seek, from the keys or the
    /// timeline or the panel itself, lands outside it and is published at once
    /// rather than whenever the next periodic update comes round. So is moving
    /// into another chapter.
    func positionChanged(from model: AppModel) {
        guard activeModel === model, let published else { return }
        let state = model.playerState
        guard state.currentURL == published.url else { return }
        let expected = published.elapsed + Date().timeIntervalSince(published.at) * published.rate
        let hasJumped = abs(state.currentTime - expected) > Self.positionTolerance
        // The panel names the chapter, and cannot work out for itself when
        // playing has carried on into the next one.
        let hasChangedChapter = state.currentChapter?.index != published.chapter
        guard hasJumped || hasChangedChapter else { return }
        update(from: model)
    }

    /// Finds a picture for the panel: the catalogue's artwork where the folder
    /// has been matched against it, which is what the browser shows for the
    /// file too, and otherwise the same frame the browser uses as its cover.
    ///
    /// Asked once per file. The panel goes without until it arrives, rather
    /// than keeping the last file's picture beside this one's name.
    private func loadArtwork(for url: URL, from model: AppModel) {
        guard artworkRequestURL != url else { return }
        artworkRequestURL = url
        artworkTask?.cancel()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let artworkPath = model.folderLibrary?.onlineMetadata(for: url)?.artworkPath
        artworkTask = Task { [weak self, weak model] in
            var image: NSImage?
            if let artworkPath {
                image = await OnlineArtworkProvider.shared.image(forArtworkPath: artworkPath)
            }
            if image == nil {
                image = await MediaThumbnailProvider.shared.coverImage(for: url)
            }
            guard !Task.isCancelled, let self, let image else { return }
            self.artwork = (url, Self.makeArtwork(image))
            if let model {
                self.update(from: model)
            }
        }
    }

    /// Wraps an image for the panel.
    ///
    /// Nonisolated on purpose. MediaPlayer asks the artwork for its picture on
    /// a queue of its own, and a handler written inside this main-actor class
    /// would inherit the main actor and trap the moment it was called anywhere
    /// else. The image is only ever read once it has been handed over.
    nonisolated static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        nonisolated(unsafe) let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func clear() {
        published = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestURL = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]

        center.togglePlayPauseCommand.addTarget { _ in
            Self.perform { $0.togglePlayPause() }
        }
        center.playCommand.addTarget { _ in
            Self.perform { $0.engine?.setPaused(false) }
        }
        center.pauseCommand.addTarget { _ in
            Self.perform { $0.engine?.setPaused(true) }
        }
        center.nextTrackCommand.addTarget { _ in
            Self.perform { $0.playNext() }
        }
        center.previousTrackCommand.addTarget { _ in
            Self.perform { $0.playPrevious() }
        }
        center.skipForwardCommand.addTarget { _ in
            Self.perform { $0.seek(by: 10) }
        }
        center.skipBackwardCommand.addTarget { _ in
            Self.perform { $0.seek(by: -10) }
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            return Self.perform { $0.engine?.seek(to: position) }
        }
    }

    /// Runs `action` against whichever window the system is following.
    ///
    /// The handlers are registered once and live for as long as the process
    /// does, so the window is looked up here, when the key is pressed, rather
    /// than captured when the handler is installed: a target bound to one model
    /// would go on controlling a window nobody is watching any more.
    ///
    /// The lookup itself has to wait for the main actor — the media keys arrive
    /// on a queue of their own — so the status is reported before it is known
    /// whether there was anything to control. Saying otherwise would take the
    /// keys away from the app entirely.
    private nonisolated static func perform(
        _ action: @escaping @MainActor (AppModel) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in
            guard let model = shared.activeModel else { return }
            action(model)
        }
        return .success
    }
}
