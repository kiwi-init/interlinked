import Foundation
import Observation

struct NavigationExceptionKey: Hashable, Codable, Comparable {
    var origin: String
    var reasons: [String]

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.origin, lhs.reasons.joined(separator: "|")) < (rhs.origin, rhs.reasons.joined(separator: "|"))
    }
}

struct NavigationExceptionRecord: Identifiable, Equatable {
    var key: NavigationExceptionKey

    var id: String { "\(key.origin)|\(key.reasons.joined(separator: "|"))" }
}

@MainActor
@Observable
final class NavigationExceptionStore {
    private(set) var exceptions: Set<NavigationExceptionKey>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "navigation-exceptions-v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Set<NavigationExceptionKey>.self, from: data) {
            exceptions = decoded
        } else {
            exceptions = []
        }
    }

    var records: [NavigationExceptionRecord] {
        exceptions.sorted().map(NavigationExceptionRecord.init)
    }

    func contains(_ review: NavigationReview) -> Bool {
        review.exceptionKey.map(exceptions.contains) ?? false
    }

    func allow(_ review: NavigationReview) {
        guard let key = review.exceptionKey else { return }
        exceptions.insert(key)
        save()
    }

    func revoke(_ key: NavigationExceptionKey) {
        exceptions.remove(key)
        save()
    }

    func revokeAll() {
        exceptions.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(exceptions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
