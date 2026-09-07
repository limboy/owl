import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let view: OwlVideoView
    let isActive: Bool

    init(view: OwlVideoView, isActive: Bool = true) {
        self.view = view
        self.isActive = isActive
    }

    func makeNSView(context: Context) -> VideoSurfaceHostView {
        VideoSurfaceHostView()
    }

    func updateNSView(_ nsView: VideoSurfaceHostView, context: Context) {
        guard isActive else { return }
        nsView.attach(view)
    }
}

final class VideoSurfaceHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ videoView: OwlVideoView) {
        if videoView.superview !== self {
            // A retry builds a fresh engine and video view. Drop whichever
            // view was here before, or the detached one stays in the hierarchy
            // underneath the new one and keeps it alive.
            for subview in subviews where subview !== videoView {
                subview.removeFromSuperview()
            }
            videoView.removeFromSuperview()
            videoView.frame = bounds
            videoView.autoresizingMask = [.width, .height]
            addSubview(videoView)
            videoView.needsDisplay = true
        }

        if videoView.frame != bounds {
            videoView.frame = bounds
            videoView.needsDisplay = true
        }
    }
}
