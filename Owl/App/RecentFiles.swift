import AppKit
import Combine

@MainActor
protocol RecentDocumentTracking: AnyObject {
    var recentDocumentURLs: [URL] { get }
    func noteNewRecentDocumentURL(_ url: URL)
    func clearRecentDocuments(_ sender: Any?)
}

extension NSDocumentController: RecentDocumentTracking {}

/// A live menu over the system's persistent recent-document list. Its actions
/// open Owl's standalone player, rather than asking NSDocument to open a file.
@MainActor
final class RecentFiles: ObservableObject {
    static let shared: RecentFiles = {
        let environment = ProcessInfo.processInfo.environment
        let isTesting = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
        return RecentFiles(
            controller: NSDocumentController.shared,
            legacyProgress: isTesting ? nil : PlaybackProgressStore.shared.entries
        )
    }()

    @Published private(set) var urls: [URL]
    private let controller: any RecentDocumentTracking
    private static let migrationKey = "ImportedStandaloneRecentFiles"

    init(
        controller: any RecentDocumentTracking,
        defaults: UserDefaults = .standard,
        legacyProgress: [PlaybackProgress]? = nil
    ) {
        self.controller = controller
        // Earlier versions kept only progress. Records without folder context
        // are treated as standalone; never infer an origin from path membership.
        // Import once so Clear Menu stays cleared on the next launch.
        if let legacyProgress, !defaults.bool(forKey: Self.migrationKey) {
            let existing = controller.recentDocumentURLs
            for entry in legacyProgress.filter({ $0.queueDirectory == nil })
                .sorted(by: { $0.lastPlayed < $1.lastPlayed }) {
                controller.noteNewRecentDocumentURL(entry.url.standardizedFileURL)
            }
            // Explicitly opened recent files take precedence over old progress.
            for url in existing.reversed() {
                controller.noteNewRecentDocumentURL(url)
            }
            defaults.set(true, forKey: Self.migrationKey)
        }
        urls = controller.recentDocumentURLs
    }

    func record(_ url: URL) {
        controller.noteNewRecentDocumentURL(url.standardizedFileURL)
        urls = controller.recentDocumentURLs
    }

    func clear() {
        controller.clearRecentDocuments(nil)
        urls = controller.recentDocumentURLs
    }

    func title(for url: URL) -> String {
        let name = url.lastPathComponent
        guard urls.contains(where: { $0 != url && $0.lastPathComponent == name }) else { return name }
        return "\(name) — \(url.deletingLastPathComponent().path)"
    }
}
