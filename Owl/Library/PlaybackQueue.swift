import Foundation

enum RepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var label: String {
        switch self {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    var symbolName: String {
        switch self {
        case .off: "repeat"
        case .all: "repeat"
        case .one: "repeat.1"
        }
    }
}

@MainActor
final class PlaybackQueue: ObservableObject {
    @Published private(set) var videos: [URL] = []
    @Published private(set) var current: URL?
    @Published var isShuffled = false {
        didSet {
            guard oldValue != isShuffled else { return }
            rebuildShuffleOrder()
        }
    }
    @Published var repeatMode: RepeatMode = .off

    private var shuffleOrder: [URL] = []
    private let shuffleProvider: ([URL]) -> [URL]

    init(shuffleProvider: @escaping ([URL]) -> [URL] = { $0.shuffled() }) {
        self.shuffleProvider = shuffleProvider
    }

    func select(_ url: URL, from videos: [URL]) {
        self.videos = videos
        current = url
        rebuildShuffleOrder()
    }

    func updateVideos(_ newVideos: [URL]) {
        videos = newVideos
        if let current, !newVideos.contains(current) {
            self.current = nil
        }

        if isShuffled {
            let retained = shuffleOrder.filter(newVideos.contains)
            let additions = newVideos.filter { !retained.contains($0) }
            shuffleOrder = retained + shuffleProvider(additions)
        } else {
            shuffleOrder = []
        }
    }

    /// Moves straight to a video picked from the queue, keeping the shuffled
    /// order as it is so that what follows it is still what was dealt.
    func jump(to url: URL) -> Bool {
        guard videos.contains(url) else { return false }
        current = url
        return true
    }

    func clear() {
        videos = []
        current = nil
        shuffleOrder = []
    }

    func next(automatic: Bool = false) -> URL? {
        guard let current else { return nil }
        if automatic, repeatMode == .one {
            return current
        }

        let order = activeOrder
        guard let index = order.firstIndex(of: current) else { return nil }
        let nextIndex = order.index(after: index)
        if nextIndex < order.endIndex {
            self.current = order[nextIndex]
            return order[nextIndex]
        }

        guard repeatMode == .all, !order.isEmpty else {
            return nil
        }

        if isShuffled {
            shuffleOrder = shuffleProvider(videos)
        }
        let first = activeOrder.first
        self.current = first
        return first
    }

    func previous() -> URL? {
        guard let current else { return nil }
        let order = activeOrder
        guard let index = order.firstIndex(of: current), index > order.startIndex else {
            if repeatMode == .all {
                let last = order.last
                self.current = last
                return last
            }
            return nil
        }
        let previous = order[order.index(before: index)]
        self.current = previous
        return previous
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    /// Flips between not repeating and repeating the current video. For a
    /// window with no queue to cycle through, "Repeat All" means nothing, so
    /// this is the only toggle such a window offers.
    func toggleRepeatOne() {
        repeatMode = repeatMode == .off ? .one : .off
    }

    private var activeOrder: [URL] {
        isShuffled ? shuffleOrder : videos
    }

    private func rebuildShuffleOrder() {
        guard isShuffled else {
            shuffleOrder = []
            return
        }
        if let current {
            shuffleOrder = [current] + shuffleProvider(videos.filter { $0 != current })
        } else {
            shuffleOrder = shuffleProvider(videos)
        }
    }
}
