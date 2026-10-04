import Foundation

/// One of the chapters a file marks out, as mpv reports it.
struct Chapter: Identifiable, Equatable, Sendable {
    /// The chapter's place in the file, from 0. mpv numbers them this way too.
    let index: Int
    let title: String
    /// Seconds into the file where the chapter begins.
    let start: Double

    var id: Int { index }

    /// A chapter's own title, or its number for the many files whose chapters
    /// are only marks with nothing written against them.
    var displayName: String {
        title.isEmpty ? "Chapter \(index + 1)" : title
    }
}

/// Where Next and Previous Chapter go from a given moment.
///
/// Worked out here from the list rather than left to mpv's `add chapter`, which
/// steps past the last chapter into the end of the file — and with the queue
/// advancing on its own, that is the next video, not the last chapter.
enum ChapterNavigation {
    /// How close to a chapter's start counts as being at it. A seek lands on
    /// the frame nearest the mark, a hair either side of it, and the chapter
    /// it was aimed at has to be the one it is in, not the one before.
    static let tolerance: Double = 0.5

    /// How far into a chapter Previous goes back to its start rather than to
    /// the chapter before, the same rule as Previous between videos.
    static let restartThreshold: Double = 3

    static func chapter(at time: Double, in chapters: [Chapter]) -> Chapter? {
        chapters.last { $0.start <= time + tolerance }
    }

    static func next(after time: Double, in chapters: [Chapter]) -> Chapter? {
        chapters.first { $0.start > time + tolerance }
    }

    static func previous(from time: Double, in chapters: [Chapter]) -> Chapter? {
        guard let current = chapter(at: time, in: chapters) else { return nil }
        if time - current.start > restartThreshold {
            return current
        }
        return chapters.last { $0.index < current.index }
    }
}
