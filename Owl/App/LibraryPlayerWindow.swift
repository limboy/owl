import AppKit
import Combine

/// The one window the folder window plays its videos in.
///
/// A video picked in the browser opens here rather than over the browser, as
/// the TV app opens one, and the browser stays up to go on looking through.
/// There is only ever one of these windows: picking another video while it is
/// up plays that video in it, in place of the last one.
///
/// The player is the folder window's, not the window's. It is made once with
/// the browser and lives as long as it does, so the queue, the playing row's
/// highlight and the progress all carry on as they did with the picture in the
/// browser. The window only borrows it: closing the window stops the video, and
/// the next video picked opens a new window onto the same player.
@MainActor
final class LibraryPlayerWindow {
    private let appModel: AppModel
    private var controller: PlayerWindowController?
    private var cancellables = Set<AnyCancellable>()

    init(appModel: AppModel) {
        self.appModel = appModel
        observeCurrentVideo()
    }

    /// Plays `url` with `videos` as its queue, opening the window if it is not
    /// up and raising it if it is.
    func play(_ url: URL, from videos: [URL], directory: URL?) {
        guard appModel.engine != nil else { return }
        // Opened before the file is asked for: the window holds the player
        // paused until it is on screen, and it has to be holding it by then.
        let controller = controller ?? open()
        appModel.play(url, from: videos, directory: directory)
        controller.show()
    }

    private func open() -> PlayerWindowController {
        let controller = PlayerWindowController(
            appModel: appModel,
            ownership: .borrowed,
            frameAutosaveName: "LibraryPlayerWindowFrame",
            rootView: LibraryPlayerView(appModel: appModel)
        ) { [weak self] in
            self?.controller = nil
        }
        _ = controller.place(after: nil)
        self.controller = controller
        return controller
    }

    /// Names the window after the video playing in it, and closes it when
    /// nothing is: the folder that was playing removed from the library, or
    /// the browser otherwise stopping the video under it.
    private func observeCurrentVideo() {
        appModel.playerState.$currentURL
            .removeDuplicates()
            // Delivered after the value is stored, and outside whatever was
            // changing it: closing the window stops the video again.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let controller else { return }
                // Read again rather than taken from the event: a video picked
                // just after the window closed has opened a new window by now,
                // and the nil left over from closing the old one is not about it.
                if let url = appModel.playerState.currentURL {
                    controller.setTitle(for: url)
                } else {
                    controller.close()
                }
            }
            .store(in: &cancellables)
    }
}
