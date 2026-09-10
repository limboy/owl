import AppKit
import SwiftUI

struct FolderBrowserView: View {
    private enum Layout: String {
        case grid
        case list
    }

    @ObservedObject var appModel: AppModel
    @ObservedObject private var library: FolderLibrary
    @ObservedObject private var playbackQueue: PlaybackQueue

    /// Whether a video is up, passed in rather than read from `PlayerState`.
    ///
    /// The browser stays in the hierarchy underneath the picture, so observing
    /// the player would re-evaluate this whole view — split view, toolbar,
    /// sidebar and every row in the folder — each time the clock ticks, several
    /// times a second, for the entire time a video plays. It is the position
    /// that moves that often; whether there is a video at all changes twice.
    private let hasMedia: Bool
    @AppStorage("FolderBrowserLayout") private var storedLayout = Layout.grid.rawValue
    @State private var destination: BrowserDestination?
    @State private var didRestoreLocation = false
    @State private var pendingRootSelectionID: UUID?
    @FocusState private var isSidebarFocused: Bool
    @State private var headerOriginX: CGFloat = 0

    private let gridColumns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 18, alignment: .top)
    ]

    private let listColumns = [
        GridItem(.adaptive(minimum: 450, maximum: 900), spacing: 8, alignment: .topLeading)
    ]

    init(appModel: AppModel, library: FolderLibrary, hasMedia: Bool) {
        self.appModel = appModel
        self.hasMedia = hasMedia
        _library = ObservedObject(wrappedValue: library)
        _playbackQueue = ObservedObject(wrappedValue: appModel.playbackQueue)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
                .toolbar {
                    ToolbarItem(id: SidebarToolbarPlacement.addFolderID, placement: .navigation) {
                        Button("Add Folder", systemImage: "folder.badge.plus", action: chooseFolders)
                            .labelStyle(.iconOnly)
                            .help("Add Folder")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                .background {
                    SidebarToolbarPlacement()
                        .frame(width: 0, height: 0)
                }
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

                    ToolbarItem(placement: .primaryAction) {
                        playbackOptionsMenu
                    }
                }
                // The toolbar is drawn in the title bar, above the content, so
                // a picture that covers the window would still be picked at by
                // the layout control. There is no layout to choose while the
                // video is up.
                .toolbar(hasMedia ? .hidden : .automatic, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
        .coordinateSpace(.named(Self.splitSpace))
        .background(Color(nsColor: .windowBackgroundColor))
        // The drag cursor's copy badge is the whole affordance: a border and a
        // tint across the window said no more than the badge already does, and
        // washed out the library underneath while they were up.
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls)
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
        .onChange(of: destination) { _, _ in rememberLocation() }
        .onChange(of: library.navigationPath) { _, _ in rememberLocation() }
        .onChange(of: library.roots) { _, _ in
            synchronizeSelection()
        }
    }

    private var layout: Layout {
        get { Layout(rawValue: storedLayout) ?? .grid }
        nonmutating set { storedLayout = newValue.rawValue }
    }

    private var showsContinueWatching: Bool { destination == .continueWatching }

    private var selectedRootID: UUID? {
        get {
            if case .folder(let id) = destination { return id }
            return nil
        }
        nonmutating set { destination = newValue.map(BrowserDestination.folder) }
    }

    private func rememberLocation() {
        guard didRestoreLocation, let destination else { return }
        BrowserLocation(destination: destination, path: library.navigationPath).save()
    }

    private var sidebar: some View {
        List(selection: $destination) {
            Label("Continue Watching", systemImage: "play.circle")
                .tag(BrowserDestination.continueWatching)

            Section("Folders") {
                ForEach(library.roots) { root in
                    Label {
                        Text(root.displayName)
                            .foregroundStyle(root.isAvailable ? .primary : .secondary)
                    } icon: {
                        Image(systemName: root.isAvailable ? "folder" : "folder.badge.questionmark")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .tag(BrowserDestination.folder(root.id))
                    .contextMenu {
                        if root.isAvailable {
                            Button("Show in Finder") { showInFinder(root) }
                        } else {
                            Button("Reconnect…") { reconnect(root) }
                        }
                        Divider()
                        Button("Remove Folder", role: .destructive) {
                            library.removeRoot(id: root.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, 0, for: .scrollContent)
        .focused($isSidebarFocused)
        .onChange(of: destination) { _, value in
            guard case .folder(let rootID) = value,
                  let root = library.roots.first(where: { $0.id == rootID })
            else { return }
            navigate(to: root)
        }
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

                if showsContinueWatching {
                    ContinueWatchingView(
                        appModel: appModel,
                        isGrid: layout == .grid,
                        hasMedia: hasMedia,
                        usesOnlineMetadata: library.isMetadataSyncEnabled
                    )
                } else if library.roots.isEmpty {
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

    /// Room for the window buttons, Add Folder, and the sidebar toggle when
    /// the sidebar is collapsed.
    private static let titleBarControlsWidth: CGFloat = 196

    /// How much of the trailing title bar strip the layout picker, playback
    /// options menu take up. The header runs up under
    /// the title bar, so the title has to stop short of these controls rather
    /// than truncate beneath them.
    private static let toolbarControlsWidth: CGFloat = 156

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
            if !showsContinueWatching, library.navigationPath.count > 1 {
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
        .padding(.trailing, Self.toolbarControlsWidth)
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

    private var playbackOptionsMenu: some View {
        Menu {
            Menu("Loop") {
                repeatModeToggle("Off", mode: .off)
                repeatModeToggle("All Videos", mode: .all)
                repeatModeToggle("Current Video", mode: .one)
            }

            Toggle("Shuffle", isOn: $playbackQueue.isShuffled)

            Divider()

            Toggle("Sync Metadata", isOn: $library.isMetadataSyncEnabled)
                .disabled(!library.isMetadataSyncAvailable)

            if !library.isMetadataSyncAvailable {
                // A plain Text is drawn as a disabled item, which is what this
                // is: not something to pick, just the reason the switch above
                // cannot be.
                Text("This build has no metadata service key.")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .help("Playback Options")
        .accessibilityLabel("Playback Options")
    }

    private func repeatModeToggle(_ title: String, mode: RepeatMode) -> some View {
        Toggle(title, isOn: Binding(
            get: { playbackQueue.repeatMode == mode },
            set: { if $0 { playbackQueue.repeatMode = mode } }
        ))
    }

    private var detailTitle: String {
        if showsContinueWatching { return "Continue Watching" }
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
            LazyVGrid(columns: listColumns, alignment: .leading, spacing: 2) {
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
        let online = onlineMetadata(for: entry)
        return LibraryGridButton(
            title: title(for: entry),
            subtitle: subtitle(for: entry),
            source: entry.kind == .folder ? .folder(entry.url) : .video(entry.url),
            artworkPath: online?.artworkPath,
            isFolder: entry.kind == .folder,
            progress: entry.kind == .video ? appModel.playbackProgress(for: entry.url) : nil,
            isEnabled: true,
            onToggleWatched: entry.kind == .video ? { toggleWatched(entry) } : nil,
            action: { open(entry) }
        )
        .modifier(EntryContextMenu(entry: entry, showInFinder: showInFinder, moveToTrash: moveToTrash))
    }

    private func entryListItem(_ entry: BrowserEntry) -> some View {
        let online = onlineMetadata(for: entry)
        return LibraryListButton(
            title: title(for: entry),
            subtitle: listSubtitle(for: entry, online: online),
            source: entry.kind == .folder ? .folder(entry.url) : .video(entry.url),
            artworkPath: online?.artworkPath,
            isFolder: entry.kind == .folder,
            description: online?.overview,
            progress: entry.kind == .video ? appModel.playbackProgress(for: entry.url) : nil,
            metadataText: entry.kind == .video
                ? library.metadata(for: entry.url)?.summaryParts.joined(separator: "  ·  ")
                : nil,
            isEnabled: true,
            onToggleWatched: entry.kind == .video ? { toggleWatched(entry) } : nil,
            action: { open(entry) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(EntryContextMenu(entry: entry, showInFinder: showInFinder, moveToTrash: moveToTrash))
    }

    private func onlineMetadata(for entry: BrowserEntry) -> OnlineMetadata? {
        guard entry.kind == .video else { return nil }
        return library.onlineMetadata(for: entry.url)
    }

    /// What the work is called, in preference to what the file is called. A
    /// release name is a description of an encode; the catalogue's title is the
    /// thing somebody meant to watch.
    private func title(for entry: BrowserEntry) -> String {
        onlineMetadata(for: entry)?.title ?? entry.name
    }

    private func subtitle(for entry: BrowserEntry) -> String {
        switch entry.kind {
        case .folder:
            return "Folder"
        case .video:
            // A card is one line wide, so the series and episode — the thing
            // that tells one row from the next — comes before the summary.
            if let online = onlineMetadata(for: entry) {
                return online.subtitleLine ?? online.overview ?? entry.name
            }
            return library.metadata(for: entry.url)?.summaryParts.first
                ?? entry.url.pathExtension.uppercased()
        }
    }

    /// The line under a row's title: a folder's location as before, and for a
    /// matched video the series and episode, or the year for a film. The
    /// description gets a line of its own below this one.
    private func listSubtitle(for entry: BrowserEntry, online: OnlineMetadata?) -> String? {
        if entry.kind == .folder {
            return entry.url.path
        }
        return online?.subtitleLine
    }

    private func select(_ root: LibraryRoot, focusSidebar: Bool = false) {
        selectedRootID = root.id
        navigate(to: root)
        if focusSidebar {
            isSidebarFocused = true
        }
    }

    private func navigate(to root: LibraryRoot) {
        if root.isAvailable {
            let currentRoot = library.navigationPath.first?.standardizedFileURL
            guard currentRoot != root.url.standardizedFileURL || library.isAtRootList else {
                return
            }
            library.openRoot(root)
        } else if !library.isAtRootList {
            library.goToRootList()
        }
    }

    private func synchronizeSelection() {
        if let pendingRootSelectionID,
           let root = library.roots.first(where: { $0.id == pendingRootSelectionID }) {
            self.pendingRootSelectionID = nil
            select(root, focusSidebar: true)
            return
        }

        if !didRestoreLocation {
            didRestoreLocation = true
            if let location = BrowserLocation.load() {
                destination = location.destination
                if case .folder(let id) = location.destination,
                   let root = library.roots.first(where: { $0.id == id }), root.isAvailable {
                    library.openRoot(root)
                    for folder in location.path.dropFirst() {
                        guard folder.deletingLastPathComponent().standardizedFileURL
                            == library.currentDirectory?.standardizedFileURL else { break }
                        library.openFolder(folder)
                    }
                }
            } else if !appModel.progressStore.continueWatching.isEmpty {
                destination = .continueWatching
            }
        }

        if showsContinueWatching { return }

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
            pendingRootSelectionID = root.id
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
            pendingRootSelectionID = root.id
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

    private func showInFinder(_ root: LibraryRoot) {
        NSWorkspace.shared.activateFileViewerSelecting([root.url])
    }

    private func moveToTrash(_ entry: BrowserEntry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        } catch {
            library.errorMessage = "Could not move \(entry.name) to Trash: \(error.localizedDescription)"
        }
    }
}

enum CoverSource: Hashable {
    case folder(URL)
    case video(URL)
}

struct LibraryGridButton: View {
    let title: String
    let subtitle: String
    let source: CoverSource
    let artworkPath: String?
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
                    artworkPath: artworkPath,
                    isFolder: isFolder,
                    progress: progress,
                    showsWatchedAffordance: showsWatchedAffordance
                )
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.1))
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.hoverSpace))
                    } action: { coverFrame = $0 }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LibraryItemButtonStyle())
        .disabled(!isEnabled)
        .overlay(alignment: .topLeading) {
            if isCoverHovered, let onToggleWatched {
                WatchedToggleButton(
                    isWatched: progress?.isCompleted == true,
                    action: onToggleWatched
                )
                .offset(MediaCover.badgeOffset(in: coverFrame))
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

struct LibraryListButton: View {
    let title: String
    let subtitle: String?
    let source: CoverSource
    let artworkPath: String?
    let isFolder: Bool

    /// What the catalogue says the video is about, when anything does. Given a
    /// line of its own rather than folded into the subtitle, so a row that has
    /// no description stays exactly the height it always was.
    let description: String?

    let progress: PlaybackProgress?
    let metadataText: String?
    let isEnabled: Bool
    let onToggleWatched: (() -> Void)?
    let action: () -> Void
    var showsDisclosure = true

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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                MediaCover(
                    source: source,
                    artworkPath: artworkPath,
                    isFolder: isFolder,
                    progress: progress,
                    showsWatchedAffordance: showsWatchedAffordance
                )
                    .frame(width: 140, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.primary.opacity(0.08))
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.hoverSpace))
                    } action: { coverFrame = $0 }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.headline)
                            .fontWeight(.regular)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    } else {
                        if let metadataText, !metadataText.isEmpty {
                            Text(metadataText)
                                .font(.headline)
                                .fontWeight(.regular)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }

                }
                
                Spacer()

                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(LibraryItemButtonStyle())
        .disabled(!isEnabled)
        .overlay(alignment: .topLeading) {
            if isCoverHovered, let onToggleWatched {
                WatchedToggleButton(
                    isWatched: progress?.isCompleted == true,
                    action: onToggleWatched
                )
                .offset(MediaCover.badgeOffset(in: coverFrame))
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
                .frame(width: MediaCover.badgeSize, height: MediaCover.badgeSize)
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

    /// The catalogue's artwork for this video, when it has been matched to
    /// one. Preferred over a frame out of the file: it is the picture chosen
    /// to represent the work, where an extracted frame is whatever happened to
    /// be on screen ten seconds in.
    var artworkPath: String?

    let isFolder: Bool
    let progress: PlaybackProgress?
    var showsWatchedAffordance = false

    /// The watched badge's size, and its inset from the artwork's top-trailing
    /// corner. Public because the click target is a separate view stacked over
    /// the cover: it is placed from these, so the two cannot drift apart the
    /// way they did when the row spelled out its own numbers.
    static let badgeSize: CGFloat = 24
    static let badgeInset: CGFloat = 8

    /// Where a badge-sized click target has to sit, in whatever space
    /// `coverFrame` was measured in, to land on the badge.
    static func badgeOffset(in coverFrame: CGRect) -> CGSize {
        CGSize(
            width: coverFrame.maxX - badgeInset - badgeSize,
            height: coverFrame.minY + badgeInset
        )
    }

    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    /// What a cover is being drawn for. Both parts matter: artwork arrives
    /// after the row is already showing an extracted frame, and the task has to
    /// run again when it does.
    private struct Request: Equatable {
        var source: CoverSource
        var artworkPath: String?
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(placeholderFill)

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
        .task(id: Request(source: source, artworkPath: artworkPath)) {
            guard let loaded = await loadImage() else { return }
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    /// What sits under artwork that hasn't loaded, or that a folder never has.
    /// Artwork is its own picture either way, so the empty cover is a shade of
    /// the page it is on rather than a panel of a fixed color.
    private var placeholderFill: LinearGradient {
        let colors: [Color] = colorScheme == .dark
            ? [Color(nsColor: .underPageBackgroundColor), .black.opacity(0.88)]
            : [Color(white: 0.90), Color(white: 0.76)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
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

        // The watched badge and the hover affordance are the same view in the same
        // slot, so toggling hover never shifts the circle.
        if isWatched || showsWatchedAffordance {
            watchedBadge
                .padding(Self.badgeInset)
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
        .frame(width: Self.badgeSize, height: Self.badgeSize)
    }

    private var playbackAccessibilityValue: String {
        guard !isFolder, let progress else { return "" }
        if progress.isCompleted { return "Watched" }
        guard progress.fraction > 0 else { return "" }
        return "\(Int((progress.fraction * 100).rounded(.down))) percent watched"
    }

    private func loadImage() async -> NSImage? {
        if let artworkPath,
           let artwork = await OnlineArtworkProvider.shared.image(forArtworkPath: artworkPath) {
            return artwork
        }
        guard !Task.isCancelled else { return nil }

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

/// SwiftUI puts navigation items after the sidebar divider. Move the native
/// item before the sidebar toggle so both controls share the sidebar toolbar,
/// including AppKit's fullscreen title-bar presentation.
struct SidebarToolbarPlacement: NSViewRepresentable {
    static let addFolderID = "Owl.AddFolder"

    /// Start keeping the Add Folder item out of the detail column.
    ///
    /// SwiftUI marks the item as a navigation one while it builds the toolbar,
    /// which happens before the toolbar reaches the window and well before the
    /// view below has one of its own. Anything that waits for a window is a
    /// pass too late: the button is drawn beside the title for the first frames
    /// after launch and then hops into the sidebar. The app starts this at
    /// launch instead, and the identifier is the app's own, so no window or
    /// toolbar is needed to recognise the item.
    @MainActor
    static func beginClaimingSidebarPlacement() {
        guard claim == nil else { return }
        claim = SidebarClaim()
    }

    @MainActor
    private static var claim: SidebarClaim?

    func makeNSView(context: Context) -> PlacementView {
        PlacementView()
    }

    func updateNSView(_ view: PlacementView, context: Context) {
        view.placeNow()
    }

    final class PlacementView: NSView {
        private var placementScheduled = false
        private var isPlacing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            // Observe item changes as SwiftUI rebuilds the toolbar. Filter by
            // the current window at delivery time, since its toolbar can change.
            for name in [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(toolbarChanged(_:)), name: name, object: nil
                )
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowUpdated),
                name: NSWindow.didUpdateNotification, object: window
            )
            placeNow()
        }

        @objc private func windowUpdated() {
            // SwiftUI can reorder the toolbar without replacing any item when
            // the sidebar collapses or the window changes presentation.
            schedulePlacement()
        }

        @objc private func toolbarChanged(_ notification: Notification) {
            guard let toolbar = notification.object as? NSToolbar,
                  toolbar === window?.toolbar else { return }
            schedulePlacement()
        }

        /// Order the item before the next time the title bar is drawn.
        ///
        /// The toolbar can still be filling in, so an async pass follows to
        /// catch items that arrive after this one.
        func placeNow() {
            placeAddFolder()
            schedulePlacement()
        }

        func schedulePlacement() {
            guard !placementScheduled else { return }
            placementScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.placementScheduled = false
                self.placeAddFolder()
            }
        }

        private func placeAddFolder() {
            // Removing and inserting posts the notifications this class listens
            // for; don't re-enter part way through a move.
            guard !isPlacing else { return }
            guard let toolbar = window?.toolbar,
                  let addIndex = toolbar.items.firstIndex(where: {
                      $0.itemIdentifier.rawValue == SidebarToolbarPlacement.addFolderID
                  }) else { return }
            isPlacing = true
            defer { isPlacing = false }

            // Sit next to the sidebar toggle, on the sidebar's side of the
            // tracking separator.
            let item = toolbar.items[addIndex]
            guard let toggleIndex = toolbar.items.firstIndex(where: Self.isSidebarToggle),
                  addIndex + 1 != toggleIndex else { return }
            toolbar.removeItem(at: addIndex)
            guard let newToggleIndex = toolbar.items.firstIndex(where: Self.isSidebarToggle) else { return }
            toolbar.insertItem(withItemIdentifier: item.itemIdentifier, at: newToggleIndex)
        }

        private static func isSidebarToggle(_ item: NSToolbarItem) -> Bool {
            item.itemIdentifier == .toggleSidebar ||
                item.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// Clears `isNavigational` on the Add Folder item as often as SwiftUI sets it.
///
/// A navigation item is drawn in the detail column whatever its place in the
/// toolbar, and SwiftUI sets the flag twice: once as the item goes in, and
/// again on the update pass that precedes the window's first frame. Watching
/// the property answers both the moment they happen, which is what keeps the
/// button from ever being drawn beside the title.
@MainActor
private final class SidebarClaim: NSObject {
    private static let navigationalKey = "navigational"

    private var claimed: [NSToolbarItem] = []
    private var isClearing = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(willAddItem(_:)),
            name: NSToolbar.willAddItemNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didRemoveItem(_:)),
            name: NSToolbar.didRemoveItemNotification, object: nil
        )
    }

    @objc private func willAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              item.itemIdentifier.rawValue == SidebarToolbarPlacement.addFolderID,
              !claimed.contains(where: { $0 === item }) else { return }
        // The toolbar hands out a fresh item each time the browser's toolbar is
        // rebuilt, so this keeps every one it is given rather than a single one.
        claimed.append(item)
        item.addObserver(self, forKeyPath: Self.navigationalKey, options: [], context: nil)
        item.isNavigational = false
    }

    @objc private func didRemoveItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              let index = claimed.firstIndex(where: { $0 === item }) else { return }
        claimed.remove(at: index)
        item.removeObserver(self, forKeyPath: Self.navigationalKey)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == Self.navigationalKey, !isClearing,
              let item = claimed.first(where: { $0 === (object as AnyObject) }),
              item.isNavigational else { return }
        isClearing = true
        item.isNavigational = false
        isClearing = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
