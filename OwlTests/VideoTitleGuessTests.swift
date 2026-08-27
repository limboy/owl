import Foundation
import XCTest
@testable import Owl

final class VideoTitleGuessTests: XCTestCase {
    func testReadsAReleaseNamedEpisode() throws {
        let guess = try XCTUnwrap(
            VideoTitleGuess.parse(name: "The.Expanse.S01E02.1080p.WEB-DL.x265-GROUP")
        )

        XCTAssertEqual(guess.title, "The Expanse")
        XCTAssertEqual(guess.season, 1)
        XCTAssertEqual(guess.episode, 2)
        XCTAssertTrue(guess.isEpisode)
    }

    func testReadsTheAlternateEpisodeForms() throws {
        let cross = try XCTUnwrap(VideoTitleGuess.parse(name: "Firefly 1x03 Bushwhacked"))
        XCTAssertEqual(cross.title, "Firefly")
        XCTAssertEqual(cross.season, 1)
        XCTAssertEqual(cross.episode, 3)

        let spelled = try XCTUnwrap(
            VideoTitleGuess.parse(name: "Planet Earth Season 2 Episode 4")
        )
        XCTAssertEqual(spelled.title, "Planet Earth")
        XCTAssertEqual(spelled.season, 2)
        XCTAssertEqual(spelled.episode, 4)
    }

    func testAYearAfterAShowNameBelongsToTheShow() throws {
        let guess = try XCTUnwrap(VideoTitleGuess.parse(name: "Doctor.Who.2005.S02E03.HDTV"))

        XCTAssertEqual(guess.title, "Doctor Who")
        XCTAssertEqual(guess.year, 2_005)
        XCTAssertEqual(guess.season, 2)
        XCTAssertEqual(guess.episode, 3)
    }

    func testReadsAFilmAndItsYear() throws {
        let dotted = try XCTUnwrap(
            VideoTitleGuess.parse(name: "Blade.Runner.2049.2017.2160p.UHD.BluRay.x265")
        )
        XCTAssertEqual(dotted.title, "Blade Runner 2049")
        XCTAssertEqual(dotted.year, 2_017)
        XCTAssertFalse(dotted.isEpisode)

        let bracketed = try XCTUnwrap(VideoTitleGuess.parse(name: "Arrival (2016) 1080p"))
        XCTAssertEqual(bracketed.title, "Arrival")
        XCTAssertEqual(bracketed.year, 2_016)
    }

    /// A title that is itself a year has to survive, or the search goes looking
    /// for nothing at all.
    func testALeadingYearIsPartOfTheTitle() throws {
        let guess = try XCTUnwrap(VideoTitleGuess.parse(name: "2012.2009.BluRay.x264"))

        XCTAssertEqual(guess.title, "2012")
        XCTAssertEqual(guess.year, 2_009)
    }

    func testDropsTheEncodeDescriptionFromAFilmWithNoYear() throws {
        let guess = try XCTUnwrap(VideoTitleGuess.parse(name: "Interstellar.1080p.BluRay.DTS"))

        XCTAssertEqual(guess.title, "Interstellar")
        XCTAssertNil(guess.year)
    }

    func testDropsBracketedGroups() throws {
        let guess = try XCTUnwrap(
            VideoTitleGuess.parse(name: "[SubGroup] Spirited Away [BD 1080p][x265]")
        )

        XCTAssertEqual(guess.title, "Spirited Away")
    }

    /// Dots inside an already-spaced name are punctuation, not separators.
    func testKeepsPunctuationInASpacedName() throws {
        let guess = try XCTUnwrap(VideoTitleGuess.parse(name: "Mr. Robot S01E01 1080p"))

        XCTAssertEqual(guess.title, "Mr. Robot")
        XCTAssertEqual(guess.season, 1)
        XCTAssertEqual(guess.episode, 1)
    }

    func testAFileNamedOnlyForItsNumberTakesTheShowFromItsFolder() throws {
        let url = URL(fileURLWithPath: "/Videos/Chernobyl/03.mkv")

        let guess = try XCTUnwrap(VideoTitleGuess.parse(url))

        XCTAssertEqual(guess.title, "Chernobyl")
        XCTAssertEqual(guess.episode, 3)
        XCTAssertEqual(guess.season, 1)
    }

    func testAFileNamedOnlyForItsEpisodeMarkerTakesTheShowFromItsFolder() throws {
        let url = URL(fileURLWithPath: "/Videos/Severance/S02E05.mkv")

        let guess = try XCTUnwrap(VideoTitleGuess.parse(url))

        XCTAssertEqual(guess.title, "Severance")
        XCTAssertEqual(guess.season, 2)
        XCTAssertEqual(guess.episode, 5)
    }

    func testAFileThatNamesItselfIgnoresItsFolder() throws {
        let url = URL(fileURLWithPath: "/Videos/Downloads/Dune.Part.Two.2024.1080p.mkv")

        let guess = try XCTUnwrap(VideoTitleGuess.parse(url))

        XCTAssertEqual(guess.title, "Dune Part Two")
        XCTAssertEqual(guess.year, 2_024)
    }

    /// The shape a whole library was named in: a parenthesised year between the
    /// show and the episode marker. Trimming the closing bracket without the
    /// opening one left "Mad Men (2007", which the catalogue matched nothing
    /// for, so every row in the folder stayed as it was.
    func testAParenthesisedYearIsSplitOffTheShowName() throws {
        let guess = try XCTUnwrap(
            VideoTitleGuess.parse(
                name: "Mad Men (2007) - S04E03 - The Good News (1080p BluRay x265 LION)"
            )
        )

        XCTAssertEqual(guess.title, "Mad Men")
        XCTAssertEqual(guess.year, 2_007)
        XCTAssertEqual(guess.season, 4)
        XCTAssertEqual(guess.episode, 3)
    }

    func testATitleNeverKeepsAnUnbalancedBracket() throws {
        for name in [
            "Mad Men (2007) - S04E03 - The Good News",
            "Mad Men (2007) S04E03",
            "Mad Men [2007] - S04E03",
        ] {
            let guess = try XCTUnwrap(VideoTitleGuess.parse(name: name), name)
            XCTAssertEqual(guess.title, "Mad Men", name)
        }
    }

    func testTheFolderAroundAnEpisodeIsReadTheSameWay() throws {
        let url = URL(fileURLWithPath:
            "/Series/Mad Men/Mad Men (2007) Season 4/Mad Men (2007) - S04E03 - The Good News.mkv"
        )

        let guess = try XCTUnwrap(VideoTitleGuess.parse(url))

        XCTAssertEqual(guess.title, "Mad Men")
        XCTAssertEqual(guess.season, 4)
        XCTAssertEqual(guess.episode, 3)
    }

    func testANameWithNothingToReadGivesNothing() {
        XCTAssertNil(VideoTitleGuess.parse(name: "1080p"))
        XCTAssertNil(VideoTitleGuess.parse(name: "   "))
    }
}
