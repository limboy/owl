import AppKit
import CMPVShim
import OpenGL.GL3

private func mpvOpenGLGetProcAddress(
    context: UnsafeMutableRawPointer?,
    name: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let name,
          let view = MPVCallbackContext<OwlVideoView>.target(of: context),
          let library = view.openGLLibrary
    else {
        return nil
    }
    return dlsym(library, name)
}

private func mpvRenderUpdate(context: UnsafeMutableRawPointer?) {
    MPVCallbackContext<MVOpenGLRenderWorker>.target(of: context)?.requestRender()
}

private final class MVOpenGLRenderWorker: @unchecked Sendable {
    private let engine: MPVPlayerEngine
    private let queue = DispatchQueue(
        label: "me.limboy.owl.opengl-render",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var context: NSOpenGLContext?
    private var isActive = false
    private var isVideoRenderingEnabled = false
    private var drawableSize = (width: 0, height: 0)
    private var presentedSize = (width: 0, height: 0)
    private var renderPending = false
    private var redrawPending = false
    private var renderScheduled = false
    private var completedFrames: UInt64 = 0

    var renderedFrameCount: UInt64 {
        stateLock.withLock { completedFrames }
    }

    init(engine: MPVPlayerEngine) {
        self.engine = engine
    }

    func activate(context: NSOpenGLContext) {
        stateLock.withLock {
            self.context = context
            isActive = true
        }
    }

    /// AppKit owns geometry; callbacks use this cached size without waiting
    /// for the main run loop to draw the view.
    func enqueue(width: Int, height: Int) {
        stateLock.withLock { drawableSize = (width, height) }
        requestRender(forceRedraw: true)
    }

    func requestRender(forceRedraw: Bool = false) {
        let shouldSchedule = stateLock.withLock {
            guard isActive, isVideoRenderingEnabled,
                  drawableSize.width > 0, drawableSize.height > 0
            else { return false }
            renderPending = true
            redrawPending = redrawPending || forceRedraw
            guard !renderScheduled else { return false }
            renderScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        // Never call mpv or hold stateLock while entering it from a callback.
        // A callback during rendering leaves one more pass for the worker.
        queue.async { [weak self] in
            self?.drainPendingRenders()
        }
    }

    func setVideoRenderingEnabled(_ enabled: Bool) {
        stateLock.withLock {
            isVideoRenderingEnabled = enabled
            if !enabled {
                renderPending = false
                redrawPending = false
            }
        }
        if !enabled {
            queue.async { [weak self] in
                self?.clearSurface()
            }
        }
    }

    func deactivate() {
        stateLock.withLock {
            isActive = false
            renderPending = false
            redrawPending = false
        }
        // Synchronous on purpose: the caller shuts the engine down as soon as
        // this returns, and mvp_mpv_destroy frees the render context too. A
        // render already in flight has to finish, and this one has to run,
        // before the handle goes away. Nothing on this queue waits on the main
        // thread, so blocking here cannot deadlock.
        queue.sync { [self] in
            guard let context = stateLock.withLock({ self.context }) else { return }
            context.lock()
            context.makeCurrentContext()
            mvp_mpv_destroy_renderer(engine.rawHandle)
            NSOpenGLContext.clearCurrentContext()
            context.unlock()
            stateLock.withLock {
                self.context = nil
            }
        }
    }

    /// Draws the picture at `width` × `height` pixels right away, on the
    /// calling thread, for a caller that holds the context's lock — the main
    /// thread, when AppKit has just resized the view's surface.
    ///
    /// Left to the worker, the resized surface would go on screen with the
    /// last picture in it, drawn at the old size and pinned to a corner, until
    /// the worker caught up; during a window's resize animation that is a
    /// picture jumping between sizes on every step.
    func renderResized(width: Int, height: Int) {
        let context = stateLock.withLock { () -> NSOpenGLContext? in
            drawableSize = (width, height)
            guard presentedSize.width != width || presentedSize.height != height else { return nil }
            guard isActive, isVideoRenderingEnabled, width > 0, height > 0 else { return nil }
            return self.context
        }
        guard let context else { return }
        let previous = NSOpenGLContext.current
        context.makeCurrentContext()
        // Resizing already runs on AppKit's animation clock. Waiting for a
        // second clock here blocks the main thread at every intermediate size.
        // Keep normal playback's swap interval after this synchronous redraw.
        var swapInterval: GLint = 0
        context.getValues(&swapInterval, for: .swapInterval)
        var immediateSwap: GLint = 0
        context.setValues(&immediateSwap, for: .swapInterval)
        defer {
            context.setValues(&swapInterval, for: .swapInterval)
            if let previous {
                previous.makeCurrentContext()
            } else {
                NSOpenGLContext.clearCurrentContext()
            }
        }
        draw(in: context, width: width, height: height, forceRedraw: true)
    }

    private func render(forceRedraw: Bool) {
        guard let context = stateLock.withLock({
            isActive && isVideoRenderingEnabled ? self.context : nil
        }) else { return }

        // Waited out with the context unlocked, not inside mpv's render call:
        // AppKit locks the same context on the main thread whenever the view's
        // geometry changes, and a render worker that held it through every
        // frame's wait left the main thread starved of it — a window resizing
        // under a 4K picture stalled, fullscreen's animation with it. The
        // question is asked under the lock, which is what keeps any two mpv
        // render calls from running at once.
        context.lock()
        context.makeCurrentContext()
        let wait = mvp_mpv_microseconds_until_next_frame(engine.rawHandle)
        NSOpenGLContext.clearCurrentContext()
        context.unlock()
        if wait > 0 {
            usleep(useconds_t(wait))
        }

        context.lock()
        defer { context.unlock() }
        // Read under the lock: the main thread changes the size and the
        // surface together while holding it.
        guard let size = stateLock.withLock({ () -> (width: Int, height: Int)? in
            guard isActive, isVideoRenderingEnabled,
                  drawableSize.width > 0, drawableSize.height > 0 else { return nil }
            return drawableSize
        }) else { return }
        context.makeCurrentContext()
        defer { NSOpenGLContext.clearCurrentContext() }
        draw(in: context, width: size.width, height: size.height, forceRedraw: forceRedraw)
    }

    /// With the context locked and current.
    private func draw(in context: NSOpenGLContext, width: Int, height: Int, forceRedraw: Bool) {
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        let result = mvp_mpv_render(
            engine.rawHandle,
            framebuffer,
            Int32(width),
            Int32(height),
            true,
            forceRedraw
        )
        guard result > 0 else { return }
        context.flushBuffer()
        mvp_mpv_report_swap(engine.rawHandle)
        stateLock.withLock {
            presentedSize = (width, height)
            completedFrames &+= 1
        }
    }

    private func drainPendingRenders() {
        while true {
            let redraw = stateLock.withLock { () -> Bool? in
                guard isActive, isVideoRenderingEnabled, renderPending,
                      drawableSize.width > 0, drawableSize.height > 0 else {
                    renderPending = false
                    redrawPending = false
                    renderScheduled = false
                    return nil
                }
                let redraw = redrawPending
                renderPending = false
                redrawPending = false
                return redraw
            }
            guard let redraw else { return }
            render(forceRedraw: redraw)
        }
    }

    private func clearSurface() {
        guard let context = stateLock.withLock({
            isActive && !isVideoRenderingEnabled ? self.context : nil
        }) else { return }

        context.lock()
        defer { context.unlock() }
        context.makeCurrentContext()
        defer { NSOpenGLContext.clearCurrentContext() }
        glDisable(GLenum(GL_SCISSOR_TEST))
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        context.flushBuffer()
    }
}

final class OwlVideoView: NSOpenGLView {
    let engine: MPVPlayerEngine
    fileprivate nonisolated(unsafe) let openGLLibrary: UnsafeMutableRawPointer?
    private let renderWorker: MVOpenGLRenderWorker
    private var animatedResizeDepth = 0

    /// Applies to both the worker and AppKit's synchronous redraws. Changing
    /// only the latter still lets the worker hold the GL lock through vsync,
    /// blocking the next step of the window animation.
    func beginAnimatedResize() {
        animatedResizeDepth += 1
        guard animatedResizeDepth == 1 else { return }
        setSwapInterval(0)
    }

    func endAnimatedResize() {
        guard animatedResizeDepth > 0 else { return }
        animatedResizeDepth -= 1
        guard animatedResizeDepth == 0 else { return }
        setSwapInterval(1)
        needsDisplay = true
    }

    private func setSwapInterval(_ interval: GLint) {
        guard let openGLContext else { return }
        openGLContext.lock()
        defer { openGLContext.unlock() }
        var interval = interval
        openGLContext.setValues(&interval, for: .swapInterval)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        beginAnimatedResize()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        endAnimatedResize()
    }

    var renderedFrameCount: UInt64 { renderWorker.renderedFrameCount }

    /// Whether mpv has a render context to open files against, and the one
    /// notification of it being made.
    ///
    /// mpv initializes a file's video stream against the render context as the
    /// file is opened. Asked for a file before there is one, it plays whatever
    /// else the file holds and no picture, and a file holding nothing else ends
    /// at once with `MPV_ERROR_NOTHING_TO_PLAY`. The context is made in
    /// `prepareOpenGL`, which AppKit calls no earlier than the first draw, so a
    /// window that opens onto a file has to wait for this.
    private(set) var isRendererReady = false
    var onRendererReady: (@MainActor () -> Void)?

    /// Owned by the render context and by mpv respectively, until
    /// `detachRenderer` tears both down. A view released without that call
    /// leaks two boxes, which is the deliberate trade: the alternative is mpv
    /// holding a pointer to freed memory.
    private var procAddressContext: UnsafeMutableRawPointer?
    private var renderUpdateContext: UnsafeMutableRawPointer?
    private var windowObservers: [NSObjectProtocol] = []

    /// The gamut mpv was last given, so that a window that keeps its screen
    /// does not have mpv rebuild its shaders for nothing. Doubly optional:
    /// nil until the first screen, then whatever that screen turned out to be.
    private var appliedPrimaries: String??


    init(engine: MPVPlayerEngine) {
        self.engine = engine
        renderWorker = MVOpenGLRenderWorker(engine: engine)
        openGLLibrary = dlopen(
            "/System/Library/Frameworks/OpenGL.framework/OpenGL",
            RTLD_LAZY | RTLD_LOCAL
        )

        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile),
            UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize),
            24,
            UInt32(NSOpenGLPFAAlphaSize),
            8,
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            0
        ]
        let format = NSOpenGLPixelFormat(attributes: attributes)!
        super.init(frame: .zero, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard !isRendererReady else { return }
        guard let openGLContext else { return }
        openGLContext.makeCurrentContext()

        // Present on the display refresh after mpv's target-time wait. Both
        // waits run on the render worker, independently of AppKit's run loop.
        var swapInterval: GLint = animatedResizeDepth == 0 ? 1 : 0
        openGLContext.setValues(&swapInterval, for: .swapInterval)

        // mpv keeps this for as long as the render context lives, not just for
        // the length of the call below.
        let procAddressContext = MPVCallbackContext<OwlVideoView>.passRetained(self)
        var error = [CChar](repeating: 0, count: 1_024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            mvp_mpv_initialize_renderer(
                engine.rawHandle,
                mpvOpenGLGetProcAddress,
                procAddressContext,
                buffer.baseAddress,
                buffer.count
            )
        }

        guard result >= 0 else {
            MPVCallbackContext<OwlVideoView>.release(procAddressContext)
            let message = error.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
            }
            Task { @MainActor [weak self] in
                self?.engine.state.errorMessage = message
            }
            return
        }

        self.procAddressContext = procAddressContext
        isRendererReady = true
        renderWorker.activate(context: openGLContext)
        let renderUpdateContext = MPVCallbackContext<MVOpenGLRenderWorker>.passRetained(renderWorker)
        self.renderUpdateContext = renderUpdateContext
        mvp_mpv_set_render_update_callback(
            engine.rawHandle,
            mpvRenderUpdate,
            renderUpdateContext
        )

        // AppKit draws on the main thread, which is where whatever was waiting
        // for a picture has to be answered.
        MainActor.assumeIsolated {
            onRendererReady?()
        }
    }

    override func update() {
        guard let openGLContext else {
            super.update()
            needsDisplay = true
            return
        }
        openGLContext.lock()
        defer { openGLContext.unlock() }
        // NSOpenGLView updates its drawable here, not in reshape() (whose
        // default implementation is empty). Serialize the actual surface
        // change with the worker and publish its matching size and picture
        // before letting the worker draw again.
        super.update()
        if isRendererReady {
            let (width, height) = pixelSize
            renderWorker.renderResized(width: width, height: height)
        }
    }

    private var pixelSize: (width: Int, height: Int) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return (Int(bounds.width * scale), Int(bounds.height * scale))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isRendererReady, openGLContext != nil else {
            // A layer-backed NSOpenGLView calls draw without a Quartz graphics
            // context. Filling dirtyRect here can crash during teardown; the
            // surrounding player supplies the black loading background.
            return
        }

        let (width, height) = pixelSize
        renderWorker.enqueue(width: width, height: height)
    }

    func setVideoRenderingEnabled(_ enabled: Bool) {
        renderWorker.setVideoRenderingEnabled(enabled)
        if enabled {
            needsDisplay = true
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            clearWindowObservers()
            renderWorker.enqueue(width: 0, height: 0)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearWindowObservers()
        guard let window else { return }

        openGLContext?.lock()
        openGLContext?.update()
        openGLContext?.unlock()
        applyDisplayGamut()

        let occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                if window.occlusionState.contains(.visible) {
                    self.openGLContext?.lock()
                    self.openGLContext?.update()
                    self.openGLContext?.unlock()
                    self.needsDisplay = true
                }
            }
        }
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openGLContext?.lock()
                self.openGLContext?.update()
                self.openGLContext?.unlock()
                self.applyDisplayGamut()
                self.needsDisplay = true
            }
        }
        // The same screen with a different colour profile, chosen in Displays
        // settings.
        let profileObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenProfileNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDisplayGamut()
            }
        }
        windowObservers = [occlusionObserver, screenObserver, profileObserver]
    }

    /// Tells mpv the gamut of the screen the window is on. See `DisplayGamut`.
    private func applyDisplayGamut() {
        let primaries = DisplayGamut.mpvPrimaries(for: window?.screen?.colorSpace)
        guard appliedPrimaries != .some(primaries) else { return }
        appliedPrimaries = .some(primaries)
        engine.setDisplayPrimaries(primaries)
    }

    private func clearWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }


    func detachRenderer() {
        clearWindowObservers()
        guard isRendererReady else { return }
        mvp_mpv_set_render_update_callback(engine.rawHandle, nil, nil)
        isRendererReady = false
        // Returns once the render context is destroyed, which is the point
        // after which neither callback can be entered again and the boxes
        // holding this view can be let go.
        renderWorker.deactivate()
        MPVCallbackContext<MVOpenGLRenderWorker>.release(renderUpdateContext)
        renderUpdateContext = nil
        MPVCallbackContext<OwlVideoView>.release(procAddressContext)
        procAddressContext = nil
    }

}
