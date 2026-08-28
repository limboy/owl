import Foundation
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

    /// Publishes what `model` is playing, or does nothing at all if some other
    /// window is the one the system is following.
    func update(from model: AppModel) {
        guard activeModel === model else { return }
        guard let url = model.playerState.currentURL else {
            clear()
            return
        }

        let state = model.playerState
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.currentTitle ?? url.lastPathComponent,
            MPMediaItemPropertyAssetURL: url,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPaused ? 0 : 1
        ]
        if state.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = state.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state.isPaused ? .paused : .playing

        let commandCenter = MPRemoteCommandCenter.shared()
        let hasQueue = model.playbackQueue.videos.count > 1
        commandCenter.nextTrackCommand.isEnabled = hasQueue
        commandCenter.previousTrackCommand.isEnabled = hasQueue
    }

    private func clear() {
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
        center.skipForwardCommand.preferredIntervals = [5]
        center.skipBackwardCommand.preferredIntervals = [5]

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
            Self.perform { $0.seek(by: 5) }
        }
        center.skipBackwardCommand.addTarget { _ in
            Self.perform { $0.seek(by: -5) }
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
