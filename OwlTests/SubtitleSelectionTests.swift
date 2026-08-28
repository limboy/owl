import Foundation
import XCTest
@testable import Owl

final class SubtitleSelectionTests: XCTestCase {
    func testARememberedEmbeddedTrackIsFoundByItsID() {
        let tracks = [
            track(id: 1, language: "eng", title: "English"),
            track(id: 2, language: "jpn", title: "Japanese", isSelected: true)
        ]

        XCTAssertEqual(
            SubtitleSelection.action(
                restoring: .embedded(id: 1, language: "eng", title: "English"),
                in: tracks
            ),
            .select(id: 1)
        )
    }

    /// Re-encoding a file renumbers its tracks, and the id remembered for it
    /// then names the wrong one — or none at all. How the track describes
    /// itself is what survives that.
    func testARenumberedTrackIsFoundByHowItDescribesItself() {
        let tracks = [
            track(id: 7, language: "eng", title: "English", isSelected: true),
            track(id: 8, language: "jpn", title: "Japanese")
        ]

        XCTAssertEqual(
            SubtitleSelection.action(
                restoring: .embedded(id: 2, language: "jpn", title: "Japanese"),
                in: tracks
            ),
            .select(id: 8)
        )
    }

    /// mpv's own pick is a better answer than no subtitles at all, so a choice
    /// that no longer matches anything is left alone rather than turned off.
    func testATrackThatIsNoLongerInTheFileLeavesMPVsPickAlone() {
        let tracks = [track(id: 1, language: "eng", title: "English", isSelected: true)]

        XCTAssertEqual(
            SubtitleSelection.action(
                restoring: .embedded(id: 4, language: "fre", title: "French"),
                in: tracks
            ),
            .none
        )
    }

    func testATrackThatIsAlreadyShowingIsNotSelectedAgain() {
        let tracks = [track(id: 1, language: "eng", title: "English", isSelected: true)]

        XCTAssertEqual(
            SubtitleSelection.action(
                restoring: .embedded(id: 1, language: "eng", title: "English"),
                in: tracks
            ),
            .none
        )
    }

    func testTurningSubtitlesOffIsOnlyAskedForWhenSomethingIsShowing() {
        let showing = [track(id: 1, language: "eng", title: "English", isSelected: true)]
        let hidden = [track(id: 1, language: "eng", title: "English")]

        XCTAssertEqual(SubtitleSelection.action(restoring: .off, in: showing), .turnOff)
        XCTAssertEqual(SubtitleSelection.action(restoring: .off, in: hidden), .none)
    }

    func testASidecarIsLoadedWhenAbsentAndSelectedWhenMPVAlreadyFoundIt() {
        let sidecar = URL(fileURLWithPath: "/Movies/Show/./Show.zh.srt")

        XCTAssertEqual(
            SubtitleSelection.action(restoring: .external(url: sidecar), in: []),
            .loadExternal(url: sidecar)
        )

        // mpv finds sidecars beside the video by itself, so the remembered one
        // is usually already in the list. Adding it again would put a second
        // copy of the same file in the menu.
        let found = track(
            id: 3,
            language: nil,
            title: "",
            externalURL: URL(fileURLWithPath: "/Movies/Show/Show.zh.srt")
        )
        XCTAssertEqual(
            SubtitleSelection.action(restoring: .external(url: sidecar), in: [found]),
            .select(id: 3)
        )
    }

    func testNothingIsRestoredBeforeTheTracksAreKnown() {
        XCTAssertEqual(
            SubtitleSelection.action(
                restoring: .embedded(id: 1, language: "eng", title: "English"),
                in: []
            ),
            .none
        )
        XCTAssertEqual(SubtitleSelection.action(restoring: nil, in: []), .none)
    }

    func testCyclingRunsThroughTheTracksAndThenOff() {
        let first = track(id: 1, language: "eng", title: "English")
        let second = track(id: 2, language: "jpn", title: "Japanese")
        let tracks = [first, second]

        XCTAssertEqual(SubtitleSelection.next(after: nil, in: tracks)?.id, 1)
        XCTAssertEqual(SubtitleSelection.next(after: first, in: tracks)?.id, 2)
        XCTAssertNil(SubtitleSelection.next(after: second, in: tracks))
        XCTAssertNil(SubtitleSelection.next(after: nil, in: []))
    }

    /// Only an embedded track says anything about language worth carrying to
    /// the next file: "und" is the code for a track nobody labelled, and a
    /// sidecar's language is not in the track list at all.
    func testOnlyALabelledEmbeddedChoiceTeachesALanguage() {
        XCTAssertEqual(
            SubtitleSelection.embedded(id: 1, language: "jpn", title: "").language,
            "jpn"
        )
        XCTAssertNil(SubtitleSelection.embedded(id: 1, language: "und", title: "").language)
        XCTAssertNil(SubtitleSelection.embedded(id: 1, language: nil, title: "").language)
        XCTAssertNil(SubtitleSelection.off.language)
        XCTAssertNil(
            SubtitleSelection.external(url: URL(fileURLWithPath: "/a.srt")).language
        )
    }

    func testASidecarIsRememberedByItsPathAndAnEmbeddedTrackByItsID() {
        let sidecar = URL(fileURLWithPath: "/Movies/Show.en.srt")
        let external = track(id: 4, language: "eng", title: "", externalURL: sidecar)

        XCTAssertEqual(SubtitleSelection.of(external), .external(url: sidecar))
        XCTAssertEqual(
            SubtitleSelection.of(track(id: 2, language: "eng", title: "English")),
            .embedded(id: 2, language: "eng", title: "English")
        )
    }

    /// The one thing a sidecar has to be told apart by is its file name: two
    /// of them beside the same video are the same codec with no title.
    func testASidecarIsNamedAfterItsFile() {
        let track = track(
            id: 1,
            language: nil,
            title: "",
            externalURL: URL(fileURLWithPath: "/Movies/Show.zh.srt")
        )

        XCTAssertEqual(track.displayName, "Show.zh.srt")
    }

    func testALanguageCodeIsShownAsAWord() {
        XCTAssertEqual(SubtitleLanguage.displayName(for: "eng"), "English")
        XCTAssertEqual(SubtitleLanguage.displayName(for: "chi"), "Chinese")
        // Nothing the system knows: better the raw code than an empty menu item.
        XCTAssertEqual(SubtitleLanguage.displayName(for: "qqq"), "QQQ")
    }

    private func track(
        id: Int64,
        language: String?,
        title: String,
        isSelected: Bool = false,
        externalURL: URL? = nil
    ) -> SubtitleTrack {
        SubtitleTrack(
            id: id,
            title: title,
            language: language,
            codec: "subrip",
            isExternal: externalURL != nil,
            isSelected: isSelected,
            externalURL: externalURL
        )
    }
}
