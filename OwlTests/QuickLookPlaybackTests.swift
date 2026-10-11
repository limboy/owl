import CMPVShim
import XCTest
@testable import Owl

@MainActor
final class QuickLookPlaybackTests: XCTestCase {
    /// Exercise the exact software-render path used across Finder's remote-view
    /// boundary, with containers that AVFoundation cannot normally preview.
    func testPreviewDecodesSeeksAndReplacesMKVAndWebM() async throws {
        let tool = try XCTUnwrap(ExternalThumbnailRenderer.locateTool())
        guard case .ffmpeg(let ffmpeg) = tool else { throw XCTSkip("Requires ffmpeg") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = PlayerState()
        let engine = try MPVPlayerEngine(state: state, preview: true)
        XCTAssertGreaterThanOrEqual(mvp_mpv_initialize_software_renderer(engine.rawHandle), 0)
        defer {
            mvp_mpv_destroy_renderer(engine.rawHandle)
            engine.shutdown()
        }
        let width = 160, height = 96, stride = 160 * 4
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
        defer { pixels.deallocate() }
        for ext in ["mkv", "webm"] {
            let url = directory.appendingPathComponent("preview.\(ext)")
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i",
                "testsrc2=size=160x96:rate=10", "-t", "3", "-c:v", "libvpx-vp9", "-threads", "1", url.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            engine.load(url, startsPaused: true)
            var frames = 0
            for _ in 0..<150 {
                if mvp_mpv_render_software(engine.rawHandle, pixels, Int32(width), Int32(height), stride, false) > 0 { frames += 1 }
                if !state.isLoading && frames > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(state.errorMessage, ext)
            XCTAssertFalse(state.isLoading, ext)
            XCTAssertTrue(state.isPaused, ext)
            XCTAssertGreaterThan(frames, 0, ext)
            let first = Data(bytes: pixels, count: stride * height)
            XCTAssertTrue(first.contains { $0 > 32 }, "A preview must contain decoded pixels")
            engine.seek(to: 1.5)
            var soughtFrame = false
            for _ in 0..<150 {
                if mvp_mpv_render_software(engine.rawHandle, pixels, Int32(width), Int32(height), stride, false) > 0 {
                    if Data(bytes: pixels, count: stride * height) != first { soughtFrame = true }
                }
                if soughtFrame && state.currentTime >= 1 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(soughtFrame, "Seeking must update a paused preview")
            XCTAssertGreaterThanOrEqual(state.currentTime, 1)
        }
    }
}
