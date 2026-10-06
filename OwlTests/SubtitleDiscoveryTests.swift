import XCTest
@testable import Owl

final class SubtitleDiscoveryTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/TV/Mad Men/Season 1")

    private func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// Subtitles for another release of the same episode share the show and
    /// the episode with the video, and nothing else.
    func testASubtitleForAnotherReleaseOfTheEpisodeIsFound() {
        let video = file("Mad Men.S01E01 - Smoke Gets in Your Eyes (1080p BluRay x265 LION).mkv")
        let subtitle = file(
            "Mad.Men.S01E01.Smoke.Gets.in.Your.Eyes.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-NOGRP.chs&eng.ass"
        )

        XCTAssertEqual(SubtitleDiscovery.matches(for: video, among: [video, subtitle]), [subtitle])
    }

    func testOtherEpisodesShowsAndFilesAreLeftOut() {
        let video = file("Mad Men.S01E01 - Smoke Gets in Your Eyes (1080p BluRay x265 LION).mkv")
        let files = [
            file("Mad.Men.S01E02.Ladies.Room.1080p.BluRay-NOGRP.chs&eng.ass"),
            file("Mad.Men.S02E01.For.Those.Who.Think.Young.1080p.BluRay-NOGRP.ass"),
            file("Halt.and.Catch.Fire.S01E01.I-O.1080p.WEB.srt"),
            file("Mad.Men.S01E01.Smoke.Gets.in.Your.Eyes.nfo"),
        ]

        XCTAssertEqual(SubtitleDiscovery.matches(for: video, among: files), [])
    }

    /// A name with the video's in it is mpv's to load; listing it here as well
    /// would put it in the menu twice.
    func testASubtitleNamedAfterTheVideoIsLeftToMPV() {
        let video = file("Mad.Men.S01E01.mkv")
        let subtitle = file("Mad.Men.S01E01.en.srt")

        XCTAssertEqual(SubtitleDiscovery.matches(for: video, among: [subtitle]), [])
    }

    func testASubtitleNamedOnlyForTheEpisodeIsFound() {
        let video = file("Mad Men - S01E03 - Marriage of Figaro.mkv")
        let subtitle = file("S01E03.srt")

        XCTAssertEqual(SubtitleDiscovery.matches(for: video, among: [subtitle]), [subtitle])
    }

    func testAFilmMatchesOnItsTitleAndYear() {
        let folder = URL(fileURLWithPath: "/Films")
        let video = folder.appendingPathComponent("Blade Runner 2049 (2017) [2160p].mkv")
        let same = folder.appendingPathComponent("Blade.Runner.2049.2017.1080p.BluRay.x264-GRP.zh.srt")
        let remake = folder.appendingPathComponent("Blade.Runner.2049.2027.WEB.srt")
        let other = folder.appendingPathComponent("Blade.Runner.1982.Final.Cut.srt")

        XCTAssertEqual(
            SubtitleDiscovery.matches(for: video, among: [same, remake, other]),
            [same]
        )
    }

    func testMatchesAreFoundOnDiskBesideTheVideoAndInASubsFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlSubtitleDiscovery-\(UUID())")
        let subs = directory.appendingPathComponent("Subs")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let video = directory.appendingPathComponent("Mad Men.S01E01 - Smoke Gets in Your Eyes.mkv")
        let beside = directory.appendingPathComponent("Mad.Men.S01E01.NOGRP.chs&eng.ass")
        let inSubs = subs.appendingPathComponent("Mad.Men.S01E01.NOGRP.eng.srt")
        for url in [video, beside, inSubs] {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }

        XCTAssertEqual(
            SubtitleDiscovery.subtitles(for: video).map(\.lastPathComponent),
            [beside.lastPathComponent, inSubs.lastPathComponent]
        )
    }
}
