import AppKit
import Combine
import Quartz
import OSLog

/// A QuickTime-style player: the picture fills the panel and a translucent
/// control bar floats over it, fading out while the video plays untouched.
@MainActor
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private let state = PlayerState()
    private var engine: MPVPlayerEngine?
    private var renderer: PreviewRenderer?
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = 0
    private var securityScopedURL: URL?

    private let surface = PreviewSurfaceView()
    private let bar = NSVisualEffectView()
    private let play = PreviewViewController.symbolButton("play.fill", label: "Play")
    private let elapsed = PreviewViewController.timeLabel()
    private let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let remaining = PreviewViewController.timeLabel()
    private let mute = PreviewViewController.symbolButton("speaker.wave.2.fill", label: "Mute")
    private let volume = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")

    private var isScrubbing = false
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
        seek.target = self
        seek.action = #selector(seekPlayback)
        seek.isContinuous = true
        seek.controlSize = .small
        seek.setAccessibilityLabel("Playback position")
        mute.target = self
        mute.action = #selector(toggleMute)
        volume.target = self
        volume.action = #selector(changeVolume)
        volume.controlSize = .small
        volume.setAccessibilityLabel("Volume")

        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.layer?.cornerCurve = .continuous
        bar.layer?.masksToBounds = true
        let tracking = PreviewBarTrackingView()
        tracking.onHoverChange = { [weak self] inside in
            self?.isPointerOverBar = inside
            if inside { self?.revealControls() }
        }

        let row = NSStackView(views: [play, elapsed, seek, remaining, mute, volume])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(14, after: play)
        row.setCustomSpacing(16, after: remaining)
        row.setCustomSpacing(4, after: mute)
        // In a narrow (portrait) panel, give up volume before the scrubber.
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 600), for: volume)
        row.setVisibilityPriority(.detachOnlyIfNecessary, for: mute)
        seek.setContentHuggingPriority(.defaultLow, for: .horizontal)
        seek.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 13)
        message.isHidden = true

        for child in [surface, spinner, message, bar] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        for child in [tracking, row] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(child)
        }
        let barWidth = bar.widthAnchor.constraint(equalToConstant: 560)
        // Below the hosting window's own size constraints, so a narrow panel
        // shrinks the bar instead of the bar widening the panel.
        barWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            barWidth,
            bar.heightAnchor.constraint(equalToConstant: 40),
            tracking.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            tracking.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            tracking.topAnchor.constraint(equalTo: bar.topAnchor),
            tracking.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            volume.widthAnchor.constraint(equalToConstant: 64),
            seek.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

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
            // complete, so wait briefly for the video's shape. Decoding
            // errors appear in the view rather than failing the preview.
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

    private func completePreparation() {
        pendingCompletion?(nil)
        pendingCompletion = nil
    }

    private func tearDown() {
        completePreparation()
        hideControls?.cancel()
        hideControls = nil
        renderer?.stop()
        renderer = nil
        engine?.shutdown()
        engine = nil
        surface.image = nil
        appliedAspectRatio = nil
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

    @objc private func seekPlayback() {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged: isScrubbing = true
        default: isScrubbing = false
        }
        engine?.seek(to: seek.doubleValue)
        elapsed.stringValue = Self.time(seek.doubleValue)
        remaining.stringValue = "-" + Self.time(state.duration - seek.doubleValue)
        revealControls()
    }

    @objc private func toggleMute() {
        engine?.toggleMute()
        revealControls()
    }

    @objc private func changeVolume() {
        engine?.setVolume(volume.doubleValue)
        if state.isMuted, volume.doubleValue > 0 { engine?.toggleMute() }
        revealControls()
    }

    // MARK: - State

    private func updateControls() {
        let ready = engine != nil && !state.isLoading && state.errorMessage == nil
        play.isEnabled = ready
        Self.setSymbol(play, state.isPaused ? "play.fill" : "pause.fill",
                       label: state.isPaused ? "Play" : "Pause")
        Self.setSymbol(mute, state.isMuted || state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       label: state.isMuted ? "Unmute" : "Mute")
        seek.isEnabled = ready && state.duration > 0
        seek.maxValue = max(1, state.duration)
        if !isScrubbing {
            seek.doubleValue = state.currentTime
            elapsed.stringValue = Self.time(state.currentTime)
            remaining.stringValue = "-" + Self.time(state.duration - state.currentTime)
        }
        if volume.doubleValue != state.volume { volume.doubleValue = state.volume }

        if state.isLoading && engine != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        message.stringValue = state.errorMessage ?? ""
        message.isHidden = state.errorMessage == nil
        bar.isHidden = state.errorMessage != nil

        if let aspect = state.videoAspectRatio, aspect.isFinite, aspect > 0, aspect != appliedAspectRatio {
            appliedAspectRatio = aspect
            renderer?.setAspectRatio(aspect)
            preferredContentSize = Self.panelSize(for: aspect)
        }
        if appliedAspectRatio != nil || state.errorMessage != nil { completePreparation() }
        if state.isPaused { revealControls() } else if hideControls == nil, bar.alphaValue > 0 { scheduleHideControls(after: 2) }
    }

    // MARK: - Controls visibility

    private func revealControls() {
        hideControls?.cancel()
        hideControls = nil
        if bar.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                bar.animator().alphaValue = 1
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

    private static func symbolButton(_ name: String, label: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
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
        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
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
