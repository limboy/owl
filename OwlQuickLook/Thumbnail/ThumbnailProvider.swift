import AppKit
import CMPVShim
import QuickLookThumbnailing
import OSLog

final class ThumbnailProvider: QLThumbnailProvider {
    private static let queue = DispatchQueue(label: "me.limboy.owl.quicklook.thumbnails", qos: .utility)

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let work = ThumbnailWork(request: request, handler: handler)
        Self.queue.async { work.run() }
    }
}

private final class ThumbnailWork: @unchecked Sendable {
    let request: QLFileThumbnailRequest
    let handler: (QLThumbnailReply?, Error?) -> Void

    init(request: QLFileThumbnailRequest, handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        self.request = request
        self.handler = handler
    }

    func run() {
        let scoped = request.fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { request.fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let contents = Bundle(for: ThumbnailProvider.self).bundleURL
                .deletingLastPathComponent().deletingLastPathComponent()
            let library = contents.appendingPathComponent("Frameworks/libmpv.2.dylib")
            let (player, _) = try LibMPVLoader.createPlayer(preview: true, libraryURL: library).get()
            defer { mvp_mpv_destroy(player) }
            guard mvp_mpv_initialize_software_renderer(player) >= 0 else { throw failure() }
            defer { mvp_mpv_destroy_renderer(player) }
            // Quick Look's thumbnail sandbox does not allow child processes.
            // Decode in-process, muted and paused, without sidecar discovery.
            try command(["set", "aid", "no"], player: player)
            try command(["set", "sid", "no"], player: player)
            try command(["set", "pause", "yes"], player: player)
            try command(["set", "start", "10%"], player: player)
            try command(["loadfile", request.fileURL.path, "replace"], player: player)
            let image = try frame(player: player)
            let maximum = request.maximumSize
            let ratio = min(maximum.width / CGFloat(image.width), maximum.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
            handler(QLThumbnailReply(contextSize: size, drawing: { context in
                // The context is sized in pixels (contextSize × scale) but its
                // transform is not always scaled to match, so fill whatever
                // the device bounds are in user space.
                let bounds = context.convertToUserSpace(CGRect(x: 0, y: 0, width: context.width, height: context.height))
                context.interpolationQuality = .high
                context.draw(image, in: bounds)
                return true
            }), nil)
        } catch {
            Logger(subsystem: "me.limboy.owl.thumbnail", category: "decoder").error("Thumbnail failed: \(error.localizedDescription, privacy: .public)")
            handler(nil, error)
        }
    }

    private func frame(player: OpaquePointer) throws -> CGImage {
        let edge = max(64, min(1024, Int(max(request.maximumSize.width, request.maximumSize.height) * request.scale)))
        let deadline = ContinuousClock.now + .seconds(8)
        var loaded = false
        var aspect = 16.0 / 9.0
        var latest: CGImage?
        while ContinuousClock.now < deadline {
            var event = MVPMPVEvent()
            while mvp_mpv_poll_event(player, &event) != 0 {
                if event.type == MVP_MPV_EVENT_FILE_LOADED { loaded = true }
                if event.type == MVP_MPV_EVENT_COMMAND_ERROR ||
                    (event.type == MVP_MPV_EVENT_END_FILE && event.end_reason == 4) { throw failure() }
                if event.type == MVP_MPV_EVENT_PROPERTY, event.value_type == MVP_MPV_VALUE_DOUBLE {
                    let name = withUnsafePointer(to: &event.name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
                    }
                    let value = event.double_value
                    if value.isFinite {
                        if name == "video-out-params/aspect", value > 0 { aspect = value }
                    }
                }
            }
            let width = max(1, Int(Double(edge) * min(1, aspect)))
            let height = max(1, Int(Double(edge) / max(1, aspect)))
            let stride = ((width * 4 + 63) / 64) * 64
            let pixels = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
            let rendered = mvp_mpv_render_software(player, pixels, Int32(width), Int32(height), stride, false)
            let data = rendered > 0 ? Data(bytes: pixels, count: stride * height) : nil
            pixels.deallocate()
            if let data,
               let provider = CGDataProvider(data: data as CFData),
               let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                latest = image
            }
            if loaded, let latest { return latest }
            if rendered < 0 { throw failure() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(domain: "OwlQuickLook", code: 2, userInfo: [NSLocalizedDescriptionKey: "Thumbnail timed out (loaded: \(loaded), frame: \(latest != nil))."])
    }

    private func command(_ arguments: [String], player: OpaquePointer) throws {
        let storage = arguments.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = storage.map { $0.map { UnsafePointer($0) } } + [nil]
        var error = [CChar](repeating: 0, count: 512)
        let result = pointers.withUnsafeBufferPointer {
            mvp_mpv_command_async(player, $0.baseAddress, nil, &error, error.count)
        }
        guard result >= 0 else { throw failure() }
    }

    private func failure() -> NSError {
        NSError(domain: "OwlQuickLook", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not decode a video thumbnail."
        ])
    }
}
