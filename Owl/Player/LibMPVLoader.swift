import CMPVShim
import Foundation

struct LibMPVInfo: Equatable, Sendable {
    let path: String
    let apiMajor: Int
    let apiMinor: Int
}

enum LibMPVLoaderError: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
        }
    }
}

enum LibMPVLoader {
    static func validate(apiVersion: UInt64) -> LibMPVLoaderError? {
        let major = Int(apiVersion >> 16)
        let minor = Int(apiVersion & 0xffff)
        guard major == 2 else {
            return .unavailable(
                "Unsupported libmpv client API version \(major).\(minor); major version 2 is required."
            )
        }
        return nil
    }

    static func createPlayer(preview: Bool = false, libraryURL: URL? = nil) -> Result<(OpaquePointer, LibMPVInfo), LibMPVLoaderError> {
        var error = [CChar](repeating: 0, count: 1_024)
        let player = error.withUnsafeMutableBufferPointer { buffer in
            preview
                ? mvp_mpv_create_preview(libraryURL?.path, buffer.baseAddress, buffer.count)
                : mvp_mpv_create(buffer.baseAddress, buffer.count)
        }

        guard let player else {
            let message = error.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
            }
            return .failure(.unavailable(message))
        }

        let version = mvp_mpv_client_api_version(player)
        if let validationError = validate(apiVersion: version) {
            mvp_mpv_destroy(player)
            return .failure(validationError)
        }
        let path = mvp_mpv_library_path(player).map(String.init(cString:)) ?? "libmpv"
        let info = LibMPVInfo(
            path: path,
            apiMajor: Int(version >> 16),
            apiMinor: Int(version & 0xffff)
        )
        return .success((player, info))
    }
}
