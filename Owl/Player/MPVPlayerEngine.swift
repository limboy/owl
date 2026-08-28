import CMPVShim
import Foundation

private func swiftString<T>(from tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}

private func mpvWakeupCallback(context: UnsafeMutableRawPointer?) {
    MPVCallbackContext<MPVPlayerEngine>.target(of: context)?.scheduleEventDrain()
}

final class MPVPlayerEngine: @unchecked Sendable {
    let info: LibMPVInfo
    let state: PlayerState

    /// Carries the generation `load()` gave the file that just ended, so a
    /// listener can tell a real end from a stale one — see `loadGeneration`.
    var onPlaybackEnded: (@MainActor (Int) -> Void)?
    var onFileLoaded: (@MainActor () -> Void)?

    private let handle: OpaquePointer

    /// Serializes every use of `handle` against the destroy. Reaching mpv from
    /// anywhere else has to hop through here first.
    ///
    /// A lock around the calls instead would deadlock. mpv runs the wakeup
    /// callback while holding its own client lock, so a lock taken there is
    /// taken beneath mpv's; a caller holding that same lock while it waits to
    /// enter mpv closes the cycle. Ordering the work on a serial queue needs no
    /// lock on either side.
    private let eventQueue = DispatchQueue(label: "me.limboy.owl.mpv-events")

    /// Whether the handle has been freed. Read and written on `eventQueue`
    /// only, and kept in a box because `shutdown` runs from deinit, where the
    /// engine itself cannot be captured.
    private final class Lifetime {
        var isDestroyed = false
    }
    private let lifetime = Lifetime()

    /// Guards the once-only part of `shutdown`. Deliberately never held while
    /// calling mpv, and never taken from an mpv callback.
    private let shutdownLock = NSLock()
    private var isShuttingDown = false

    /// Bumped by every `load()`, so the end-of-file mpv reports for one file
    /// can be told apart from a load a manual Previous/Next has since
    /// replaced it with. `load()` runs on the main actor; end-of-file is
    /// detected on `eventQueue`; a lock is simplest for a plain counter two
    /// threads only ever read or increment, never anything that touches mpv.
    private let generationLock = NSLock()
    private var _loadGeneration = 0

    private var loadGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return _loadGeneration
    }

    @discardableResult
    private func bumpLoadGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        _loadGeneration += 1
        return _loadGeneration
    }

    /// Whether `generation` is still the most recent file asked of mpv, i.e.
    /// nothing has loaded since. Lets a caller reacting to a delayed
    /// end-of-file check whether it is still about the file it thinks it is.
    func isMostRecentLoad(_ generation: Int) -> Bool {
        loadGeneration == generation
    }

    /// Owned by libmpv until the player is destroyed. Touched only by `init`
    /// and `shutdown`, which runs at most once.
    private var wakeupContext: UnsafeMutableRawPointer?

    init(state: PlayerState) throws {
        switch LibMPVLoader.createPlayer() {
        case .success(let result):
            handle = result.0
            info = result.1
            self.state = state
        case .failure(let error):
            throw error
        }

        let wakeupContext = MPVCallbackContext<MPVPlayerEngine>.passRetained(self)
        self.wakeupContext = wakeupContext
        mvp_mpv_set_wakeup_callback(handle, mpvWakeupCallback, wakeupContext)
        scheduleEventDrain()
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        let wasShuttingDown = shutdownLock.withLock {
            let previous = isShuttingDown
            isShuttingDown = true
            return previous
        }
        guard !wasShuttingDown else { return }

        // The lock is already released, so this call cannot be part of a cycle
        // with mpv's own. Nothing has destroyed the handle at this point: the
        // only destroy is the one enqueued below, and the guard above lets that
        // happen once.
        mvp_mpv_set_wakeup_callback(handle, nil, nil)

        // Freeing on the event queue puts the destroy behind every drain and
        // command already queued. It has to be asynchronous, because deinit
        // calls this and deinit itself lands on the event queue whenever a
        // drain drops the last reference to the engine. Only values are
        // captured, never self, which deinit could not offer anyway.
        let handle = self.handle
        let lifetime = self.lifetime
        let wakeupContext = self.wakeupContext
        self.wakeupContext = nil
        eventQueue.async {
            guard !lifetime.isDestroyed else { return }
            lifetime.isDestroyed = true
            mvp_mpv_destroy(handle)
            // Clearing the callback does not stop one already running, so the
            // box outlives the engine and reads as nil for it. mpv makes no
            // further calls once the player is destroyed, which is the first
            // moment the box can go.
            MPVCallbackContext<MPVPlayerEngine>.release(wakeupContext)
        }
    }

    /// Called from mpv's wakeup callback, which runs with mpv's client lock
    /// held. Enqueuing is the only thing it may do: taking any lock here would
    /// order that lock beneath mpv's and deadlock against a thread waiting to
    /// enter mpv.
    func scheduleEventDrain() {
        eventQueue.async { [weak self] in
            self?.drainEvents()
        }
    }

    /// Hands `body` the live handle on the event queue, or drops it once the
    /// handle has been freed. Safe to call from the event queue itself, where
    /// it simply defers the work to the next block.
    private func onEventQueue(_ body: @escaping (OpaquePointer) -> Void) {
        let handle = self.handle
        let lifetime = self.lifetime
        eventQueue.async {
            guard !lifetime.isDestroyed else { return }
            body(handle)
        }
    }

    /// How often the playback position reaches `PlayerState`.
    ///
    /// mpv reports `time-pos` once per decoded frame. Publishing at that rate
    /// invalidates every SwiftUI view observing PlayerState 30-60 times a
    /// second, including the whole folder browser, to move a seconds-resolution
    /// label and a bar whose finest pixel is worth half a second on a short
    /// file and twelve on a long one. Four updates a second look identical and
    /// cost an order of magnitude less.
    private static let timePositionInterval: TimeInterval = 0.25

    /// The newest position mpv has reported since the last one published.
    /// Event-queue state, like everything else the drain touches.
    private var pendingTimePosition: Double?
    private var isTimePositionPublishScheduled = false

    /// Publishes on the trailing edge, so a steady stream settles into one
    /// update per interval and the last position of a file still lands rather
    /// than being dropped with the stream.
    private func publishTimePosition(_ seconds: Double) {
        pendingTimePosition = seconds
        guard !isTimePositionPublishScheduled else { return }
        isTimePositionPublishScheduled = true

        eventQueue.asyncAfter(deadline: .now() + Self.timePositionInterval) {
            [weak self] in
            guard let self else { return }
            isTimePositionPublishScheduled = false
            guard let seconds = pendingTimePosition else { return }
            pendingTimePosition = nil
            Task { @MainActor [weak self] in
                self?.state.currentTime = seconds
            }
        }
    }

    /// Drops a position left over from the file being replaced, so it cannot
    /// land on top of the new file's reset clock.
    private func discardPendingTimePosition() {
        eventQueue.async { [weak self] in
            self?.pendingTimePosition = nil
        }
    }

    private func drainEvents() {
        guard !lifetime.isDestroyed else { return }
        while true {
            var event = MVPMPVEvent()
            guard mvp_mpv_poll_event(handle, &event) != 0 else {
                break
            }
            handle(event)
        }
    }

    private func handle(_ event: MVPMPVEvent) {
        switch event.type {
        case MVP_MPV_EVENT_PROPERTY:
            var mutableEvent = event
            let name = swiftString(from: &mutableEvent.name)
            let valueType = event.value_type
            let flag = event.flag_value != 0
            let number = event.double_value

            // time-pos is the one property mpv reports per decoded frame, and
            // it is the only one worth rationing. The rest arrive a handful of
            // times per file and go straight through, so pausing still feels
            // instant.
            if name == "time-pos", valueType == MVP_MPV_VALUE_DOUBLE {
                publishTimePosition(number.isFinite ? max(0, number) : 0)
                return
            }

            // With `keep-open` holding mpv at the last frame instead of
            // unloading the file, `end-file` is not a dependable signal of
            // reaching natural end-of-playback — `eof-reached` flipping is.
            // Reported the same way `end-file` normally would be, generation
            // and all, so a stale flip after a manual Previous/Next is
            // dropped the same way a stale end-of-file report is.
            if name == "eof-reached", valueType == MVP_MPV_VALUE_FLAG, flag {
                let endedGeneration = loadGeneration
                Task { @MainActor [weak self] in
                    self?.onPlaybackEnded?(endedGeneration)
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch name {
                case "pause" where valueType == MVP_MPV_VALUE_FLAG:
                    state.isPaused = flag
                case "duration" where valueType == MVP_MPV_VALUE_DOUBLE:
                    state.duration = number.isFinite ? max(0, number) : 0
                case "volume" where valueType == MVP_MPV_VALUE_DOUBLE:
                    state.volume = min(max(number, 0), 100)
                case "mute" where valueType == MVP_MPV_VALUE_FLAG:
                    state.isMuted = flag
                case "speed" where valueType == MVP_MPV_VALUE_DOUBLE:
                    state.speed = number
                case "sub-delay" where valueType == MVP_MPV_VALUE_DOUBLE:
                    state.subtitleDelay = number
                case "video-out-params/aspect":
                    // Between files, and for one with no picture at all, mpv
                    // reports the property as having no value rather than not
                    // reporting it: a shape of nothing, which is nil here.
                    let isUsable = valueType == MVP_MPV_VALUE_DOUBLE
                        && number.isFinite
                        && number > 0
                    state.videoAspectRatio = isUsable ? number : nil
                default:
                    break
                }
            }

        case MVP_MPV_EVENT_FILE_LOADED:
            refreshTracks()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.isLoading = false
                self.onFileLoaded?()
            }

        case MVP_MPV_EVENT_TRACKS_CHANGED:
            refreshTracks()

        case MVP_MPV_EVENT_END_FILE:
            let reason = event.end_reason
            let errorCode = event.error
            if reason == 0 {
                let endedGeneration = loadGeneration
                Task { @MainActor [weak self] in
                    self?.onPlaybackEnded?(endedGeneration)
                }
            } else if reason == 4 {
                let message = "Playback failed (mpv error \(errorCode))."
                Task { @MainActor [weak self] in
                    self?.state.isLoading = false
                    self?.state.errorMessage = message
                }
            }

        case MVP_MPV_EVENT_COMMAND_ERROR:
            var mutableEvent = event
            let detail = swiftString(from: &mutableEvent.string_value)
            Task { @MainActor [weak self] in
                self?.state.isLoading = false
                self?.state.errorMessage = detail.isEmpty ? "The mpv command failed." : detail
            }

        case MVP_MPV_EVENT_SHUTDOWN:
            Task { @MainActor [weak self] in
                self?.state.errorMessage = "libmpv shut down unexpectedly."
            }

        default:
            break
        }
    }

    private func refreshTracks() {
        let count = mvp_mpv_copy_subtitle_tracks(handle, nil, 0)
        let audioCount = mvp_mpv_copy_audio_tracks(handle, nil, 0)
        guard count >= 0, audioCount >= 0 else { return }

        var subtitleValues = [MVPMPVSubtitleTrack](
            repeating: MVPMPVSubtitleTrack(),
            count: Int(count)
        )
        let copiedSubtitles = subtitleValues.withUnsafeMutableBufferPointer { buffer in
            mvp_mpv_copy_subtitle_tracks(handle, buffer.baseAddress, Int32(buffer.count))
        }
        guard copiedSubtitles >= 0 else { return }

        var audioValues = [MVPMPVAudioTrack](
            repeating: MVPMPVAudioTrack(),
            count: Int(audioCount)
        )
        let copiedAudio = audioValues.withUnsafeMutableBufferPointer { buffer in
            mvp_mpv_copy_audio_tracks(handle, buffer.baseAddress, Int32(buffer.count))
        }
        guard copiedAudio >= 0 else { return }

        let subtitles = subtitleValues.prefix(Int(copiedSubtitles)).map { value -> SubtitleTrack in
            var mutableValue = value
            let title = swiftString(from: &mutableValue.title)
            let language = swiftString(from: &mutableValue.language)
            let codec = swiftString(from: &mutableValue.codec)
            let externalFilename = swiftString(from: &mutableValue.external_filename)
            return SubtitleTrack(
                id: value.id,
                title: title,
                language: language.isEmpty ? nil : language,
                codec: codec.isEmpty ? nil : codec,
                isExternal: value.external,
                isSelected: value.selected,
                externalURL: externalFilename.isEmpty
                    ? nil
                    : URL(fileURLWithPath: externalFilename).standardizedFileURL
            )
        }

        let audioTracks = audioValues.prefix(Int(copiedAudio)).map { value -> AudioTrack in
            var mutableValue = value
            let title = swiftString(from: &mutableValue.title)
            let language = swiftString(from: &mutableValue.language)
            let codec = swiftString(from: &mutableValue.codec)
            return AudioTrack(
                id: value.id,
                title: title,
                language: language.isEmpty ? nil : language,
                codec: codec.isEmpty ? nil : codec,
                isExternal: value.external,
                isSelected: value.selected
            )
        }

        Task { @MainActor [weak self] in
            self?.state.subtitles = subtitles
            self?.state.audioTracks = audioTracks
        }
    }

    @MainActor
    /// Opens `url`, optionally beginning at `startAt` seconds rather than at
    /// the start, and letting mpv pick a subtitle track unless
    /// `selectsSubtitles` says the last answer to that question was no.
    ///
    /// `sid` is set to `auto` or `no` rather than to a specific track: mpv already
    /// knows which subtitle to prefer from the tracks' own default and forced
    /// flags, from `subs-fallback=yes` when no flag settles it, from
    /// `preferredSubtitleLanguage` where one has been learned, and — with
    /// `sub-auto=fuzzy` — from the sidecar files sitting next to the video.
    /// Picking a track here would throw all of that away. A track remembered
    /// for this particular file — including a remembered "off" — is applied
    /// afterwards, once mpv has reported what the file actually contains.
    ///
    /// The position goes through mpv's `start` option instead of a seek issued
    /// once the file is open, so the first frame drawn is already the right one
    /// and there is no window in which the beginning of the file is on screen.
    /// It is set on every load, never cleared, because mpv reads it when a file
    /// begins and would otherwise carry it into the next one.
    ///
    /// `loadfile` could take the same thing as a per-file option, but the
    /// argument it goes in moved when mpv 0.38 inserted an index before it, and
    /// this app loads whichever libmpv Homebrew has installed. `start` has been
    /// spelled the same way throughout.
    /// Returns the generation this load was given, for a caller that wants to
    /// match it against a later `isMostRecentLoad(_:)` check itself rather
    /// than waiting on `onPlaybackEnded`.
    @discardableResult
    func load(
        _ url: URL,
        startAt seconds: Double? = nil,
        selectsSubtitles: Bool = true,
        preferredSubtitleLanguage: String? = nil
    ) -> Int {
        let generation = bumpLoadGeneration()
        state.resetForLoad(url, startAt: seconds)
        discardPendingTimePosition()
        command(["set", "start", seconds.map { String($0) } ?? "none"])
        // Set on every load rather than once, and cleared to the empty list
        // when there is no preference, because mpv reads it as a file opens
        // and would otherwise carry the last one into every file after it.
        command(["set", "slang", preferredSubtitleLanguage ?? ""])
        command(["set", "sid", selectsSubtitles ? "auto" : "no"])
        command(["loadfile", url.path, "replace"])
        setPaused(false)
        return generation
    }

    func stop() {
        command(["stop"])
    }

    func togglePause() {
        command(["cycle", "pause"])
    }

    func setPaused(_ paused: Bool) {
        setFlag(property: "pause", value: paused)
    }

    func seek(to seconds: Double) {
        command(["seek", String(seconds), "absolute+exact"])
    }

    func seek(by seconds: Double) {
        command(["seek", String(seconds), "relative+exact"])
    }

    func setVolume(_ volume: Double) {
        setDouble(property: "volume", value: min(max(volume, 0), 100))
    }

    func setSpeed(_ speed: Double) {
        setDouble(property: "speed", value: min(max(speed, 0.25), 4))
    }

    func toggleMute() {
        command(["cycle", "mute"])
    }

    func setSubtitle(id: Int64?) {
        command(["set", "sid", id.map(String.init) ?? "no"])
    }

    func setSubtitleDelay(_ seconds: Double) {
        setDouble(property: "sub-delay", value: seconds)
    }

    /// Scales subtitles relative to however large mpv would draw them. Applies
    /// to the player rather than to the file, so it survives every load and is
    /// only set when it changes.
    func setSubtitleScale(_ scale: Double) {
        setDouble(property: "sub-scale", value: scale)
    }

    func setAudio(id: Int64?) {
        command(["set", "aid", id.map(String.init) ?? "no"])
    }

    /// Adds a subtitle file to the open video and shows it.
    ///
    /// Only for a file mpv has not already got: `sub-add` on a path that is
    /// already in the track list adds a second copy of it. Selecting the
    /// existing track is `setSubtitle(id:)`, and which of the two a request
    /// needs is `SubtitleSelection.action(restoring:in:)`.
    func loadSubtitle(_ url: URL) {
        command(["sub-add", url.path, "select"])
    }

    private func command(_ arguments: [String]) {
        onEventQueue { [weak self] handle in
            let storage = arguments.map { strdup($0) }
            defer {
                storage.forEach { pointer in
                    if let pointer { free(pointer) }
                }
            }
            var pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
                guard let pointer else { return nil }
                return UnsafePointer<CChar>(pointer)
            }
            pointers.append(nil)
            var error = [CChar](repeating: 0, count: 512)
            let result = pointers.withUnsafeBufferPointer { argumentsPointer in
                error.withUnsafeMutableBufferPointer { errorPointer in
                    mvp_mpv_command_async(
                        handle,
                        argumentsPointer.baseAddress,
                        errorPointer.baseAddress,
                        errorPointer.count
                    )
                }
            }
            if result < 0 {
                self?.publishImmediateError(error)
            }
        }
    }

    private func setFlag(property: String, value: Bool) {
        onEventQueue { [weak self] handle in
            var error = [CChar](repeating: 0, count: 512)
            let result = property.withCString { propertyPointer in
                error.withUnsafeMutableBufferPointer { errorPointer in
                    mvp_mpv_set_flag_async(
                        handle,
                        propertyPointer,
                        value,
                        errorPointer.baseAddress,
                        errorPointer.count
                    )
                }
            }
            if result < 0 {
                self?.publishImmediateError(error)
            }
        }
    }

    private func setDouble(property: String, value: Double) {
        onEventQueue { [weak self] handle in
            var error = [CChar](repeating: 0, count: 512)
            let result = property.withCString { propertyPointer in
                error.withUnsafeMutableBufferPointer { errorPointer in
                    mvp_mpv_set_double_async(
                        handle,
                        propertyPointer,
                        value,
                        errorPointer.baseAddress,
                        errorPointer.count
                    )
                }
            }
            if result < 0 {
                self?.publishImmediateError(error)
            }
        }
    }

    private func publishImmediateError(_ buffer: [CChar]) {
        let message = buffer.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
        Task { @MainActor [weak self] in
            self?.state.errorMessage = message
        }
    }

    var rawHandle: OpaquePointer {
        handle
    }
}
