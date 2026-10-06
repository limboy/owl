import XCTest
@testable import Owl

final class OnlineMetadataTests: XCTestCase {
    /// An episode is named by its series and number ahead of its own title,
    /// which leaves only the running time for the line under it.
    func testAnEpisodeIsTitledWithItsSeriesAndNumber() {
        let metadata = OnlineMetadata(
            title: "Smoke Gets in Your Eyes",
            year: 2007,
            episodeLabel: "Mad Men · S1E1"
        )

        XCTAssertEqual(metadata.displayTitle, "Mad Men · S1E1 · Smoke Gets in Your Eyes")
        XCTAssertNil(metadata.detailLine)
    }

    func testAFilmKeepsItsTitleWithItsYearUnderIt() {
        let metadata = OnlineMetadata(title: "Blade Runner 2049", year: 2017, episodeLabel: nil)

        XCTAssertEqual(metadata.displayTitle, "Blade Runner 2049")
        XCTAssertEqual(metadata.detailLine, "2017")
    }
}
