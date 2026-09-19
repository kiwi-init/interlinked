import Foundation

enum CriticalReadingMode: String, CaseIterable, Identifiable {
    case automatic
    case onRequest

    static let defaultsKey = "jev.criticalReadingMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Always on"
        case .onRequest: return "Run only when asked"
        }
    }

    init(defaults: UserDefaults = .standard) {
        self = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum JevPreferences {
    static let enabledKey = "jev.enabled"

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}
