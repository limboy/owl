import Foundation
import XCTest
@testable import Owl

final class TMDBClientTests: XCTestCase {
    func testMovieSearchReadsTheFirstResult() throws {
        let json = Data("""
        {"results": [
            {
                "title": "Arrival",
                "overview": "A linguist is recruited by the military.",
                "release_date": "2016-11-10",
                "backdrop_path": "/wide.jpg",
                "poster_path": "/tall.jpg"
            },
            {"title": "Arrival of a Train", "overview": "", "release_date": "1896-01-25"}
        ]}
        """.utf8)

        let metadata = try XCTUnwrap(TMDBClient.parseMovieSearch(json))

        XCTAssertEqual(metadata.title, "Arrival")
        XCTAssertEqual(metadata.overview, "A linguist is recruited by the military.")
        XCTAssertEqual(metadata.year, 2_016)
        XCTAssertNil(metadata.episodeLabel)
    }

    /// The covers are 16:9, so the wide still is the one to draw and the
    /// upright poster only stands in when there is no still.
    func testMovieSearchPrefersTheBackdropOverThePoster() throws {
        let withBoth = try XCTUnwrap(TMDBClient.parseMovieSearch(Data("""
        {"results": [{"title": "A", "backdrop_path": "/wide.jpg", "poster_path": "/tall.jpg"}]}
        """.utf8)))
        XCTAssertEqual(withBoth.artworkPath, "/wide.jpg")

        let posterOnly = try XCTUnwrap(TMDBClient.parseMovieSearch(Data("""
        {"results": [{"title": "A", "poster_path": "/tall.jpg"}]}
        """.utf8)))
        XCTAssertEqual(posterOnly.artworkPath, "/tall.jpg")
    }

    func testEmptySearchResultsAreNoMatch() {
        XCTAssertNil(TMDBClient.parseMovieSearch(Data(#"{"results": []}"#.utf8)))
        XCTAssertNil(TMDBClient.parseMovieSearch(Data(#"{"results": [{"title": "  "}]}"#.utf8)))
        XCTAssertNil(TMDBClient.parseMovieSearch(Data("not json".utf8)))
    }

    func testAnUndatedReleaseHasNoYear() {
        XCTAssertNil(TMDBClient.year(fromDate: ""))
        XCTAssertNil(TMDBClient.year(fromDate: nil))
        XCTAssertEqual(TMDBClient.year(fromDate: "2019-04-24"), 2_019)
    }

    func testAnEpisodeTakesItsNameAndStillAndTheSeriesSupplesTheRest() {
        let show = TMDBClient.SeriesMatch(
            id: 63_639,
            name: "The Expanse",
            overview: "Two hundred years in the future.",
            year: 2_015,
            artworkPath: "/show.jpg"
        )
        let episode = TMDBClient.EpisodeMatch(
            name: "The Big Empty",
            overview: "Holden and the crew.",
            stillPath: "/still.jpg"
        )

        let merged = TMDBClient.merge(show: show, episode: episode, season: 1, number: 2)

        XCTAssertEqual(merged.title, "The Big Empty")
        XCTAssertEqual(merged.overview, "Holden and the crew.")
        XCTAssertEqual(merged.artworkPath, "/still.jpg")
        XCTAssertEqual(merged.episodeLabel, "The Expanse · S1E2")
        XCTAssertEqual(merged.year, 2_015)
    }

    /// A season the catalogue has not filled in still leaves the row better off
    /// than the file name did.
    func testAMissingEpisodeFallsBackToTheSeries() {
        let show = TMDBClient.SeriesMatch(
            id: 1,
            name: "Chernobyl",
            overview: "In April 1986.",
            year: 2_019,
            artworkPath: "/show.jpg"
        )

        let merged = TMDBClient.merge(show: show, episode: nil, season: 1, number: 4)

        XCTAssertEqual(merged.title, "Chernobyl")
        XCTAssertEqual(merged.overview, "In April 1986.")
        XCTAssertEqual(merged.artworkPath, "/show.jpg")
        XCTAssertEqual(merged.episodeLabel, "Chernobyl · S1E4")
    }

    func testAnEmptyEpisodeResponseIsNoMatch() {
        XCTAssertNil(TMDBClient.parseEpisode(Data("{}".utf8)))
        XCTAssertNil(TMDBClient.parseEpisode(Data(#"{"name": "", "overview": ""}"#.utf8)))
        XCTAssertNotNil(TMDBClient.parseEpisode(Data(#"{"name": "Leviathan Wakes"}"#.utf8)))
    }

    func testRequestsCarryTheKeyAndTheQuery() throws {
        let request = try XCTUnwrap(
            TMDBClient.request(
                path: "/3/search/movie",
                queryItems: [
                    URLQueryItem(name: "query", value: "Blade Runner 2049"),
                    URLQueryItem(name: "year", value: "2017"),
                ],
                apiKey: "secret"
            )
        )
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, TMDBClient.host)
        XCTAssertEqual(components.path, "/3/search/movie")
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        XCTAssertEqual(items["query"], "Blade Runner 2049")
        XCTAssertEqual(items["year"], "2017")
        XCTAssertEqual(items["api_key"], "secret")
    }

    func testAMovieLookUpGoesToTheSearchEndpoint() async throws {
        let recorded = RecordedRequests()
        let client = TMDBClient(apiKey: "secret") { request in
            await recorded.append(request)
            return Data("""
            {"results": [{"title": "Arrival", "release_date": "2016-11-10"}]}
            """.utf8)
        }

        let metadata = try await client.movie(title: "Arrival", year: 2_016)

        XCTAssertEqual(metadata?.title, "Arrival")
        let paths = await recorded.paths
        XCTAssertEqual(paths, ["/3/search/movie"])
    }

    func testAnEpisodeLookUpFindsTheSeriesThenTheEpisode() async throws {
        let recorded = RecordedRequests()
        let client = TMDBClient(apiKey: "secret") { request in
            await recorded.append(request)
            if request.url?.path == "/3/search/tv" {
                return Data(#"{"results": [{"id": 42, "name": "The Expanse"}]}"#.utf8)
            }
            return Data(#"{"name": "The Big Empty", "still_path": "/still.jpg"}"#.utf8)
        }

        let metadata = try await client.episode(series: "The Expanse", season: 1, episode: 2)

        XCTAssertEqual(metadata?.title, "The Big Empty")
        XCTAssertEqual(metadata?.artworkPath, "/still.jpg")
        let paths = await recorded.paths
        XCTAssertEqual(paths, ["/3/search/tv", "/3/tv/42/season/1/episode/2"])
    }

    /// Nothing is asked about the episode when the series itself is unknown.
    func testAnUnknownSeriesStopsBeforeTheEpisodeRequest() async throws {
        let recorded = RecordedRequests()
        let client = TMDBClient(apiKey: "secret") { request in
            await recorded.append(request)
            return Data(#"{"results": []}"#.utf8)
        }

        let metadata = try await client.episode(series: "Nothing", season: 1, episode: 1)

        XCTAssertNil(metadata)
        let paths = await recorded.paths
        XCTAssertEqual(paths, ["/3/search/tv"])
    }

    func testAKeyIsReadFromTheEnvironmentFirst() {
        XCTAssertEqual(
            TMDBCredentials.apiKey(
                bundle: .main,
                environment: [TMDBCredentials.environmentKey: "from-environment"]
            ),
            "from-environment"
        )
    }

    /// A build setting that was never given a value expands to the literal
    /// `$(TMDB_API_KEY)`, which is not a key.
    func testAnUnexpandedBuildSettingIsNotAKey() {
        XCTAssertNil(
            TMDBCredentials.apiKey(
                bundle: Bundle(for: Self.self),
                environment: [TMDBCredentials.environmentKey: "$(TMDB_API_KEY)"]
            )
        )
        XCTAssertNil(
            TMDBCredentials.apiKey(
                bundle: Bundle(for: Self.self),
                environment: [TMDBCredentials.environmentKey: "   "]
            )
        )
    }
}

/// Collects the requests a fake transport was handed, in order.
private actor RecordedRequests {
    private(set) var requests: [URLRequest] = []

    var paths: [String] {
        requests.compactMap { $0.url?.path }
    }

    func append(_ request: URLRequest) {
        requests.append(request)
    }
}
