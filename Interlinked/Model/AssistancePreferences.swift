import Foundation

enum JevPreferences {
    static let enabledKey = "jev.enabled"

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}
