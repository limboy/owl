import AppKit
import SwiftUI

extension FocusedValues {
    /// Puts the cursor in the library's search field, for Edit ▸ Find.
    @Entry var focusLibrarySearch: (() -> Void)?
}

struct FolderBrowserView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var library: FolderLibrary

    /// Where the videos picked here play.
    private let player: LibraryPlayerWindow
    @State private var destination: BrowserDestination?
    @State private var didRestoreLocation = false
    @State private var pendingRootSelectionID: UUID?
    @FocusState private var isSidebarFocused: Bool
    @State private var headerOriginX: CGFloat = 0
    @State private var toolbarControlsWidth: CGFloat = Self.minimumToolbarControlsWidth
    @State private var backButtonTrailing: CGFloat?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @AppStorage(LibrarySortOrder.defaultsKey) private var sortOrder: LibrarySortOrder = .name

    private let gridColumns = [
        GridItem(.adaptive(minimum: 260, maximum: 390), spacing: 18, alignment: .top)
    ]

    init(appModel: AppModel, library: FolderLibrary, player: LibraryPlayerWindow) {
        self.appModel = appModel
        self.player = player
        _library = ObservedObject(wrappedValue: library)
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
                    // In the toolbar rather than the header: the header runs
                    // up under the title bar, where the toolbar takes every
                    // click, so a button drawn there could be seen but never
                    // pressed — and with it the only way out of a subfolder.
                    if library.navigationPath.count > 1 {
                        ToolbarItem(id: TrailingToolbarWidthReader.backID, placement: .navigation) {
                            Button("Back", systemImage: "chevron.left") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    library.goBack()
                                }
                            }
                            .labelStyle(.iconOnly)
                            .keyboardShortcut("[", modifiers: .command)
                            .help("Back")
                        }
                    }

                    // Without the spacer the menu lands right beside the
                    // sidebar toggle, on top of the header's title.
                    ToolbarSpacer(.flexible)

                    ToolbarItem(placement: .primaryAction) {
                        sortMenu
                    }

                    ToolbarItem(placement: .primaryAction) {
                        optionsMenu
                    }
                }
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
                .searchFocused($isSearchFocused)
                .focusedSceneValue(\.focusLibrarySearch) { isSearchFocused = true }
        }
        .navigationSplitViewStyle(.balanced)
        .coordinateSpace(.named(Self.splitSpace))
        .background(Color(nsColor: .windowBackgroundColor))
        // The drag cursor's copy badge is the whole affordance: a border and a
        // tint across the window said no more than the badge already does, and
        // washed out the library underneath while they were up.
        // The empty `isTargeted` picks the overload whose action reports back
        // whether the drop was taken; there is nothing to show while it hovers.
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls)
        } isTargeted: { _ in }
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
        .onChange(of: library.navigationPath) { _, _ in
            rememberLocation()
            // A search is of the folder it was typed in; carried into the
            // next, it would hide most of what was just opened.
            searchText = ""
        }
        .onChange(of: library.roots) { _, _ in
            synchronizeSelection()
        }
    }

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
        let total = "\(count) \(count == 1 ? "item" : "items")"
        guard isSearching else { return total }
        return "\(arrangedEntries.count) of \(total)"
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The folder as the grid shows it: narrowed to the search, in the order
    /// chosen from the sort menu.
    private var arrangedEntries: [BrowserEntry] {
        LibraryArrangement.arrange(
            library.entries,
            matching: searchText,
            by: sortOrder,
            title: title(for:),
            lastWatched: appModel.lastWatched
        )
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
                } else if isSearching, arrangedEntries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    grid
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Room for the window buttons, Add Folder, and the sidebar toggle when
    /// the sidebar is collapsed.
    private static let titleBarControlsWidth: CGFloat = 196

    /// The least the title stops short of the window's trailing edge, before
    /// the toolbar has been measured. The header runs up under the title bar,
    /// so the title has to stop short of the sort and options menus and the
    /// search field rather than run beneath them; `TrailingToolbarWidthReader`
    /// measures how far in they reach.
    private static let minimumToolbarControlsWidth: CGFloat = 76

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
    ///
    /// The Back button sits in that strip too, wherever the toolbar puts it,
    /// so the title starts past it.
    private var headerLeadingInset: CGFloat {
        let base = max(24, Self.titleBarControlsWidth - headerOriginX)
        guard let backButtonTrailing else { return base }
        return max(base, backButtonTrailing + 12)
    }

    private var contentHeader: some View {
        HStack(spacing: 10) {
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
        .padding(.trailing, toolbarControlsWidth)
        .background {
            TrailingToolbarWidthReader(minimum: Self.minimumToolbarControlsWidth) {
                toolbarControlsWidth = $0
            } onBackButtonChange: {
                backButtonTrailing = $0
            }
        }
        .frame(height: 58)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(Self.splitSpace)).minX
        } action: { headerOriginX = $0 }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortOrder) {
                ForEach(LibrarySortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort By")
        .accessibilityLabel("Sort By")
    }

    private var optionsMenu: some View {
        Menu {
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
        .help("Options")
        .accessibilityLabel("Options")
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
                ForEach(arrangedEntries) { entry in
                    entryGridItem(entry)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
    }

    private func entryGridItem(_ entry: BrowserEntry) -> some View {
        let online = onlineMetadata(for: entry)
        let progress = entry.kind == .video ? appModel.playbackProgress(for: entry.url) : nil
        return LibraryGridButton(
            title: title(for: entry),
            subtitle: subtitle(for: entry),
            source: entry.kind == .folder ? .folder(entry.url) : .video(entry.url),
            artworkPath: online?.artworkPath,
            isFolder: entry.kind == .folder,
            progress: progress,
            durationText: entry.kind == .video ? library.metadata(for: entry.url)?.durationText : nil,
            isEnabled: true,
            action: { open(entry) }
        )
        .modifier(EntryContextMenu(
            entry: entry,
            isWatched: progress?.isCompleted == true,
            toggleWatched: toggleWatched,
            showInFinder: showInFinder,
            moveToTrash: moveToTrash
        ))
    }

    private func onlineMetadata(for entry: BrowserEntry) -> OnlineMetadata? {
        guard entry.kind == .video else { return nil }
        return library.onlineMetadata(for: entry.url)
    }

    /// What the work is called, in preference to what the file is called. A
    /// release name is a description of an encode; the catalogue's title is the
    /// thing somebody meant to watch.
    private func title(for entry: BrowserEntry) -> String {
        onlineMetadata(for: entry)?.displayTitle ?? entry.name
    }

    /// The line under a card's title, or nil for none. The running time is on
    /// the picture and an episode's series and number are in its title, so
    /// all that is left for a video is a film's year.
    private func subtitle(for entry: BrowserEntry) -> String? {
        switch entry.kind {
        case .folder:
            return "Folder"
        case .video:
            return onlineMetadata(for: entry)?.detailLine
        }
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
            }
        }

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
            player.play(
                entry.url,
                from: library.visibleVideos,
                directory: library.currentDirectory
            )
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

        // One video on its own is the same ask as File ▸ Open Video: it gets a
        // window of its own and a place in Open Recent, rather than taking over
        // the browser and its queue. Several at once are a queue already, and
        // stay one.
        if videos.count == 1, let video = videos.first {
            openStandalone(video)
        } else if let video = videos.first {
            player.play(video, from: videos, directory: video.deletingLastPathComponent())
        }
        return added || !videos.isEmpty
    }

    /// Opens `video` in a window of its own, quieting this window first so the
    /// two are not heard at once. A window already playing the dropped file is
    /// left alone: `FilePlayerWindows` raises it rather than opening a second.
    private func openStandalone(_ video: URL) {
        if appModel.playerState.currentURL?.standardizedFileURL != video.standardizedFileURL {
            appModel.yieldPlayback()
        }
        FilePlayerWindows.shared.open(video)
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
    let subtitle: String?
    let source: CoverSource
    let artworkPath: String?
    let isFolder: Bool
    let progress: PlaybackProgress?
    /// The running time, shown on the picture.
    let durationText: String?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                MediaCover(
                    source: source,
                    artworkPath: artworkPath,
                    isFolder: isFolder,
                    progress: progress,
                    durationText: durationText
                )
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.1))
                    }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LibraryItemButtonStyle())
        .disabled(!isEnabled)
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
    var durationText: String?

    /// How far the running-time pill sits in from the cover's trailing and
    /// bottom edges.
    static let badgeInset: CGFloat = 8

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
            // The picture fills the shape as an overlay so it never sizes the
            // cover: filled straight into the stack, a frame wider than 16:9
            // (a 2:1 or scope film) would widen the cover, and the grid cell
            // with it, past its column.
            Rectangle()
                .fill(placeholderFill)
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }

            if image == nil {
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
                bottomRow
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

    /// How much of the pill to fill, as far as playback has got, or nil — no
    /// fill — for a video not started or already watched.
    private var progressFraction: Double? {
        guard let progress, !progress.isCompleted else { return nil }
        return progress.fraction > 0 ? progress.fraction : nil
    }

    private var isWatched: Bool { progress?.isCompleted == true }

    /// The running time in a pill of glass in the bottom-trailing corner. It
    /// also says how far in the video is, with a lighter wash across it from
    /// the leading edge as far as playback has got, and holds a check once
    /// the video is watched.
    @ViewBuilder
    private var bottomRow: some View {
        if durationText != nil || isWatched || progressFraction != nil {
            durationPill
                .padding(Self.badgeInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private var durationPill: some View {
        HStack(spacing: 3) {
            if isWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            if let durationText {
                Text(durationText)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        // A pill with nothing to say still needs room for its wash.
        .frame(minWidth: 36, minHeight: 18)
        .background {
            if let fraction = progressFraction {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(.white.opacity(0.42))
                        .frame(width: proxy.size.width * fraction)
                }
                .clipShape(Capsule())
            }
        }
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: Capsule())
        .environment(\.colorScheme, .dark)
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
    let isWatched: Bool
    let toggleWatched: (BrowserEntry) -> Void
    let showInFinder: (BrowserEntry) -> Void
    let moveToTrash: (BrowserEntry) -> Void

    func body(content: Content) -> some View {
        if entry.kind == .folder {
            content
        } else {
            content.contextMenu {
                Button(isWatched ? "Mark as Unwatched" : "Mark as Watched") { toggleWatched(entry) }
                Divider()
                Button("Show in Finder") { showInFinder(entry) }
                Divider()
                Button("Move to Trash", role: .destructive) { moveToTrash(entry) }
            }
        }
    }
}

/// How far in from the window's trailing edge the toolbar's trailing items
/// reach — the sort and options menus and the search field — for a header
/// drawn under the title bar to stop short of.
///
/// The toolbar knows nothing of that header, so it never shrinks the search
/// field to make room for the title; at a narrow width the two would overlap.
/// Measured from the toolbar's own views rather than assumed, because the
/// search field's width is the toolbar's to decide and changes with the
/// window's.
///
/// It also reports how far into the header the Back button reaches, or nil
/// when there is none, for the title to start past it.
struct TrailingToolbarWidthReader: NSViewRepresentable {
    static let backID = "Owl.Back"

    let minimum: CGFloat
    let onChange: (CGFloat) -> Void
    let onBackButtonChange: (CGFloat?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.minimum = minimum
        view.onChange = onChange
        view.onBackButtonChange = onBackButtonChange
        view.scheduleMeasurement()
    }

    final class ReaderView: NSView {
        static let searchFieldWidth: CGFloat = 220

        var minimum: CGFloat = 0
        var onChange: ((CGFloat) -> Void)?
        var onBackButtonChange: ((CGFloat?) -> Void)?
        private var reported: CGFloat?
        private var reportedBack: CGFloat??
        private var measurementScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowChanged), name: name, object: window
                )
            }
            scheduleMeasurement()
        }

        @objc private func windowChanged() {
            scheduleMeasurement()
        }

        /// After the toolbar has laid itself out for whatever just changed.
        func scheduleMeasurement() {
            guard !measurementScheduled else { return }
            measurementScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                measurementScheduled = false
                measure()
            }
        }

        private func measure() {
            guard let window, let toolbar = window.toolbar else { return }
            // Left to itself the search field takes all the room the toolbar
            // has, which at a narrow width is all of the header's: the
            // folder's name would be squeezed out to make a field for a few
            // words wider than it needs. Finder's is about this wide. The
            // preferred width alone does not hold it — the toolbar stretches
            // the field past it — so the field is held to it too; the width
            // having been set marks an item already seen to.
            for case let item as NSSearchToolbarItem in toolbar.items
            where item.preferredWidthForSearchField != Self.searchFieldWidth {
                item.preferredWidthForSearchField = Self.searchFieldWidth
                let limit = item.searchField.widthAnchor.constraint(
                    lessThanOrEqualToConstant: Self.searchFieldWidth
                )
                limit.isActive = true
            }
            let header = convert(bounds, to: nil)
            let back = toolbar.items.first {
                $0.itemIdentifier.rawValue == TrailingToolbarWidthReader.backID
            }?.view.flatMap { view -> CGFloat? in
                guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
                let frame = view.convert(view.bounds, to: nil)
                guard frame.width > 0, frame.maxX > header.minX else { return nil }
                return (frame.maxX - header.minX).rounded()
            }
            if reportedBack != .some(back) {
                reportedBack = .some(back)
                onBackButtonChange?(back)
            }
            // Only what sits over this header's trailing half: Back, and with
            // the sidebar collapsed Add Folder and the sidebar toggle, sit
            // over its leading end, and counting them squeezed the title out.
            let leadingEdges = toolbar.items.compactMap { item -> CGFloat? in
                guard item.itemIdentifier.rawValue != TrailingToolbarWidthReader.backID,
                      let view = item.view, view.window === window, !view.isHiddenOrHasHiddenAncestor
                else { return nil }
                let frame = view.convert(view.bounds, to: nil)
                guard frame.width > 0, frame.minX > header.midX, frame.minX < header.maxX
                else { return nil }
                return frame.minX
            }
            guard let leading = leadingEdges.min() else { return }
            // A gap between the title's last letter and the first control.
            let width = max(minimum, (header.maxX - leading + 12).rounded())
            guard width != reported else { return }
            reported = width
            onChange?(width)
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
