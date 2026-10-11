import AppKit
import CMPVShim

/// Software frames cross Quick Look's remote-view boundary reliably; an
/// NSOpenGLView drawable belongs to the extension process, not Finder.
final class PreviewRenderer: @unchecked Sendable {
    /// Longest edge of a rendered frame, in pixels. Large enough to stay sharp
    /// in a typical Quick Look panel, small enough to decode and copy at 30 fps.
    static let longEdge = 1280

    private let queue = DispatchQueue(label: "me.limboy.owl.quicklook.frames", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let engine: MPVPlayerEngine
    private var timer: DispatchSourceTimer?
    private var active = false
    private let deliveryLock = NSLock()
    private var deliveryPending = false
    // Guarded by `queue`.
    private var width = PreviewRenderer.longEdge
    private var height = PreviewRenderer.longEdge * 9 / 16
    private var needsRedraw = false

    init(engine: MPVPlayerEngine) throws {
        self.engine = engine
        queue.setSpecific(key: queueKey, value: true)
        let result = queue.sync { mvp_mpv_initialize_software_renderer(engine.rawHandle) }
        guard result >= 0 else {
            throw NSError(domain: "OwlQuickLook", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "Could not create the video preview renderer."
            ])
        }
        active = true
    }

    /// Match the frame to the video so mpv doesn't letterbox inside it. A
    /// paused preview is redrawn at the new size on the next tick.
    func setAspectRatio(_ aspect: Double) {
        guard aspect.isFinite, aspect > 0 else { return }
        let long = Double(Self.longEdge)
        let width = Self.even(aspect >= 1 ? long : long * aspect)
        let height = Self.even(aspect >= 1 ? long / aspect : long)
        queue.async { [self] in
            guard width != self.width || height != self.height else { return }
            self.width = width
            self.height = height
            needsRedraw = true
        }
    }

    func start(deliver: @escaping @MainActor @Sendable (CGImage) -> Void) {
        queue.sync {
            guard active, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in
                guard let self, active else { return }
                // Bound delivery when Finder's main thread is busy.
                guard !deliveryLock.withLock({ deliveryPending }) else { return }
                guard let image = renderFrame() else { return }
                deliveryLock.withLock { deliveryPending = true }
                Task { @MainActor [weak self] in
                    deliver(image)
                    self?.deliveryLock.withLock { self?.deliveryPending = false }
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    private func renderFrame() -> CGImage? {
        let stride = ((width * 4 + 63) / 64) * 64
        let byteCount = stride * height
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        let status = mvp_mpv_render_software(engine.rawHandle, pixels, Int32(width), Int32(height), stride, needsRedraw)
        guard status > 0 else {
            pixels.deallocate()
            return nil
        }
        needsRedraw = false
        // Hand the buffer to the image instead of copying it every frame.
        let data = Data(bytesNoCopy: pixels, count: byteCount, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Must precede engine.shutdown(), including when replacing a preview.
    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        guard active else { return }
        active = false
        timer?.cancel()
        timer = nil
        mvp_mpv_destroy_renderer(engine.rawHandle)
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int(value.rounded()) & ~1)
    }

    deinit { stop() }
}
