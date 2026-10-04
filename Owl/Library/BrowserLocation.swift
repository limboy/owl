import Foundation

enum BrowserDestination: Hashable, Codable {
    case folder(UUID)
}

struct BrowserLocation: Codable, Equatable {
    var destination: BrowserDestination
    var path: [URL]

    private static let key = "BrowserLocation"

    static func load(defaults: UserDefaults = .standard) -> Self? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
