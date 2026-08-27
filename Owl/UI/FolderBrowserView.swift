import AppKit
import SwiftUI

struct FolderBrowserView: View {
    private enum Layout: String {
        case grid
        case list
    }

    @ObservedObject var appModel: AppModel
    @ObservedObject private var library: FolderLibrary
    @AppStorage("FolderBrowserLayout") private var storedLayout = Layout.grid.rawValue
    @State private var isDropTargeted = false
    @State private var selectedRootID: UUID?
    @State private var headerOriginX: CGFloat = 0

    private let gridColumns = [
        GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 18, alignment: .top)
    ]

    init(appModel: AppModel, library: FolderLibrary) {
        self.appModel = appModel
        _library = ObservedObject(wrappedValue: library)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            browserDetail
                .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .toolbar {
                    // Without the spacer the picker lands right beside the
                    // sidebar toggle, on top of the header's title.
                    ToolbarSpacer(.flexible)

                    ToolbarItem(placement: .primaryAction) {
                        layoutPicker
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .coordinateSpace(.named(Self.splitSpace))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                isDropTargeted = targeted
            }
        }
        .alert(
            "Owl Couldn’t Complete That Action",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )
        ) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onAppear(perform: synchronizeSelection)
        .onChange(of: library.roots) { _, _ in
            synchronizeSelection()
        }
    }

    private var layout: Layout {
        get { Layout(rawValue: storedLayout) ?? .grid }
        nonmutating set { storedLayout = newValue.rawValue }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()

                Button(action: chooseFolders) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .offset(y: -5)
                .help("Add Folder")
                .accessibilityLabel("Add Folder")
            }
            .padding(.leading, 10)
            .padding(.trailing, 48)
            .frame(height: 44)

            List(selection: rootSelection) {
                Section("Folders") {
                    ForEach(library.roots) { root in
                        Label {
                            Text(root.displayName)
                                .foregroundStyle(root.isAvailable ? .primary : .secondary)
                        } icon: {
                            Image(systemName: root.isAvailable ? "folder" : "folder.badge.questionmark")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .tag(root.id)
                        .contextMenu {
                            if !root.isAvailable {
                                Button("Reconnect…") { reconnect(root) }
                            }
                            Button("Remove Folder", role: .destructive) {
                                library.removeRoot(id: root.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var rootSelection: Binding<UUID?> {
        Binding(
            get: { selectedRootID },
            set: { rootID in
                guard let rootID,
                      let root = library.roots.first(where: { $0.id == rootID })
                else { return }
                select(root)
            }
        )
    }

    private var itemCountText: String {
        let count = library.entries.count
        return "\(count) \(count == 1 ? "item" : "items")"
    }

    private var selectedRoot: LibraryRoot? {
        guard let selectedRootID else { return nil }
        return library.roots.first { $0.id == selectedRootID }
    }

    @ViewBuilder
    private var browserDetail: some View {
        VStack(spacing: 0) {
            contentHeader

            ZStack {
                Color(nsColor: .windowBackgroundColor)

                if library.roots.isEmpty {
                    noFoldersState
                } else if let selectedRoot, !selectedRoot.isAvailable {
                    unavailableState(selectedRoot)
                } else if selectedRoot == nil {
                    chooseFolderState
                } else if library.entries.isEmpty {
                    emptyFolderState
                } else {
                    switch layout {
                    case .grid:
                        grid
                    case .list:
                        list
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// How far into the window the window buttons and the sidebar toggle reach.
    private static let titleBarControlsWidth: CGFloat = 156

    /// How much of the trailing title bar strip the layout picker takes up.
    /// The header runs up under the title bar, so the title has to stop short
    /// of the toolbar rather than truncate beneath it.
    private static let layoutControlWidth: CGFloat = 104

    private static let splitSpace = "BrowserSplit"

    /// How far in the header has to start. The window hides its title bar and
    /// the detail pane runs up under it, so whatever part of the header is not
    /// pushed clear by the sidebar shares that strip with the window buttons
    /// and the sidebar toggle.
    ///
    /// This is measured from where the pane actually sits rather than from
    /// whether the sidebar is showing, because the visibility only flips once
    /// the sidebar has finished moving — the title kept its old margin through
    /// the whole animation and then jumped. Reading the pane's own leading edge
    /// gives an inset that closes as the sidebar opens, so the title travels
    /// with it.
    private var headerLeadingInset: CGFloat {
        max(24, Self.titleBarControlsWidth - headerOriginX)
    }

    private var contentHeader: some View {
        HStack(spacing: 10) {
            if library.navigationPath.count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        library.goBack()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Back")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(detailTitle)
                    .font(.headline)
                    .lineLimit(1)

                if selectedRoot != nil {
                    Text(itemCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)
        }
        .padding(.leading, headerLeadingInset)
        .padding(.trailing, Self.layoutControlWidth)
        .frame(height: 58)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(Self.splitSpace)).minX
        } action: { headerOriginX = $0 }
    }

    /// The Grid/List toggle. It lives in the window toolbar so it picks up the
    /// system's segmented look and sits in the title bar strip beside the
    /// window's own controls.
    private var layoutPicker: some View {
        Picker("Layout", selection: Binding(
            get: { layout },
            set: { layout = $0 }
        )) {
            Image(systemName: "square.grid.2x2").tag(Layout.grid)
            Image(systemName: "list.bullet").tag(Layout.list)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Choose Grid or List View")
    }

    private var detailTitle: String {
        guard selectedRoot != nil else { return "Library" }
        return library.currentTitle
    }

    private var noFoldersState: some View {
        ContentUnavailableView {
            Label("Build Your Library", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Add a video folder, or drag one anywhere into this window.")
        } actions: {
            Button("Add Folder…", action: chooseFolders)
                .buttonStyle(.borderedProminent)
        }
    }

    private var chooseFolderState: some View {
        ContentUnavailableView {
            Label("Choose a Folder", systemImage: "sidebar.left")
        } description: {
            Text("Select a folder in the sidebar to browse its videos.")
        }
    }

    private var emptyFolderState: some View {
        ContentUnavailableView(
            "No Videos Here",
            systemImage: "film.stack",
            description: Text("This folder has no supported videos or subfolders.")
        )
    }

    private func unavailableState(_ root: LibraryRoot) -> some View {
        ContentUnavailableView {
            Label("Folder Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Reconnect \(root.displayName) to continue browsing it.")
        } actions: {
            Button("Reconnect…") { reconnect(root) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
                ForEach(library.entries) { entry in
                    entryGridItem(entry)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(library.entries) { entry in
                    entryListItem(entry)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }

    private func entryGridItem(_ entry: BrowserEntry) -> some View {
        LibraryGridButton(
            title: entry.name,
            subtitle: subtitle(for: entry),
            source: entry.kind == .folder ? .folder(entry.url) : .video(entry.url),
            isFolder: entry.kind == .folder,
            progress: entry.kind == .video ? appModel.playbackProgress(for: entry.url) : nil,
            isEnabled: true,
            onToggleWatched: entry.kind == .video ? { toggleWatched(entry) } : nil,
            action: { open(entry) }
        )
        .modifier(EntryContextMenu(entry: entry, showInFinder: showInFinder, moveToTrash: moveToTrash))
    }

    private func entryListItem(_ entry: BrowserEntry) -> some View {
        LibraryListButton(
            title: entry.name,
            subtitle: entry.kind == .folder ? entry.url.path : nil,
            source: entry.kind == .folder ? .folder(entry.url) : .video(entry.url),
            isFolder: entry.kind == .folder,
            progress: entry.kind == .video ? appModel.playbackProgress(for: entry.url) : nil,
            metadataText: entry.kind == .video
                ? library.metadata(for: entry.url)?.summaryParts.joined(separator: "  ·  ")
                : nil,
            isEnabled: true,
            onToggleWatched: entry.kind == .video ? { toggleWatched(entry) } : nil,
            action: { open(entry) }
        )
        .modifier(EntryContextMenu(entry: entry, showInFinder: showInFinder, moveToTrash: moveToTrash))
    }

    private func subtitle(for entry: BrowserEntry) -> String {
        switch entry.kind {
        case .folder:
            return "Folder"
        case .video:
            return library.metadata(for: entry.url)?.summaryParts.first ?? entry.url.pathExtension.uppercased()
        }
    }

    private func select(_ root: LibraryRoot) {
        selectedRootID = root.id
        withAnimation(.easeInOut(duration: 0.2)) {
            if root.isAvailable {
                library.openRoot(root)
            } else {
                library.goToRootList()
            }
        }
    }

    private func synchronizeSelection() {
        if let pathRoot = library.navigationPath.first,
           let root = library.roots.first(where: {
               $0.url.standardizedFileURL == pathRoot.standardizedFileURL
           }) {
            selectedRootID = root.id
            return
        }

        if let selectedRootID,
           let root = library.roots.first(where: { $0.id == selectedRootID }) {
            if library.isAtRootList, root.isAvailable {
                library.openRoot(root)
            }
            return
        }

        guard let first = library.roots.first else {
            selectedRootID = nil
            library.goToRootList()
            return
        }
        select(first)
    }

    private func open(_ entry: BrowserEntry) {
        switch entry.kind {
        case .folder:
            withAnimation(.easeInOut(duration: 0.2)) {
                library.openFolder(entry.url)
            }
        case .video:
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                appModel.play(
                    entry.url,
                    from: library.visibleVideos,
                    directory: library.currentDirectory
                )
            }
        }
    }

    private func toggleWatched(_ entry: BrowserEntry) {
        appModel.toggleWatched(
            for: entry.url,
            duration: library.metadata(for: entry.url)?.duration
        )
    }

    private func accept(_ urls: [URL]) -> Bool {
        let videos = urls.filter(FolderLibrary.isVideo)
        let folders = urls.filter { !videos.contains($0) }
        let added = library.addFolders(folders)

        if added,
           let addedURL = folders.first?.standardizedFileURL,
           let root = library.roots.first(where: { $0.url.standardizedFileURL == addedURL }) {
            select(root)
        }

        if let video = videos.first {
            appModel.play(video, from: videos, directory: video.deletingLastPathComponent())
        }
        return added || !videos.isEmpty
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add Video Folder"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.presentAsSheet { urls in
            guard library.addFolders(urls),
                  let addedURL = urls.first?.standardizedFileURL,
                  let root = library.roots.first(where: {
                      $0.url.standardizedFileURL == addedURL
                  })
            else {
                return
            }
            select(root)
        }
    }

    private func reconnect(_ root: LibraryRoot) {
        let panel = NSOpenPanel()
        panel.title = "Reconnect \(root.displayName)"
        panel.prompt = "Reconnect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.presentAsSheet { urls in
            guard let url = urls.first else { return }
            library.replaceRoot(id: root.id, with: url)
        }
    }

    private func showInFinder(_ entry: BrowserEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    private func moveToTrash(_ entry: BrowserEntry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        } catch {
            library.errorMessage = "Could not move \(entry.name) to Trash: \(error.localizedDescription)"
        }
    }
}

private enum CoverSource: Hashable {
    case folder(URL)
    case video(URL)
}

private struct LibraryGridButton: View {
    let title: String
    let subtitle: String
    let source: CoverSource
    let isFolder: Bool
    let progress: PlaybackProgress?
    let isEnabled: Bool
    let onToggleWatched: (() -> Void)?
    let action: () -> Void

    /// Where the artwork sits inside the card, and whether the pointer is in it.
    ///
    /// The pointer is tracked on the whole card rather than on the artwork,
    /// because the toggle is an overlay stacked above the artwork and outside
    /// it: an `onHover` on the artwork alone lost the pointer the instant it
    /// crossed onto the toggle, which hid the toggle, handed the pointer back,
    /// and flickered. One tracker on an ancestor of both, tested against the
    /// artwork's rect, keeps the reveal scoped to the artwork without the
    /// hand-off.
    @State private var isCoverHovered = false
    @State private var coverFrame: CGRect = .zero

    private static let hoverSpace = "LibraryGridItem"

    private var showsWatchedAffordance: Bool {
        isCoverHovered && onToggleWatched != nil
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                MediaCover(
                    source: source,
                    isFolder: isFolder,
                    progress: progress,
                    showsWatchedAffordance: showsWatchedAffordance,
                    showsTimeLeftBadge: true
                )
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.1))
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.hoverSpace))
                    } action: { coverFrame = $0 }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LibraryItemButtonStyle())
        .disabled(!isEnabled)
        .overlay(alignment: .topTrailing) {
            if isCoverHovered, let onToggleWatched {
                WatchedToggleButton(
                    isWatched: progress?.isCompleted == true,
                    action: onToggleWatched
                )
                .padding(8)
            }
        }
        .coordinateSpace(.named(Self.hoverSpace))
        .onContinuousHover(coordinateSpace: .named(Self.hoverSpace)) { phase in
            switch phase {
            case .active(let location):
                isCoverHovered = coverFrame.contains(location)
            case .ended:
                isCoverHovered = false
            }
        }
    }
}

private struct LibraryListButton: View {
    let title: String
    let subtitle: String?
    let source: CoverSource
    let isFolder: Bool
    let progress: PlaybackProgress?
    let metadataText: String?
    let isEnabled: Bool
    let onToggleWatched: (() -> Void)?
    let action: () -> Void

    /// Where the artwork sits inside the row, and whether the pointer is in it.
    ///
    /// The pointer is tracked on the whole row rather than on the artwork,
    /// because the toggle is an overlay stacked above the artwork and outside
    /// it: an `onHover` on the artwork alone lost the pointer the instant it
    /// crossed onto the toggle, which hid the toggle, handed the pointer back,
    /// and flickered. One tracker on an ancestor of both, tested against the
    /// artwork's rect, keeps the reveal scoped to the artwork without the
    /// hand-off.
    @State private var isCoverHovered = false
    @State private var coverFrame: CGRect = .zero

    private static let hoverSpace = "LibraryListItem"

    private var showsWatchedAffordance: Bool {
        isCoverHovered && onToggleWatched != nil
    }

    private var timeLeftText: String? {
        isFolder ? nil : progress?.timeLeftText
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                MediaCover(
                    source: source,
                    isFolder: isFolder,
                    progress: progress,
                    showsWatchedAffordance: showsWatchedAffordance
                )
                    .frame(width: 112, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(.white.opacity(0.08))
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.hoverSpace))
                    } action: { coverFrame = $0 }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let metadataText, !metadataText.isEmpty {
                        Text(metadataText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    if let timeLeftText {
                        Text(timeLeftText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(LibraryItemButtonStyle())
        .disabled(!isEnabled)
        .overlay(alignment: .leading) {
            if isCoverHovered, let onToggleWatched {
                WatchedToggleButton(
                    isWatched: progress?.isCompleted == true,
                    action: onToggleWatched
                )
                .padding(8)
                .frame(width: 112, height: 64, alignment: .topTrailing)
                .padding(.leading, 10)
            }
        }
        .coordinateSpace(.named(Self.hoverSpace))
        .onContinuousHover(coordinateSpace: .named(Self.hoverSpace)) { phase in
            switch phase {
            case .active(let location):
                isCoverHovered = coverFrame.contains(location)
            case .ended:
                isCoverHovered = false
            }
        }
    }
}

private struct WatchedToggleButton: View {
    let isWatched: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isWatched ? "Mark as Unwatched" : "Mark as Watched")
        .accessibilityLabel(isWatched ? "Mark as Unwatched" : "Mark as Watched")
    }
}

private struct LibraryItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.primary.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MediaCover: View {
    let source: CoverSource
    let isFolder: Bool
    let progress: PlaybackProgress?
    var showsWatchedAffordance = false
    /// Whether the remaining time belongs on the artwork. The list row prints it
    /// beside the row's disclosure arrow instead, where there is room for text.
    var showsTimeLeftBadge = false

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: .underPageBackgroundColor), .black.opacity(0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: isFolder ? "folder.fill" : "film")
                    .font(.system(size: isFolder ? 34 : 30, weight: .medium))
                    .foregroundStyle(isFolder ? Color.accentColor : .secondary)
            }

            if isFolder {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.58)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                Image(systemName: "folder.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if !isFolder {
                playbackStateOverlay
            }
        }
        .clipped()
        .accessibilityValue(playbackAccessibilityValue)
        .task(id: source) {
            image = await loadImage()
        }
    }

    private var isWatched: Bool { progress?.isCompleted == true }

    @ViewBuilder
    private var playbackStateOverlay: some View {
        if !isWatched, let progress, progress.fraction > 0 {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer()
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.black.opacity(0.45))
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * progress.fraction)
                    }
                    .frame(height: 4)
                }
            }
        }

        if showsTimeLeftBadge, let timeLeftText = progress?.timeLeftText {
            Text(timeLeftText)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }

        // The watched badge and the hover affordance are the same view in the same
        // slot, so toggling hover never shifts the circle.
        if isWatched || showsWatchedAffordance {
            watchedBadge
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    @ViewBuilder
    private var watchedBadge: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.5))
            Circle()
                .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
            if isWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 24, height: 24)
    }

    private var playbackAccessibilityValue: String {
        guard !isFolder, let progress else { return "" }
        if progress.isCompleted { return "Watched" }
        guard progress.fraction > 0 else { return "" }
        return "\(Int((progress.fraction * 100).rounded(.down))) percent watched"
    }

    private func loadImage() async -> NSImage? {
        let videoURL: URL?
        switch source {
        case .video(let url):
            videoURL = url
        case .folder(let url):
            videoURL = await FolderCoverFinder.firstVideo(in: url)
        }
        guard !Task.isCancelled, let videoURL else { return nil }
        return await MediaThumbnailProvider.shared.coverImage(for: videoURL)
    }
}

private enum FolderCoverFinder {
    /// The video a folder's cover comes from. The answer is remembered across
    /// launches, because walking a deep folder to find it is slower than
    /// extracting the frame once it has been found.
    static func firstVideo(in directory: URL) async -> URL? {
        if let remembered = await FolderCoverIndex.shared.video(for: directory) {
            return remembered
        }
        guard !Task.isCancelled, let found = await scan(directory) else { return nil }
        await FolderCoverIndex.shared.setVideo(found, for: directory)
        return found
    }

    private static func scan(_ directory: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return nil
            }

            var inspected = 0
            while let url = enumerator.nextObject() as? URL {
                guard !Task.isCancelled else { return nil }
                inspected += 1
                if inspected > 600 { break }

                let values = try? url.resourceValues(forKeys: keys)
                if values?.isHidden == true { continue }
                if values?.isRegularFile == true, FolderLibrary.isVideo(url) {
                    return url.standardizedFileURL
                }
            }
            return nil
        }.value
    }
}

private struct EntryContextMenu: ViewModifier {
    let entry: BrowserEntry
    let showInFinder: (BrowserEntry) -> Void
    let moveToTrash: (BrowserEntry) -> Void

    func body(content: Content) -> some View {
        if entry.kind == .folder {
            content
        } else {
            content.contextMenu {
                Button("Show in Finder") { showInFinder(entry) }
                Divider()
                Button("Move to Trash", role: .destructive) { moveToTrash(entry) }
            }
        }
    }
}
