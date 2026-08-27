import Foundation

/// The key Owl was built with, if it was built with one.
///
/// Owl talks to The Movie Database, which wants a key per application rather
/// than per person. A release build carries one, baked into the bundle from the
/// `TMDB_API_KEY` build setting; a plain local build has none, and metadata
/// sync is simply unavailable there unless `OWL_TMDB_API_KEY` is set in the
/// environment — the same escape hatch `OWL_LIBMPV_PATH` and its neighbours
/// give the other things a release build vendors.
enum TMDBCredentials {
    static let infoPlistKey = "OWLTMDBAPIKey"
    static let environmentKey = "OWL_TMDB_API_KEY"

    static func apiKey(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let candidates = [
            environment[environmentKey],
            bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
        ]
        for candidate in candidates {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            // An unset build setting expands to the empty string, and to the
            // literal `$(TMDB_API_KEY)` if the substitution never ran at all.
            guard let value, !value.isEmpty, !value.hasPrefix("$(") else { continue }
            return value
        }
        return nil
    }
}

/// Asks The Movie Database what a file is.
///
/// The requests are plain GETs against the public v3 API, so the transport is a
/// closure rather than a `URLSession` reference: the request building and the
/// response reading are the parts worth testing, and both are reachable without
/// a network.
struct TMDBClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> Data

    static let host = "api.themoviedb.org"

    /// Where artwork is served from, and at what width. 780 points wide is
    /// more than a browser cover needs on any display Owl runs on, and is the
    /// smallest of the catalogue's sizes that does not soften on a Retina one.
    static let imageBase = "https://image.tmdb.org/t/p/w780"

    let apiKey: String
    let transport: Transport

    init(apiKey: String, transport: @escaping Transport = TMDBClient.sharedTransport) {
        self.apiKey = apiKey
        self.transport = transport
    }

    /// A session of its own rather than `URLSession.shared`, so that a folder
    /// filling in cannot crowd out anything else and so the requests time out
    /// on a scale a browser row can wait for. Metadata is decoration: a row
    /// that never hears back keeps the file name it started with.
    static let sharedTransport: Transport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw TMDBError.badStatus(http.statusCode)
            }
            return data
        }
    }()

    enum TMDBError: Error {
        case badStatus(Int)
        case malformedRequest
    }

    /// The film a name appears to be naming, or nil when the catalogue has
    /// nothing that looks like it.
    func movie(title: String, year: Int?) async throws -> OnlineMetadata? {
        var items = [URLQueryItem(name: "query", value: title)]
        if let year {
            items.append(URLQueryItem(name: "year", value: String(year)))
        }
        items.append(URLQueryItem(name: "include_adult", value: "false"))

        let data = try await get(path: "/3/search/movie", queryItems: items)
        return Self.parseMovieSearch(data)
    }

    /// The episode a name appears to be naming. This takes two requests: the
    /// series has to be found by name before its episodes can be asked for by
    /// number. When the episode itself is missing — a season the catalogue has
    /// not filled in — the series still answers for the title and artwork,
    /// which beats a file name.
    func episode(series: String, season: Int, episode: Int) async throws -> OnlineMetadata? {
        let data = try await get(
            path: "/3/search/tv",
            queryItems: [
                URLQueryItem(name: "query", value: series),
                URLQueryItem(name: "include_adult", value: "false"),
            ]
        )
        guard let show = Self.parseSeriesSearch(data) else { return nil }

        let episodeData = try? await get(
            path: "/3/tv/\(show.id)/season/\(season)/episode/\(episode)",
            queryItems: []
        )
        return Self.merge(
            show: show,
            episode: episodeData.flatMap(Self.parseEpisode),
            season: season,
            number: episode
        )
    }

    private func get(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        guard let request = Self.request(
            path: path,
            queryItems: queryItems,
            apiKey: apiKey
        ) else {
            throw TMDBError.malformedRequest
        }
        return try await transport(request)
    }

    static func request(path: String, queryItems: [URLQueryItem], apiKey: String) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = queryItems + [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func artworkURL(path: String) -> URL? {
        URL(string: imageBase + path)
    }

    // MARK: - Responses

    /// The fields Owl reads, out of a search result that carries dozens.
    private struct MovieResults: Decodable {
        struct Movie: Decodable {
            let title: String?
            let overview: String?
            let release_date: String?
            let backdrop_path: String?
            let poster_path: String?
        }

        let results: [Movie]?
    }

    struct SeriesMatch: Equatable, Sendable {
        var id: Int
        var name: String
        var overview: String?
        var year: Int?
        var artworkPath: String?
    }

    private struct SeriesResults: Decodable {
        struct Series: Decodable {
            let id: Int
            let name: String?
            let overview: String?
            let first_air_date: String?
            let backdrop_path: String?
            let poster_path: String?
        }

        let results: [Series]?
    }

    struct EpisodeMatch: Equatable, Sendable {
        var name: String?
        var overview: String?
        var stillPath: String?
    }

    private struct EpisodeResponse: Decodable {
        let name: String?
        let overview: String?
        let still_path: String?
    }

    /// The catalogue orders search results by how well known they are, so the
    /// first is the answer. Nothing here tries to score the rest: a wrong first
    /// result means the file name was ambiguous, and a second guess made from
    /// the same name would be no better informed.
    static func parseMovieSearch(_ data: Data) -> OnlineMetadata? {
        guard let decoded = try? JSONDecoder().decode(MovieResults.self, from: data),
              let first = decoded.results?.first,
              let title = first.title?.trimmed, !title.isEmpty
        else {
            return nil
        }
        return OnlineMetadata(
            title: title,
            overview: first.overview?.trimmed.nilIfEmpty,
            year: year(fromDate: first.release_date),
            episodeLabel: nil,
            // The backdrop is the wide still the browser's covers are shaped
            // for; the poster is upright and would sit in a 16:9 frame as a
            // sliver between two bands, so it is only the fallback.
            artworkPath: first.backdrop_path ?? first.poster_path
        )
    }

    static func parseSeriesSearch(_ data: Data) -> SeriesMatch? {
        guard let decoded = try? JSONDecoder().decode(SeriesResults.self, from: data),
              let first = decoded.results?.first,
              let name = first.name?.trimmed, !name.isEmpty
        else {
            return nil
        }
        return SeriesMatch(
            id: first.id,
            name: name,
            overview: first.overview?.trimmed.nilIfEmpty,
            year: year(fromDate: first.first_air_date),
            artworkPath: first.backdrop_path ?? first.poster_path
        )
    }

    static func parseEpisode(_ data: Data) -> EpisodeMatch? {
        guard let decoded = try? JSONDecoder().decode(EpisodeResponse.self, from: data) else {
            return nil
        }
        let match = EpisodeMatch(
            name: decoded.name?.trimmed.nilIfEmpty,
            overview: decoded.overview?.trimmed.nilIfEmpty,
            stillPath: decoded.still_path
        )
        return match == EpisodeMatch(name: nil, overview: nil, stillPath: nil) ? nil : match
    }

    /// Puts an episode and the series it belongs to into one record, letting
    /// the series stand in wherever the episode said nothing.
    static func merge(
        show: SeriesMatch,
        episode: EpisodeMatch?,
        season: Int,
        number: Int
    ) -> OnlineMetadata {
        OnlineMetadata(
            title: episode?.name ?? show.name,
            overview: episode?.overview ?? show.overview,
            year: show.year,
            episodeLabel: "\(show.name) · S\(season)E\(number)",
            artworkPath: episode?.stillPath ?? show.artworkPath
        )
    }

    /// The catalogue writes dates as "2019-04-24", and leaves the field as an
    /// empty string for anything unreleased or undated.
    static func year(fromDate date: String?) -> Int? {
        guard let prefix = date?.split(separator: "-").first else { return nil }
        return Int(prefix)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
