import AppKit
import Combine
import Quartz
import OSLog

/// A QuickTime-style player with a floating control bar in Quick Look and
/// a single centered playback button in Finder's preview pane.
@MainActor
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private let state = PlayerState()
    private var engine: MPVPlayerEngine?
    private var renderer: PreviewRenderer?
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = 0
    private var securityScopedURL: URL?

    private let surface = PreviewSurfaceView()
    private let bar = NSGlassEffectView()
    private let thumbnailControls = NSGlassEffectView()
    private let thumbnailPlay = PreviewViewController.symbolButton("play.fill", label: "Play", size: 22)
    private let play = PreviewViewController.symbolButton("pause.fill", label: "Pause", size: 22)
    private let elapsed = PreviewViewController.timeLabel()
    private let seek = PreviewScrubber(knobDiameter: 24, label: "Playback position")
    private let remaining = PreviewViewController.timeLabel()
    private let mute = PreviewViewController.symbolButton("speaker.wave.2.fill", label: "Mute", size: 16)
    private let volume = PreviewScrubber(knobDiameter: 14, label: "Volume")
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")

    private var isScrubbing = false
    /// Whether the video was paused when the knob was taken hold of, to go
    /// back to once it is let go.
    private var wasPausedBeforeScrubbing: Bool?
    private var isPointerOverBar = false
    private var hideControls: DispatchWorkItem?
    private var appliedAspectRatio: Double?
    private var pendingCompletion: (@Sendable (Error?) -> Void)?

    override func loadView() {
        let root = PreviewRootView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.onPointerActivity = { [weak self] in self?.revealControls() }
        root.onPointerExit = { [weak self] in self?.scheduleHideControls(after: 0.3) }
        view = root
        preferredContentSize = root.frame.size

        surface.onClick = { [weak self] in self?.togglePlayback() }

        play.target = self
        play.action = #selector(togglePlayback)
        thumbnailPlay.target = self
        thumbnailPlay.action = #selector(togglePlayback)
        seek.onChange = { [weak self] value, isFinal in self?.seekPlayback(to: value, isFinal: isFinal) }
        mute.target = self
        mute.action = #selector(toggleMute)
        volume.maxValue = 100
        volume.value = 100
        volume.onChange = { [weak self] value, _ in self?.changeVolume(to: value) }

        bar.cornerRadius = 22
        let content = NSView()
        bar.contentView = content
        thumbnailControls.cornerRadius = 26
        thumbnailControls.contentView = thumbnailPlay
        bar.isHidden = true
        thumbnailControls.isHidden = true
        let tracking = PreviewBarTrackingView()
        tracking.onHoverChange = { [weak self] inside in
            self?.isPointerOverBar = inside
            if inside { self?.revealControls() }
        }

        let row = NSStackView(views: [play, elapsed, seek, remaining, mute, volume])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.setCustomSpacing(20, after: play)
        row.setCustomSpacing(14, after: elapsed)
        row.setCustomSpacing(14, after: seek)
        row.setCustomSpacing(18, after: remaining)
        row.setCustomSpacing(6, after: mute)
        // In a narrow (portrait) panel, give up volume before the scrubber.
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 500), for: volume)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 600), for: mute)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 800), for: remaining)
        seek.setContentHuggingPriority(.defaultLow, for: .horizontal)
        seek.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 13)
        message.isHidden = true

        for child in [surface, spinner, message, bar, thumbnailControls] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        for child in [tracking, row] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: 48),
            tracking.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tracking.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tracking.topAnchor.constraint(equalTo: content.topAnchor),
            tracking.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            row.heightAnchor.constraint(equalTo: content.heightAnchor),
            seek.heightAnchor.constraint(equalTo: row.heightAnchor),
            volume.heightAnchor.constraint(equalTo: row.heightAnchor),
            volume.widthAnchor.constraint(equalToConstant: 64),
            seek.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            thumbnailControls.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            thumbnailControls.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            thumbnailControls.widthAnchor.constraint(equalToConstant: 52),
            thumbnailControls.heightAnchor.constraint(equalToConstant: 52),

            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            message.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48)
        ])

        state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateControls() }
        }.store(in: &subscriptions)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping @Sendable (Error?) -> Void) {
        _ = view
        tearDown()
        generation += 1
        let currentGeneration = generation
        if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
        do {
            // ExtensionKit may host us in a system executable. Resolve the
            // runtime from our code bundle, never Bundle.main or argv[0].
            let contents = Bundle(for: Self.self).bundleURL
                .deletingLastPathComponent().deletingLastPathComponent()
            let library = contents.appendingPathComponent("Frameworks/libmpv.2.dylib")
            let engine = try MPVPlayerEngine(state: state, preview: true, libraryURL: library)
            self.engine = engine
            let renderer = try PreviewRenderer(engine: engine)
            self.renderer = renderer
            renderer.start { [weak self] image in
                guard let self, self.generation == currentGeneration, self.renderer != nil else { return }
                self.surface.image = image
            }
            engine.load(url, startsPaused: true)
            revealControls()
            updateControls()
            // Quick Look sizes the panel from preferredContentSize when we
            // complete, so wait briefly for the video's shape; playback starts
            // as the panel appears. Decoding errors appear in the view rather
            // than failing the preview.
            pendingCompletion = handler
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, generation == currentGeneration else { return }
                completePreparation()
            }
        } catch {
            Logger(subsystem: "me.limboy.owl.preview", category: "decoder").error("Preview failed: \(error.localizedDescription, privacy: .public)")
            tearDown()
            handler(error)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        tearDown()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateControlsPresentation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateControlsPresentation()
    }

    private func completePreparation(startingPlayback: Bool = true) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        if startingPlayback, state.errorMessage == nil, isInQuickLookPanel { engine?.setPaused(false) }
        completion(nil)
    }

    /// Whether this is the Space-bar panel rather than Finder's preview
    /// column or pane, which only shows a still until asked to play.
    ///
    /// Both host the same extension in the same kind of window, and nothing
    /// says which is which. The panel, though, takes the size asked for in
    /// `preferredContentSize`, while Finder's preview keeps the shape of its
    /// column whatever the video's.
    private var isInQuickLookPanel: Bool {
        guard let size = view.window?.frame.size else { return false }
        return abs(size.width - preferredContentSize.width) < 2
            && abs(size.height - preferredContentSize.height) < 2
    }

    private func tearDown() {
        completePreparation(startingPlayback: false)
        hideControls?.cancel()
        hideControls = nil
        renderer?.stop()
        renderer = nil
        engine?.shutdown()
        engine = nil
        surface.image = nil
        appliedAspectRatio = nil
        isScrubbing = false
        wasPausedBeforeScrubbing = nil
        if let url = securityScopedURL { url.stopAccessingSecurityScopedResource() }
        securityScopedURL = nil
    }

    // MARK: - Actions

    @objc private func togglePlayback() {
        guard let engine, !state.isLoading, state.errorMessage == nil else { return }
        // Like QuickTime, playing a finished video starts it over.
        if state.isPaused, state.duration > 0, state.currentTime >= state.duration - 0.25 {
            engine.seek(to: 0)
            engine.setPaused(false)
        } else {
            engine.togglePause()
        }
        revealControls()
    }

    /// Playback pauses while the knob is held, so the picture follows it
    /// frame by frame, and picks up again where it was let go if it was
    /// playing before.
    private func seekPlayback(to seconds: Double, isFinal: Bool) {
        isScrubbing = !isFinal
        if !isFinal, wasPausedBeforeScrubbing == nil {
            wasPausedBeforeScrubbing = state.isPaused
            engine?.setPaused(true)
        }
        engine?.seek(to: seconds)
        if isFinal, let wasPaused = wasPausedBeforeScrubbing {
            wasPausedBeforeScrubbing = nil
            engine?.setPaused(wasPaused)
        }
        elapsed.stringValue = Self.time(seconds)
        remaining.stringValue = "-" + Self.time(state.duration - seconds)
        revealControls()
    }

    @objc private func toggleMute() {
        engine?.toggleMute()
        revealControls()
    }

    private func changeVolume(to value: Double) {
        engine?.setVolume(value)
        if state.isMuted, value > 0 { engine?.toggleMute() }
        revealControls()
    }

    // MARK: - State

    private func updateControls() {
        let ready = engine != nil && !state.isLoading && state.errorMessage == nil
        play.isEnabled = ready
        thumbnailPlay.isEnabled = ready
        Self.setSymbol(play, state.isPaused ? "play.fill" : "pause.fill",
                       label: state.isPaused ? "Play" : "Pause")
        Self.setSymbol(thumbnailPlay, state.isPaused ? "play.fill" : "pause.fill",
                       label: state.isPaused ? "Play" : "Pause")
        Self.setSymbol(mute, state.isMuted || state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       label: state.isMuted ? "Unmute" : "Mute")
        seek.isEnabled = ready && state.duration > 0
        seek.maxValue = max(1, state.duration)
        if !isScrubbing {
            seek.value = state.currentTime
            elapsed.stringValue = Self.time(state.currentTime)
            remaining.stringValue = "-" + Self.time(state.duration - state.currentTime)
        }
        if !volume.isTracking { volume.value = state.isMuted ? 0 : state.volume }

        if state.isLoading && engine != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        message.stringValue = state.errorMessage ?? ""
        message.isHidden = state.errorMessage == nil

        if let aspect = state.videoAspectRatio, aspect.isFinite, aspect > 0, aspect != appliedAspectRatio {
            appliedAspectRatio = aspect
            renderer?.setAspectRatio(aspect)
            preferredContentSize = Self.panelSize(for: aspect)
        }
        if appliedAspectRatio != nil || state.errorMessage != nil { completePreparation() }
        updateControlsPresentation()
        if state.isPaused { revealControls() } else if hideControls == nil, bar.alphaValue > 0 { scheduleHideControls(after: 2) }
    }

    // MARK: - Controls visibility

    private func updateControlsPresentation() {
        let isPanel = isInQuickLookPanel
        bar.isHidden = !isPanel || state.errorMessage != nil
        thumbnailControls.isHidden = isPanel || engine == nil || state.isLoading || state.errorMessage != nil
    }

    private func revealControls() {
        hideControls?.cancel()
        hideControls = nil
        if bar.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                bar.animator().alphaValue = 1
                thumbnailControls.animator().alphaValue = 1
            }
        }
        if !state.isPaused { scheduleHideControls(after: 2.5) }
    }

    private func scheduleHideControls(after delay: TimeInterval) {
        hideControls?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            hideControls = nil
            guard !state.isPaused, !isPointerOverBar, !isScrubbing, state.errorMessage == nil else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.bar.animator().alphaValue = 0
                self.thumbnailControls.animator().alphaValue = 0
            }
        }
        hideControls = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Helpers

    /// Fit the video inside a comfortable panel, as QuickTime's preview does.
    private static func panelSize(for aspect: Double) -> NSSize {
        let maxWidth = 960.0, maxHeight = 720.0
        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private static func symbolButton(_ name: String, label: String, size: CGFloat) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        button.symbolConfiguration = .init(pointSize: size, weight: .regular)
        setSymbol(button, name, label: label)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private static func setSymbol(_ button: NSButton, _ name: String, label: String) {
        guard button.identifier?.rawValue != name else { return }
        button.identifier = NSUserInterfaceItemIdentifier(name)
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        button.setAccessibilityLabel(label)
    }

    private static func timeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "00:00")
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.75)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    isolated deinit {
        tearDown()
    }
}

/// Reports pointer movement anywhere in the preview so the controls can return.
private final class PreviewRootView: NSView {
    var onPointerActivity: (() -> Void)?
    var onPointerExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onPointerActivity?() }
    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }
}

/// Keeps the bar up while the pointer rests on it.
private final class PreviewBarTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Shows frames aspect-fit on black; a click toggles playback.
private final class PreviewSurfaceView: NSView {
    var onClick: (() -> Void)?
    var image: CGImage? {
        didSet { layer?.contents = image }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .trilinear
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    // Claim mouseDown so the panel doesn't start a window drag from it.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        // Finder's remote view can report a click count of 0.
        if event.clickCount < 2 { onClick?() }
    }
}

/// QuickTime's scrubber: a thin track, white where it has played, and a
/// large white knob.
private final class PreviewScrubber: NSView {
    var onChange: ((Double, Bool) -> Void)?
    var maxValue: Double = 1 { didSet { if maxValue != oldValue { needsDisplay = true } } }
    var value: Double = 0 {
        didSet { if value != oldValue { needsDisplay = true; setAccessibilityValue(value) } }
    }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    private(set) var isTracking = false
    private let knobDiameter: CGFloat
    private let trackHeight: CGFloat = 4

    init(knobDiameter: CGFloat, label: String) {
        self.knobDiameter = knobDiameter
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: knobDiameter + 4) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var fraction: CGFloat {
        maxValue > 0 ? CGFloat(min(max(value / maxValue, 0), 1)) : 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = knobDiameter / 2
        let track = NSRect(x: inset, y: bounds.midY - trackHeight / 2,
                           width: max(0, bounds.width - knobDiameter), height: trackHeight)
        let knobX = track.minX + track.width * fraction
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        var played = track
        played.size.width = knobX - track.minX
        NSColor.white.withAlphaComponent(isEnabled ? 0.95 : 0.5).setFill()
        NSBezierPath(roundedRect: played, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        guard isEnabled else { return }
        let knob = NSRect(x: knobX - knobDiameter / 2, y: bounds.midY - knobDiameter / 2,
                          width: knobDiameter, height: knobDiameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTracking = true
        update(with: event, isFinal: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        update(with: event, isFinal: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        update(with: event, isFinal: true)
    }

    private func update(with event: NSEvent, isFinal: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let width = max(1, bounds.width - knobDiameter)
        let fraction = min(max((point.x - knobDiameter / 2) / width, 0), 1)
        value = Double(fraction) * maxValue
        onChange?(value, isFinal)
    }
}
