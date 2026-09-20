import Foundation
import Observation

enum WebsitePermissionKind: String, Codable, CaseIterable, Comparable {
    case camera
    case microphone
    case cameraAndMicrophone
    case location

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .cameraAndMicrophone: return "Camera and microphone"
        case .location: return "Location"
        }
    }
}
enum WebsitePermissionDecision: String, Codable {
    case allow
    case deny
}

struct WebsitePermissionKey: Hashable, Codable, Comparable {
    var origin: String
    var kind: WebsitePermissionKind

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.origin, lhs.kind) < (rhs.origin, rhs.kind)
    }
}

struct WebsitePermissionRecord: Identifiable, Equatable {
    var key: WebsitePermissionKey
    var decision: WebsitePermissionDecision

    var id: String { "\(key.origin)|\(key.kind.rawValue)" }
}

@MainActor
@Observable
final class WebsitePermissionStore {
    private(set) var decisions: [WebsitePermissionKey: WebsitePermissionDecision]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "website-permissions-v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([WebsitePermissionKey: WebsitePermissionDecision].self, from: data) {
            decisions = decoded
        } else {
            decisions = [:]
        }
    }

    var records: [WebsitePermissionRecord] {
        decisions.keys.sorted().compactMap { key in
            decisions[key].map { WebsitePermissionRecord(key: key, decision: $0) }
        }
    }

    func decision(for origin: String, kind: WebsitePermissionKind) -> WebsitePermissionDecision? {
        decisions[WebsitePermissionKey(origin: origin, kind: kind)]
    }

    func set(_ decision: WebsitePermissionDecision, for origin: String, kind: WebsitePermissionKind) {
        decisions[WebsitePermissionKey(origin: origin, kind: kind)] = decision
        save()
    }

    func revoke(_ key: WebsitePermissionKey) {
        decisions.removeValue(forKey: key)
        save()
    }

    func revokeAll() {
        decisions.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(decisions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
