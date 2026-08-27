import AppKit
import XCTest
@testable import Owl

@MainActor
final class MediaThumbnailProviderTests: XCTestCase {
    func testMatroskaFallsBackToTheExternalRenderer() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv")
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        )
        let image = await provider.image(for: sample, at: 2)

        XCTAssertNotNil(image, "Matroska previews must come from the external renderer.")
    }

    func testMatroskaHasNoPreviewWithoutAnExternalTool() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv")
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: nil)
        )
        let image = await provider.image(for: sample, at: 2)

        XCTAssertNil(image, "AVFoundation is expected to fail on Matroska.")
    }

    func testMP4UsesAVFoundationWithoutAnExternalTool() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: nil)
        )
        let image = await provider.image(for: sample, at: 2)

        XCTAssertNotNil(image)
    }

    func testRepeatedRequestsForTheSameSecondAreCached() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv")
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        )
        let firstImage = await provider.image(for: sample, at: 2.2)
        let secondImage = await provider.image(for: sample, at: 2.4)
        let first = try XCTUnwrap(firstImage)
        let second = try XCTUnwrap(secondImage)

        XCTAssertIdentical(first, second)
    }

    func testACoverSurvivesWithoutTheToolThatRenderedIt() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv", seconds: 12)
        defer { try? FileManager.default.removeItem(at: sample) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlCovers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rendering = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg)),
            coverCache: CoverImageCache(directory: directory)
        )
        let rendered = await rendering.coverImage(for: sample)
        XCTAssertNotNil(rendered)

        // A second provider stands in for a later launch: it shares nothing in
        // memory, and without an external tool it could not render a Matroska
        // cover itself, so a cover here can only have come off disk.
        let relaunched = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: nil),
            coverCache: CoverImageCache(directory: directory)
        )
        let restored = await relaunched.coverImage(for: sample)
        XCTAssertNotNil(restored)
    }

    func testOnlyContainersAVFoundationClaimsAreProbed() {
        XCTAssertTrue(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip.mp4")))
        XCTAssertTrue(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip.MOV")))
        XCTAssertFalse(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip.mkv")))
        XCTAssertFalse(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip.webm")))
        XCTAssertFalse(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip")))
    }

    private func requireFFmpeg() throws -> URL {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        return ffmpeg
    }

    private func makeSample(
        using ffmpeg: URL,
        pathExtension: String,
        seconds: Int = 5
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlThumbnailSample-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
            "-i", "testsrc=size=320x180:rate=10",
            "-t", String(seconds),
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
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
