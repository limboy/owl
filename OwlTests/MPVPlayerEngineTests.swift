import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Owl

/// Drives a real libmpv player, because the interesting failures here are
/// between threads and cannot be reproduced against a stub: mpv runs the wakeup
/// callback while holding its own client lock, so anything the app locks on
/// that path sits beneath mpv's lock and can deadlock a caller waiting to enter
/// mpv. Only an actual player exercises that ordering.
@MainActor
final class MPVPlayerEngineTests: XCTestCase {
    func testFirstPlayerPresentationKeepsTheMainRunLoopResponsive() async throws {
        let sample = try makeSample(frameRate: 24, duration: 10, includesAudio: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwlPresentation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = FolderLibrary(storageURL: directory.appendingPathComponent("library.json"), startWatching: false)
        let model = AppModel(
            folderLibrary: library,
            progressStore: PlaybackProgressStore(storageURL: directory.appendingPathComponent("progress.json"))
        )
        let view = try XCTUnwrap(model.videoView)
        let player = LibraryPlayerWindow(appModel: model)
        defer {
            model.shutdown()
            model.progressStore.waitForPendingWrites()
            try? FileManager.default.removeItem(at: sample)
            try? FileManager.default.removeItem(at: directory)
        }
        for presentation in 1...2 {
            let clock = ContinuousClock()
            let start = clock.now
            var previous = start
            var longestGap: Duration = .zero
            let framesBefore = view.renderedFrameCount
            player.play(sample, from: [sample], directory: sample.deletingLastPathComponent())
            while clock.now - start < .seconds(2) {
                try await Task.sleep(for: .milliseconds(16))
                let now = clock.now
                longestGap = max(longestGap, now - previous)
                previous = now
            }
            print("Player presentation \(presentation): longest main-run-loop gap \(longestGap)")
            XCTAssertLessThan(longestGap, .milliseconds(150))
            try await waitUntil { view.renderedFrameCount > framesBefore }
            XCTAssertGreaterThan(view.renderedFrameCount, framesBefore)
            XCTAssertNotNil(view.window, "the video should play in a window of its own")
            XCTAssertFalse(model.playerState.isPaused, "the window should let the video play once shown")
            XCTAssertNil(model.playerState.errorMessage)

            // Stopping the video from the browser's side takes its window away.
            model.closeVideo()
            try await waitUntil { view.window == nil }
            XCTAssertNil(view.window)
        }

        // A second video picked while the window is up plays in that window.
        player.play(sample, from: [sample], directory: sample.deletingLastPathComponent())
        try await waitUntil { view.window != nil }
        let window = try XCTUnwrap(view.window)
        player.play(sample, from: [sample], directory: sample.deletingLastPathComponent())
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(view.window === window)

        // Closing the window stops the video, and leaves the player for the next.
        window.performClose(nil)
        try await waitUntil { view.window == nil }
        XCTAssertFalse(model.playerState.hasMedia)
        XCTAssertNotNil(model.engine)
    }

    func testVideoKeepsRenderingWhileTheMainThreadIsBusy() async throws {
        try await withVideoSurface { _, view, _ in
            let before = view.renderedFrameCount
            // Deliberately block AppKit, as a folder scan or system service can.
            // A 10 fps video must still present several frames in this interval.
            usleep(700_000)
            let rendered = view.renderedFrameCount - before
            print("Frames rendered during 700 ms main-thread stall: \(rendered)")
            XCTAssertGreaterThanOrEqual(rendered, 4)
        }
    }

    func testVideoWithAudioKeepsRenderingWhileTheMainThreadIsBusy() async throws {
        try await withVideoSurface(frameRate: 24, includesAudio: true) { _, view, _ in
            let before = view.renderedFrameCount
            usleep(700_000)
            let rendered = view.renderedFrameCount - before
            print("24 fps with audio: \(rendered) frames during 700 ms main-thread stall")
            XCTAssertGreaterThanOrEqual(rendered, 12)
        }
    }

    func testRenderingSurvivesPauseResizeSeekAndReattachingTheSurface() async throws {
        try await withVideoSurface { engine, view, window in
            engine.setPaused(true)
            try await waitUntil { engine.state.isPaused }
            try await Task.sleep(for: .milliseconds(300))
            let paused = view.renderedFrameCount
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(view.renderedFrameCount, paused, "paused playback should not spin")

            window.setContentSize(NSSize(width: 480, height: 270))
            view.needsDisplay = true
            try await waitUntil { view.renderedFrameCount > paused }
            XCTAssertGreaterThan(view.renderedFrameCount, paused, "resize must redraw a paused frame")

            let beforeSeek = view.renderedFrameCount
            engine.seek(to: 3)
            try await waitUntil { view.renderedFrameCount > beforeSeek }
            XCTAssertGreaterThan(view.renderedFrameCount, beforeSeek, "paused seek must draw its new frame")

            view.setVideoRenderingEnabled(false)
            try await Task.sleep(for: .milliseconds(200))
            let disabled = view.renderedFrameCount
            view.needsDisplay = true
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(view.renderedFrameCount, disabled)

            view.removeFromSuperview()
            window.contentView = view
            view.setVideoRenderingEnabled(true)
            engine.setPaused(false)
            try await waitUntil { view.renderedFrameCount >= disabled + 4 }
            XCTAssertGreaterThanOrEqual(view.renderedFrameCount, disabled + 4)
            XCTAssertNil(engine.state.errorMessage)
        }
    }

    /// Live Text reads the picture back out of the renderer, and lays its
    /// findings over the view on the strength of the picture being the right
    /// way up and the view's own size.
    func testASnapshotIsThePictureTheRightWayUpAtTheViewsSize() async throws {
        let halves = "color=c=red:s=320x90:r=10[top];color=c=blue:s=320x90:r=10[bottom];[top][bottom]vstack"
        try await withVideoSurface(picture: halves) { engine, view, _ in
            engine.setPaused(true)
            try await waitUntil { engine.state.isPaused }
            try await Task.sleep(for: .milliseconds(200))

            let snapshot = await view.snapshot()
            let image = try XCTUnwrap(snapshot)
            let scale = view.window?.backingScaleFactor ?? 1
            XCTAssertEqual(image.width, Int(view.bounds.width * scale))
            XCTAssertEqual(image.height, Int(view.bounds.height * scale))

            let bitmap = NSBitmapImageRep(cgImage: image)
            let top = try XCTUnwrap(bitmap.colorAt(x: image.width / 2, y: image.height / 4))
            let bottom = try XCTUnwrap(bitmap.colorAt(x: image.width / 2, y: image.height * 3 / 4))
            XCTAssertGreaterThan(top.redComponent, top.blueComponent, "the top half should be red")
            XCTAssertGreaterThan(bottom.blueComponent, bottom.redComponent, "the bottom half should be blue")

            // Taking the picture must not leave the view without one.
            let drawn = view.renderedFrameCount
            view.needsDisplay = true
            try await waitUntil { view.renderedFrameCount > drawn }
            XCTAssertGreaterThan(view.renderedFrameCount, drawn)
        }
    }

    func testAnimatedResizeRestoresPlaybackSynchronizationAfterNestedResize() async throws {
        try await withVideoSurface { engine, view, window in
            let context = try XCTUnwrap(view.openGLContext)
            func swapInterval() -> GLint {
                context.lock()
                defer { context.unlock() }
                var interval: GLint = -1
                context.getValues(&interval, for: .swapInterval)
                return interval
            }
            XCTAssertEqual(swapInterval(), 1)
            view.beginAnimatedResize()
            view.beginAnimatedResize()
            defer {
                view.endAnimatedResize()
                view.endAnimatedResize()
            }
            XCTAssertEqual(swapInterval(), 0)
            engine.setPaused(true)
            try await waitUntil { engine.state.isPaused }
            let beforeResize = view.renderedFrameCount
            window.setContentSize(NSSize(width: 640, height: 360))
            try await waitUntil { view.renderedFrameCount > beforeResize }
            XCTAssertGreaterThan(view.renderedFrameCount, beforeResize)
            XCTAssertEqual(swapInterval(), 0, "a resize redraw must preserve the animation's interval")
            view.endAnimatedResize()
            XCTAssertEqual(swapInterval(), 0)
            view.endAnimatedResize()
            XCTAssertEqual(swapInterval(), 1)
            engine.setPaused(false)
            let beforeResume = view.renderedFrameCount
            try await waitUntil { view.renderedFrameCount >= beforeResume + 4 }
            XCTAssertGreaterThanOrEqual(view.renderedFrameCount, beforeResume + 4)
        }
    }

    func testSixtyFPSPlaybackKeepsRenderingThroughRepeatedMainThreadStalls() async throws {
        try await withVideoSurface(frameRate: 60, duration: 70) { engine, view, _ in
            // Exercise sustained playback, including callback coalescing after
            // UI stalls. Leave the run loop free between each disturbance.
            for round in 1...12 {
                try await Task.sleep(for: .seconds(4.5))
                let before = view.renderedFrameCount
                usleep(500_000)
                let rendered = view.renderedFrameCount - before
                print("60 fps, stall \(round): \(rendered) frames in 500 ms")
                XCTAssertGreaterThanOrEqual(rendered, 20, "rendering stalled in round \(round)")
            }
            XCTAssertNil(engine.state.errorMessage)
        }
    }

    private func withVideoSurface(
        frameRate: Int = 10,
        duration: Int = 10,
        includesAudio: Bool = false,
        picture: String? = nil,
        _ body: (MPVPlayerEngine, OwlVideoView, NSWindow) async throws -> Void
    ) async throws {
        let engine = try makeEngine()
        let sample = try makeSample(
            frameRate: frameRate,
            duration: duration,
            includesAudio: includesAudio,
            picture: picture
        )
        let view = OwlVideoView(engine: engine)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        view.setVideoRenderingEnabled(true)
        defer {
            view.detachRenderer()
            engine.shutdown()
            window.close()
            try? FileManager.default.removeItem(at: sample)
        }

        view.display()
        try await waitUntil { view.isRendererReady }
        XCTAssertTrue(view.isRendererReady)
        engine.load(sample)
        try await waitUntil { view.renderedFrameCount >= 5 && engine.state.currentTime > 0 }
        XCTAssertNil(engine.state.errorMessage)
        XCTAssertGreaterThanOrEqual(view.renderedFrameCount, 5)
        try await body(engine, view, window)
    }

    func testLoadingAFileDeliversEventsThroughTheWakeupCallback() async throws {
        let engine = try makeEngine()
        let sample = try makeSample()
        defer { try? FileManager.default.removeItem(at: sample) }

        engine.load(sample)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, engine.state.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }

        // load() issues a command and then sets a property, both of which reach
        // mpv from the main thread while mpv is calling back with events for
        // the same file. Holding a lock across either call deadlocks against
        // the wakeup callback, and the whole test hangs here instead of failing.
        XCTAssertFalse(engine.state.isLoading, "no event ever came back from mpv")

        // vo=libmpv has no output without a render context, which a headless
        // test cannot build, so mpv answers this load with VO_INIT_FAILED. That
        // it is reported at all is the point: the message travels an END_FILE
        // event through the wakeup callback, the drain, and the main actor.
        XCTAssertEqual(engine.state.errorMessage, "Playback failed (mpv error -16).")

        engine.shutdown()
        try await Task.sleep(for: .milliseconds(500))
    }

    func testShutdownIsSafeToRepeatWhileDrainsAreQueued() async throws {
        let engine = try makeEngine()
        for _ in 0..<50 {
            engine.scheduleEventDrain()
        }

        // The destroy runs once, behind every drain already queued. A second
        // and third call must not free the player again.
        engine.shutdown()
        engine.shutdown()
        engine.shutdown()
        try await Task.sleep(for: .milliseconds(500))
    }

    func testCommandsIssuedAfterShutdownAreDropped() async throws {
        let engine = try makeEngine()
        engine.shutdown()

        // Every one of these would reach a freed handle if the queue did not
        // drop work behind the destroy.
        engine.seek(to: 30)
        engine.setPaused(true)
        engine.setVolume(50)
        engine.setSubtitle(id: 1)
        engine.stop()
        try await Task.sleep(for: .milliseconds(500))
    }

    func testThePlaybackPositionIsPublishedAtAFixedRateRatherThanPerFrame() async throws {
        let engine = try makeEngine()
        // Audio only, because a headless test has no render context and mpv
        // would fail a video file on VO init before ever reporting a position.
        let sample = try makeSample(audioOnly: true)
        defer { try? FileManager.default.removeItem(at: sample) }

        var updates = 0
        let subscription = engine.state.$currentTime.sink { _ in updates += 1 }
        defer { subscription.cancel() }

        engine.load(sample)
        try await Task.sleep(for: .seconds(3))

        // Playing at all is half the assertion: a throttle that published
        // nothing would also satisfy the count.
        XCTAssertGreaterThan(engine.state.currentTime, 1, "the file did not play")

        // Three seconds at four a second, plus the reset and the subscription's
        // own first value. Unthrottled this file measures around seventeen a
        // second, and a video file reports one per decoded frame.
        XCTAssertLessThan(updates, 20, "the position is not being rationed")

        engine.shutdown()
        try await Task.sleep(for: .milliseconds(500))
    }

    func testLoadingWithAStartPositionBeginsThereRatherThanSeekingAfterwards() async throws {
        let engine = try makeEngine()
        let sample = try makeSample(audioOnly: true)
        defer { try? FileManager.default.removeItem(at: sample) }

        var positions: [Double] = []
        let subscription = engine.state.$currentTime
            .sink { if $0 > 0 { positions.append($0) } }
        defer { subscription.cancel() }

        engine.load(sample, startAt: 6)
        try await waitUntil { engine.state.currentTime > 0 }

        XCTAssertGreaterThan(engine.state.currentTime, 5)
        // The file is never at its beginning: mpv starts it at the offset
        // instead of playing from zero and being seeked once it is open.
        XCTAssertEqual(positions.first ?? 0, 6, accuracy: 1)
    }

    func testAStartPositionDoesNotCarryIntoTheNextFile() async throws {
        let engine = try makeEngine()
        let sample = try makeSample(audioOnly: true)
        defer { try? FileManager.default.removeItem(at: sample) }

        engine.load(sample, startAt: 6)
        try await waitUntil { engine.state.currentTime > 0 }
        XCTAssertGreaterThan(engine.state.currentTime, 5, "the first load ignored its offset")

        // mpv reads `start` whenever a file begins, so a load without an offset
        // has to say so rather than leaving the previous one in place. Loading
        // resets the clock, so the next position to arrive is the new file's.
        engine.load(sample)
        try await waitUntil { engine.state.currentTime > 0 }

        XCTAssertLessThan(engine.state.currentTime, 3, "the offset leaked into the next file")
    }

    /// Guards against the race behind Previous/Next intermittently doing
    /// nothing: mpv reports a file's natural end on its own thread, and the
    /// report reaches `onPlaybackEnded` only after a hop to the main actor. A
    /// manual Previous/Next can land in that gap and load a different file
    /// before the stale end-of-file report is handled. This checks the
    /// mechanism `AppModel.advanceAfterEnd` leans on to drop such a report
    /// instead of acting on it and undoing the user's navigation — without
    /// depending on an actual end-of-file event, which needs real playback to
    /// run to completion and is unreliable under a headless test's audio
    /// output.
    func testALoadsGenerationStopsBeingMostRecentOnceAnotherLoadRuns() throws {
        let engine = try makeEngine()
        let first = try makeSample(audioOnly: true)
        let second = try makeSample(audioOnly: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let firstGeneration = engine.load(first)
        XCTAssertTrue(
            engine.isMostRecentLoad(firstGeneration),
            "nothing else has loaded yet, so this load is still the most recent"
        )

        // Stands in for a manual Previous/Next racing a stale end-of-file
        // report for `first`.
        let secondGeneration = engine.load(second)

        XCTAssertFalse(
            engine.isMostRecentLoad(firstGeneration),
            "a load that happened after should invalidate the first load's generation"
        )
        XCTAssertTrue(engine.isMostRecentLoad(secondGeneration))

        engine.shutdown()
    }

    /// The track list is where a remembered sidecar is matched back up with
    /// the file it came from, and the path it is matched on crosses from mpv
    /// through the C shim. Nothing but a real player reports it.
    func testAnExternalSubtitleIsReportedWithThePathItCameFrom() async throws {
        let engine = try makeEngine()
        let sample = try makeSample(audioOnly: true)
        let subtitle = try makeSubtitle()
        defer {
            try? FileManager.default.removeItem(at: sample)
            try? FileManager.default.removeItem(at: subtitle)
        }

        engine.load(sample)
        try await waitUntil { engine.state.currentTime > 0 }
        // Loading clears `slang` when no language has been learned, and the
        // scale is set on every load. Either being rejected by mpv would raise
        // a banner over the video rather than failing quietly.
        XCTAssertNil(engine.state.errorMessage)

        engine.setSubtitleScale(1.2)
        engine.setSubtitleDelay(0.5)
        engine.loadSubtitle(subtitle)
        try await waitUntil { !engine.state.subtitles.isEmpty }

        let track = try XCTUnwrap(engine.state.subtitles.first)
        XCTAssertTrue(track.isExternal)
        XCTAssertEqual(track.externalURL, subtitle.standardizedFileURL)
        XCTAssertEqual(track.displayName, subtitle.lastPathComponent)
        XCTAssertNil(engine.state.errorMessage)

        engine.shutdown()
        try await Task.sleep(for: .milliseconds(500))
    }

    /// A subtitle named for another release of the same episode is one mpv
    /// passes over, and the player adds it — and, with nothing else showing,
    /// shows it.
    func testASubtitleForAnotherReleaseOfTheEpisodeIsAddedAndShown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlDiscovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let video = directory.appendingPathComponent("Show.S01E01 - Pilot (1080p x265 LION).mp4")
        let subtitle = directory.appendingPathComponent("Show.S01E01.Pilot.1080p.BluRay-NOGRP.chs&eng.srt")
        try FileManager.default.moveItem(at: try makeSample(), to: video)
        try FileManager.default.moveItem(at: try makeSubtitle(), to: subtitle)
        let progressStore = PlaybackProgressStore(storageURL: directory.appendingPathComponent("progress.json"))
        let subtitleStore = SubtitleStateStore(storageURL: directory.appendingPathComponent("subtitles.json"))
        let model = AppModel(folderLibrary: nil, progressStore: progressStore, subtitleStore: subtitleStore)
        let wasEnabled = SubtitlePreference.isEnabled
        SubtitlePreference.isEnabled = true
        defer {
            model.shutdown()
            SubtitlePreference.isEnabled = wasEnabled
            progressStore.waitForPendingWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        guard model.engine != nil else { throw XCTSkip("libmpv is not available in this environment.") }

        LibraryPlayerWindow(appModel: model).play(video, from: [video], directory: directory)
        try await waitUntil { !model.playerState.subtitles.isEmpty }

        let track = try XCTUnwrap(model.playerState.subtitles.first)
        XCTAssertEqual(track.externalURL, subtitle.standardizedFileURL)
        XCTAssertTrue(track.isSelected)
        XCTAssertEqual(model.playerState.subtitles.count, 1)
    }

    /// Chapters cross from mpv through the C shim as a node list, which only
    /// a real player reports.
    func testAFilesChaptersAreReportedInOrderWithTheirTitles() async throws {
        let engine = try makeEngine()
        // Sound only: with no surface to draw on, a picture is something mpv
        // has nothing to play.
        let sample = try makeSample(audioOnly: true, chapters: [(0, "Opening"), (4, "Middle"), (7, nil)])
        defer { try? FileManager.default.removeItem(at: sample) }

        engine.load(sample)
        try await waitUntil { engine.state.chapters.count == 3 }

        let chapters = engine.state.chapters
        XCTAssertEqual(chapters.map(\.displayName), ["Opening", "Middle", "Chapter 3"])
        XCTAssertEqual(chapters.map(\.start), [0, 4, 7])
        XCTAssertEqual(chapters.map(\.index), [0, 1, 2])

        engine.shutdown()
        try await Task.sleep(for: .milliseconds(500))
    }

    private func makeSubtitle() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlEngineSample-\(UUID().uuidString).srt")
        let contents = """
        1
        00:00:00,000 --> 00:00:05,000
        Hello

        """
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Polls rather than sleeping a fixed span: opening a file and getting the
    /// first position back takes a second or so, and the position itself only
    /// lands four times a second.
    private func waitUntil(
        _ condition: () -> Bool,
        upTo seconds: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeEngine() throws -> MPVPlayerEngine {
        do {
            return try MPVPlayerEngine(state: PlayerState())
        } catch {
            throw XCTSkip("libmpv is not available in this environment: \(error)")
        }
    }

    private func makeSample(
        audioOnly: Bool = false,
        frameRate: Int = 10,
        duration: Int = 10,
        includesAudio: Bool = false,
        picture: String? = nil,
        chapters: [(start: Int, title: String?)] = []
    ) throws -> URL {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlEngineSample-\(UUID().uuidString)")
            .appendingPathExtension(audioOnly ? "m4a" : "mp4")
        let source = audioOnly
            ? ["-i", "sine=frequency=440"]
            : ["-i", picture ?? "testsrc=size=320x180:rate=\(frameRate)"]
        let audioInput = includesAudio && !audioOnly
            ? ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
            : []
        // Chapters go in through an ffmetadata file, the one way ffmpeg takes
        // them from the command line. Not alongside a second sound input, so
        // the metadata input's number never has to be worked out.
        var chapterInput: [String] = []
        if !chapters.isEmpty, !includesAudio {
            var metadata = ";FFMETADATA1\n"
            for (offset, chapter) in chapters.enumerated() {
                let end = offset + 1 < chapters.count ? chapters[offset + 1].start : duration
                metadata += "[CHAPTER]\nTIMEBASE=1/1\nSTART=\(chapter.start)\nEND=\(end)\n"
                if let title = chapter.title {
                    metadata += "title=\(title)\n"
                }
            }
            let metadataURL = url.appendingPathExtension("ffmetadata")
            try Data(metadata.utf8).write(to: metadataURL)
            chapterInput = ["-f", "ffmetadata", "-i", metadataURL.path, "-map", "0", "-map_chapters", "1"]
        }
        let codec = audioOnly
            ? ["-c:a", "aac"]
            : ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
        ] + source + audioInput + chapterInput + [
            "-t", String(duration),
        ] + codec + (includesAudio && !audioOnly ? ["-c:a", "aac"] : []) + [
            url.path,
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg could not encode the test fixture.")
        }
        return url
    }
}
