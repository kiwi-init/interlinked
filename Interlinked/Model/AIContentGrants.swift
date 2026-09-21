import Foundation
import Observation

/// Origin grants for sending page text to AI. Session grants die with the process.
/// Remembered grants are stored only after the user chooses to keep them.
@MainActor
@Observable
final class AIContentGrantStore {
    private(set) var sessionOrigins: Set<String>
    private(set) var rememberedOrigins: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "jev.originGrants") {
        self.defaults = defaults
        self.storageKey = storageKey
        sessionOrigins = []
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            rememberedOrigins = Set(saved.filter { !$0.isEmpty })
        } else {
            rememberedOrigins = []
        }
    }

    var records: [String] {
        (sessionOrigins.union(rememberedOrigins)).sorted()
    }

    func allows(_ origin: String) -> Bool {
        guard !origin.isEmpty else { return false }
        return sessionOrigins.contains(origin) || rememberedOrigins.contains(origin)
    }

    func isRemembered(_ origin: String) -> Bool {
        rememberedOrigins.contains(origin)
    }

    func grant(_ origin: String, remember: Bool) {
        guard !origin.isEmpty else { return }
        sessionOrigins.insert(origin)
        if remember {
            rememberedOrigins.insert(origin)
            save()
        }
    }

    func revoke(_ origin: String) {
        sessionOrigins.remove(origin)
        if rememberedOrigins.remove(origin) != nil { save() }
    }

    func revokeAll() {
        sessionOrigins.removeAll()
        if !rememberedOrigins.isEmpty {
            rememberedOrigins.removeAll()
            save()
        }
    }

    private func save() {
        let payload = rememberedOrigins.sorted()
        defaults.set((try? JSONEncoder().encode(payload)) ?? Data(), forKey: storageKey)
    }
}
