import AppKit
import SwiftUI

struct ContinueWatchingView: View {
    let appModel: AppModel
    let isGrid: Bool
    let hasMedia: Bool
    let usesOnlineMetadata: Bool
    @ObservedObject private var store: PlaybackProgressStore
    @State private var entries: [PlaybackProgress] = []
    @State private var unavailable: [URL: String] = [:]
    @State private var metadata: [URL: OnlineMetadata] = [:]
    @State private var scrollID: URL?
    @State private var lastPlayedURL: URL?
    @FocusState private var focusedURL: URL?
    @State private var hoveredURL: URL?
    @State private var undoEntry: PlaybackProgress?
    @State private var notice = ""
    @State private var refreshRevision = 0
    @State private var openingURL: URL?
    @State private var openTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var keepsCurrentOrder = false

    init(appModel: AppModel, isGrid: Bool, hasMedia: Bool, usesOnlineMetadata: Bool) {
        self.appModel = appModel
        self.isGrid = isGrid
        self.hasMedia = hasMedia
        self.usesOnlineMetadata = usesOnlineMetadata
        _store = ObservedObject(wrappedValue: appModel.progressStore)
        _entries = State(initialValue: appModel.progressStore.continueWatching)
    }

    private struct Request: Equatable {
        var urls: [URL]
        var usesOnlineMetadata: Bool
        var revision: Int
        var hasMedia: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing to Continue Yet",
                    systemImage: "play.circle",
                    description: Text("Unfinished videos played from your folders will appear here. Files opened on their own are in File → Open Recent.")
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: isGrid
                            ? [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 18)]
                            : [GridItem(.flexible())],
                        alignment: .leading,
                        spacing: isGrid ? 22 : 8
                    ) {
                        ForEach(entries) { entry in
                            item(entry).id(entry.url)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, isGrid ? 24 : 18)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollPosition(id: $scrollID, anchor: .top)
            }

            if let undoEntry {
                HStack {
                    Text(notice).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") {
                        store.restoreEntry(undoEntry)
                        self.undoEntry = nil
                    }
                    Button {
                        self.undoEntry = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .font(.callout)
                .padding(12)
                .background(.bar)
                .accessibilityElement(children: .contain)
            }
        }
        .onChange(of: store.entries) { _, _ in
            // Keep the browser stable beneath the player. Reordering it every
            // five seconds would also discard the user's scroll context.
            if !hasMedia { refreshEntries() }
        }
        .onChange(of: hasMedia) { _, playing in
            if !playing {
                refreshEntries()
                refreshRevision += 1
                focusedURL = entries.contains(where: { $0.url == lastPlayedURL })
                    ? lastPlayedURL : entries.first?.url
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            refreshRevision += 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            refreshRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !hasMedia { refreshRevision += 1 }
        }
        .task(id: Request(
            urls: entries.map(\.url), usesOnlineMetadata: usesOnlineMetadata,
            revision: refreshRevision, hasMedia: hasMedia
        )) {
            guard !hasMedia else { return }
            await refreshDetails()
        }
        .onDisappear {
            openTask?.cancel()
        }
        .alert("Video Unavailable", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refreshEntries() {
        let anchor = scrollID
        let updated = store.continueWatching
        if keepsCurrentOrder {
            // A resumed card must not jump to the top underneath the player.
            // The next visit to this page starts in recency order again.
            let byURL = Dictionary(uniqueKeysWithValues: updated.map { ($0.url, $0) })
            let existingURLs = Set(entries.map(\.url))
            entries = entries.compactMap { byURL[$0.url] }
                + updated.filter { !existingURLs.contains($0.url) }
        } else {
            entries = updated
        }
        if let anchor, entries.contains(where: { $0.url == anchor }) {
            scrollID = anchor
        }
    }

    private func item(_ entry: PlaybackProgress) -> some View {
        let online = usesOnlineMetadata ? metadata[entry.url] : nil
        let title = online.map { value in
            value.episodeLabel.map { "\($0) · \(value.title)" } ?? value.title
        } ?? entry.url.lastPathComponent
        let source = sourceLabel(for: entry.url)
        let isAvailable = unavailable[entry.url] == nil
        let resumeLabel = "Continue from \(entry.resumeTimeText)"
        let status = unavailable[entry.url] ?? (
            hoveredURL == entry.url || focusedURL == entry.url
                ? resumeLabel
                : "\(entry.timeLeftText ?? resumeLabel) · \(entry.lastPlayed.formatted(.dateTime.month(.abbreviated).day()))"
        )

        return VStack(alignment: .leading, spacing: 5) {
            Group {
                if isGrid {
                    LibraryGridButton(
                        title: title, subtitle: source, source: .video(entry.url),
                        artworkPath: online?.artworkPath, isFolder: false, progress: entry,
                        isEnabled: isAvailable, onToggleWatched: nil,
                        action: { open(entry) }
                    )
                } else {
                    HStack(spacing: 4) {
                        LibraryListButton(
                            title: title, subtitle: source, source: .video(entry.url),
                            artworkPath: online?.artworkPath, isFolder: false, description: nil,
                            progress: entry, metadataText: status,
                            isEnabled: isAvailable, onToggleWatched: nil,
                            action: { open(entry) }, showsDisclosure: false
                        )
                        if openingURL == entry.url {
                            ProgressView().controlSize(.small)
                        }
                        moreMenu(for: entry, title: title)
                    }
                }
            }
            .focused($focusedURL, equals: entry.url)
            .help(isAvailable ? resumeLabel : unavailable[entry.url] ?? "File Unavailable")
            .accessibilityHint(isAvailable ? resumeLabel : "Check the file or reconnect its disk to continue.")
            .onHover { hoveredURL = $0 ? entry.url : nil }

            if isGrid {
                HStack(spacing: 6) {
                    if openingURL == entry.url {
                        ProgressView().controlSize(.small)
                    }
                    Text(status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    moreMenu(for: entry, title: title)
                }
                .font(.callout)
            }
        }
        .contextMenu { actions(for: entry) }
    }

    private func moreMenu(for entry: PlaybackProgress, title: String) -> some View {
        Menu {
            actions(for: entry)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(title)")
    }

    private func sourceLabel(for url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        let roots = appModel.folderLibrary?.roots ?? []
        if let root = roots.sorted(by: { $0.url.path.count > $1.url.path.count }).first(where: {
            parent.path == $0.url.path || parent.path.hasPrefix($0.url.path + "/")
        }) {
            return root.displayName + parent.path.dropFirst(root.url.path.count)
        }
        return parent.pathComponents.suffix(2).joined(separator: " / ")
    }

    @ViewBuilder
    private func actions(for entry: PlaybackProgress) -> some View {
        Button("Play from Beginning") { open(entry, fromBeginning: true) }
            .disabled(unavailable[entry.url] != nil)
        Button("Mark as Watched") {
            undoEntry = entry
            notice = "Marked as watched."
            store.setWatched(true, url: entry.url, duration: entry.duration)
        }
        Button("Remove from Continue Watching") {
            undoEntry = entry
            notice = "Removed from Continue Watching. Playback progress is kept."
            store.setHiddenFromContinueWatching(true, url: entry.url)
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        .disabled(unavailable[entry.url] != nil)
    }

    private func open(_ entry: PlaybackProgress, fromBeginning: Bool = false) {
        openTask?.cancel()
        openingURL = entry.url
        openTask = Task { @MainActor in
            do {
                let queue = try await Task.detached(priority: .userInitiated) {
                    try ContinueWatchingQueue.resolve(for: entry)
                }.value
                guard !Task.isCancelled else { return }
                openingURL = nil
                lastPlayedURL = entry.url
                keepsCurrentOrder = true
                undoEntry = nil
                appModel.play(
                    entry.url, from: queue.videos, directory: queue.directory,
                    fromBeginning: fromBeginning, followsBrowserQueue: false
                )
            } catch {
                guard !Task.isCancelled else { return }
                openingURL = nil
                errorMessage = "Could not open \(entry.url.lastPathComponent). Reconnect its disk or check the file in Finder."
                refreshRevision += 1
            }
        }
    }

    private func refreshDetails() async {
        let urls = entries.map(\.url)
        let missing = await Task.detached(priority: .utility) {
            var result: [URL: String] = [:]
            for url in urls where !FileManager.default.isReadableFile(atPath: url.path) {
                let components = url.pathComponents
                let volumeMissing = components.count > 2 && components[1] == "Volumes"
                    && !FileManager.default.fileExists(atPath: "/Volumes/\(components[2])")
                result[url] = volumeMissing ? "Disk Not Connected" : "File Unavailable"
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        unavailable = missing
        guard usesOnlineMetadata else {
            metadata = [:]
            return
        }
        var cached: [URL: OnlineMetadata] = [:]
        for url in urls {
            // Reuse existing matches; this page never needs a catalogue lookup.
            let record = await OnlineMetadataStore.shared.record(for: url)
            guard !Task.isCancelled else { return }
            cached[url] = record?.metadata
        }
        metadata = cached
    }
}
