import AppKit
import SwiftUI

struct TimelinePreviewScrubber: View {
    let currentTime: Double
    let duration: Double
    let url: URL?
    @Binding var isSeeking: Bool
    @Binding var seekValue: Double
    let onCommit: (Double) -> Void

    @State private var previewTime: Double?
    @State private var previewImage: NSImage?
    @State private var previewsUnavailable = false
    @State private var previewAspectRatio: CGFloat?
    @State private var thumbnailTask: Task<Void, Never>?
    @State private var committedSeekTarget: Double?
    @State private var seekCompletionTask: Task<Void, Never>?

    private let thumbnailProvider = MediaThumbnailProvider.shared

    /// The box the preview frame is fitted into. Big enough to read the shot at
    /// a glance rather than having to look for it. Frames are extracted at
    /// twice this width so the card stays sharp on a Retina display.
    ///
    /// The frame keeps the file's own shape inside the box, so the familiar
    /// 16:9 card fills the full width while a taller file gives up width
    /// instead of towering over the controls.
    private static let previewFrameBounds = CGSize(width: 240, height: 180)

    /// What the card is shaped like until a frame says otherwise.
    private static let defaultAspectRatio: CGFloat = 16.0 / 9.0

    /// The time label, the spacing above it, and the card padding, which sit
    /// below the frame and so push the whole card further up.
    private static let previewCardChrome: CGFloat = 27

    private var previewFrameSize: CGSize {
        let ratio = previewAspectRatio ?? Self.defaultAspectRatio
        let bounds = Self.previewFrameBounds
        let height = min(bounds.height, bounds.width / ratio)
        return CGSize(width: (height * ratio).rounded(), height: height.rounded())
    }

    /// Where the card's centre goes, keeping a constant gap above the bar
    /// whatever size the frame is.
    private var previewCardCenterY: CGFloat {
        -((previewFrameSize.height + Self.previewCardChrome) / 2 + 9)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = ratio(for: isSeeking ? seekValue : currentTime)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.4))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * progress, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 2.5, y: 1)
                    .offset(x: max(0, min(width - 12, width * progress - 6)))

                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !isSeeking else { return }
                            updatePreview(
                                at: location.x,
                                width: width,
                                updatesSeekValue: false
                            )
                        case .ended:
                            clearPreview()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if committedSeekTarget != nil {
                                    seekCompletionTask?.cancel()
                                    committedSeekTarget = nil
                                }
                                updatePreview(at: value.location.x, width: width)
                                if !isSeeking {
                                    isSeeking = true
                                }
                            }
                            .onEnded { value in
                                let destination = updatePreview(
                                    at: value.location.x,
                                    width: width
                                ) ?? seekValue
                                committedSeekTarget = destination
                                onCommit(destination)
                                scheduleSeekCompletionFallback()
                                clearPreview()
                            }
                    )

                if let previewTime {
                    // Half the card width keeps it inside the bar at either
                    // end instead of hanging off the edge of the controls.
                    let inset = previewFrameSize.width / 2 + 5
                    previewCard(time: previewTime)
                        .position(
                            x: min(
                                max(width * ratio(for: previewTime), inset),
                                max(width - inset, inset)
                            ),
                            y: previewCardCenterY
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        // GeometryReader expands to the proposed height unless it is bounded.
        // Keep the scrubber compact so the surrounding control capsule does
        // not grow to fill the entire player.
        .frame(minWidth: 80, minHeight: 28, maxHeight: 28)
        .onAppear { prepareFilmstrip() }
        .onDisappear {
            clearPreview()
            seekCompletionTask?.cancel()
        }
        .onChange(of: url) { _, _ in
            clearPreview()
            previewsUnavailable = false
            // The next file has its own shape; the card learns it from the
            // first frame of that file rather than keeping this one's.
            previewAspectRatio = nil
            prepareFilmstrip()
        }
        .onChange(of: duration) { _, _ in
            clearPreview()
            // The duration only settles once the file is open, which is the
            // first moment the strip knows how far apart its frames go.
            prepareFilmstrip()
        }
        .onChange(of: currentTime) { _, newTime in
            guard let target = committedSeekTarget else { return }
            guard abs(newTime - target) <= 0.5 else { return }
            finishCommittedSeek()
        }
        .opacity(duration > 0 ? 1 : 0.55)
        .allowsHitTesting(duration > 0)
    }

    private func ratio(for time: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    @discardableResult
    private func updatePreview(
        at x: CGFloat,
        width: CGFloat,
        updatesSeekValue: Bool = true
    ) -> Double? {
        guard duration > 0, let url else { return nil }
        let time = min(max(Double(x / width) * duration, 0), duration)
        if updatesSeekValue {
            seekValue = time
        }
        previewTime = time

        // The filmstrip covers the whole file, so this normally hits and the
        // preview tracks the pointer with no delay at all. Extracting a frame
        // costs a process launch, which the next pointer move would cancel
        // before it ever finished.
        if let ready = thumbnailProvider.cachedImage(for: url, at: time) {
            thumbnailTask?.cancel()
            thumbnailTask = nil
            previewsUnavailable = false
            previewImage = ready
            adoptAspectRatio(from: ready)
            return time
        }

        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor in
            let image = await thumbnailProvider.image(for: url, at: time)
            guard !Task.isCancelled else { return }
            // Keep the previous frame on screen when a request comes back
            // empty so the card does not flicker mid-scrub.
            previewsUnavailable = image == nil
            if let image {
                previewImage = image
                adoptAspectRatio(from: image)
            }
        }
        return time
    }

    /// Shapes the card like the file it is previewing. The first frame decides
    /// it and the rest of the file keeps it, so the card cannot change size
    /// under the pointer when a frame comes back a pixel row shorter.
    private func adoptAspectRatio(from image: NSImage) {
        guard previewAspectRatio == nil, let ratio = Self.aspectRatio(of: image) else {
            return
        }
        previewAspectRatio = ratio
    }

    static func aspectRatio(of image: NSImage) -> CGFloat? {
        var size = image.size
        // Pixel dimensions where the representation reports them, so a frame
        // carrying an unusual DPI is still measured by its own shape.
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard size.width > 0, size.height > 0 else { return nil }
        // Anything past these is a frame that arrived wrong rather than a video
        // anyone shot, and letting it through would deform the card.
        return min(max(size.width / size.height, 0.2), 5)
    }

    private func prepareFilmstrip() {
        guard let url, duration > 0 else { return }
        thumbnailProvider.prepare(for: url, duration: duration)
    }

    private func clearPreview() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        previewTime = nil
        previewImage = nil
    }

    private func scheduleSeekCompletionFallback() {
        seekCompletionTask?.cancel()
        seekCompletionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            finishCommittedSeek()
        }
    }

    private func finishCommittedSeek() {
        seekCompletionTask?.cancel()
        seekCompletionTask = nil
        committedSeekTarget = nil
        isSeeking = false
    }

    @ViewBuilder
    private func previewCard(time: Double) -> some View {
        VStack(spacing: 4) {
            if previewImage != nil || !previewsUnavailable {
                ZStack {
                    // A placeholder of the same size keeps the card from
                    // resizing while the first frame is being extracted.
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.12))
                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(
                    width: previewFrameSize.width,
                    height: previewFrameSize.height
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text(timeString(time))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(5)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
