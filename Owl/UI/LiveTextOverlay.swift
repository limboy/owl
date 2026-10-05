import AppKit
import SwiftUI
import VisionKit

/// What a paused picture is a picture of. The text found in it stops lining up
/// the moment any of this changes.
struct LiveTextFrame: Equatable {
    var url: URL?
    var time: Double
    /// Subtitles are drawn into the picture, so they are part of what is read.
    var subtitleID: Int64?
    var subtitleDelay: Double
}

/// Live Text over the paused picture: the text in it — a sign, a slide, a
/// subtitle — can be selected, copied, translated and looked up, as in a photo.
///
/// Only while paused, as in QuickTime and IINA 1.5. A moving picture's text
/// would be stale before it could be selected, and reading every frame would
/// cost far more than anything it found.
///
/// Laid over the whole video view, black bars included, because that is what
/// the picture it reads is: the view, as `OwlVideoView.snapshot` takes it. The
/// text it finds sits over the picture point for point without any working
/// out of where the video falls inside the view.
struct LiveTextOverlay: NSViewRepresentable {
    let videoView: OwlVideoView
    /// Whether there is a still picture to read: a file open, paused, loaded.
    let isActive: Bool
    let frame: LiveTextFrame
    /// Told when the Live Text button is switched on to pick out the text in
    /// the picture, and off again.
    var onHighlightChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> LiveTextOverlayView {
        LiveTextOverlayView()
    }

    func updateNSView(_ nsView: LiveTextOverlayView, context: Context) {
        nsView.onHighlightChange = onHighlightChange
        nsView.update(videoView: videoView, isActive: isActive, frame: frame)
    }

    static func dismantleNSView(_ nsView: LiveTextOverlayView, coordinator: Void) {
        nsView.clear()
    }
}

@MainActor
final class LiveTextOverlayView: NSView {
    /// How long a picture has to stay put before it is read. Pausing is
    /// followed a moment later by the last position landing, and a seek while
    /// paused by its frame; each would otherwise start a reading of its own
    /// only to throw away the last.
    private static let settleDelay: Duration = .milliseconds(300)

    private let overlay = ImageAnalysisOverlayView()
    private weak var videoView: OwlVideoView?
    private var isActive = false
    private var picture: LiveTextFrame?
    /// What the overlay's analysis was read from, or is being read from.
    private var analyzed: (picture: LiveTextFrame, size: NSSize)?
    private var analysisTask: Task<Void, Never>?
    var onHighlightChange: (Bool) -> Void = { _ in }
    /// Whether the Live Text button has the picture's text picked out.
    private var isHighlighting = false {
        didSet {
            guard oldValue != isHighlighting else { return }
            onHighlightChange(isHighlighting)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlay.delegate = self
        overlay.preferredInteractionTypes = .automatic
        // Clear of the controls along the bottom and the close button and
        // title along the top, so the Live Text button is never under either.
        overlay.supplementaryInterfaceContentInsets = NSEdgeInsets(
            top: 64, left: 16, bottom: 100, right: 16
        )
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Passes the pointer through to the player wherever there is nothing to
    /// read: always, before there is an analysis, and after it wherever the
    /// overlay itself has nothing under the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard overlay.analysis != nil else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The picture is redrawn at the new size, with its text somewhere
        // else in it.
        refresh()
    }

    func update(videoView: OwlVideoView, isActive: Bool, frame: LiveTextFrame) {
        self.videoView = videoView
        self.isActive = isActive
        picture = frame
        refresh()
    }

    func clear() {
        analysisTask?.cancel()
        analysisTask = nil
        analyzed = nil
        overlay.analysis = nil
        // Without an analysis there is no button, and nothing picked out;
        // the overlay does not say so itself.
        isHighlighting = false
    }

    private func refresh() {
        guard isActive, let picture, let videoView, bounds.width > 0, bounds.height > 0 else {
            clear()
            return
        }
        if let analyzed, analyzed.picture == picture, analyzed.size == bounds.size {
            return
        }
        clear()
        analyzed = (picture, bounds.size)
        analysisTask = Task { [weak self, weak videoView] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let videoView,
                  let image = await videoView.snapshot(),
                  !Task.isCancelled
            else { return }
            let configuration = ImageAnalyzer.Configuration([.text])
            guard let analysis = try? await ImageAnalyzer().analyze(
                image,
                orientation: .up,
                configuration: configuration
            ), !Task.isCancelled else { return }
            self?.overlay.analysis = analysis
        }
    }
}

extension LiveTextOverlayView: ImageAnalysisOverlayViewDelegate {
    func overlayView(
        _ overlayView: ImageAnalysisOverlayView,
        highlightSelectedItemsDidChange highlightSelectedItems: Bool
    ) {
        isHighlighting = highlightSelectedItems
    }
}
