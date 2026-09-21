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
        self = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .onRequest
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

enum AutomaticReadingConsent {
    static let key = "jev.automaticReadingConsent"

    static func accepted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func accept(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    static let warning = """
    Always-on Critical Reading sends readable text from sites you allow to Jev through OpenRouter. OpenRouter's current policy is that these requests are anonymized and not used to train models. That policy is not a guarantee. A third party still receives the page's text, including anything written on a logged-in mail, finance, health, or work page you later allow. Interlinked will not run automatically on a site until you grant that site, and you can revoke a grant at any time.
    """
}
