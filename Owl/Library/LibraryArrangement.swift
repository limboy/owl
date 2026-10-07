import Foundation

/// The orders the browser can show a folder in.
enum LibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case dateAdded
    case recentlyWatched

    static let defaultsKey = "LibrarySortOrder"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .dateAdded: "Date Added"
        case .recentlyWatched: "Recently Watched"
        }
    }
}

/// What the browser shows of a folder: its entries narrowed to a search and put
/// in an order.
///
/// Folders stay ahead of videos whatever the order, as they always have: a
/// folder is somewhere to go rather than something to watch, and mixing the two
/// would scatter the way into a season among its neighbours' episodes.
enum LibraryArrangement {
    /// `title` is the name the card shows — the catalogue's, where there is
    /// one — and is searched alongside the file name, so a film can be found
    /// by either. Every word of the query has to turn up in one or the other,
    /// ignoring case and accents. `lastWatched` is nil for anything never
    /// played.
    static func arrange(
        _ entries: [BrowserEntry],
        matching query: String,
        by order: LibrarySortOrder,
        title: (BrowserEntry) -> String,
        lastWatched: (BrowserEntry) -> Date?
    ) -> [BrowserEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        // Worked out once per entry rather than once per comparison: a sort
        // asks for each of these many times over, and a folder's last-watched
        // date is a search through everything ever played.
        let titles = Dictionary(
            entries.map { ($0.url, title($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let matching = terms.isEmpty ? entries : entries.filter { entry in
            let shown = titles[entry.url] ?? entry.name
            return terms.allSatisfy { term in
                entry.name.localizedStandardContains(term) || shown.localizedStandardContains(term)
            }
        }
        let watched: [URL: Date] = order == .recentlyWatched
            ? Dictionary(
                matching.compactMap { entry in lastWatched(entry).map { (entry.url, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            : [:]

        let byName: (BrowserEntry, BrowserEntry) -> Bool = { lhs, rhs in
            let left = titles[lhs.url] ?? lhs.name
            let right = titles[rhs.url] ?? rhs.name
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        let inOrder: (BrowserEntry, BrowserEntry) -> Bool
        switch order {
        case .name:
            inOrder = byName
        case .dateAdded:
            // Newest first, the way a list sorted by date is wanted: what just
            // arrived is what is being looked for.
            inOrder = { lhs, rhs in
                newestFirst(lhs.dateAdded, rhs.dateAdded) ?? byName(lhs, rhs)
            }
        case .recentlyWatched:
            inOrder = { lhs, rhs in
                newestFirst(watched[lhs.url], watched[rhs.url]) ?? byName(lhs, rhs)
            }
        }

        return matching.sorted { lhs, rhs in
            if (lhs.kind == .folder) != (rhs.kind == .folder) {
                return lhs.kind == .folder
            }
            return inOrder(lhs, rhs)
        }
    }

    /// Whether `lhs` comes first by date, newest first and anything undated
    /// last, or nil when the dates do not decide it.
    private static func newestFirst(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs: lhs > rhs
        case (_?, nil): true
        case (nil, _?): false
        default: nil
        }
    }
}
