import Foundation

/// One attempt per open hostname, shared by every tab, including unloaded tabs.
struct DomainIconCache<Value> {
    private struct Entry {
        var token: UUID
        var value: Value?
    }
    private var entries: [String: Entry] = [:]
    private(set) var owners: [PaneID: String] = [:]

    static func domain(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.host?.lowercased()
    }

    private var live: Set<String> { Set(owners.values) }

    mutating func retain(_ owners: [PaneID: String]) -> Set<String> {
        self.owners = owners
        let live = self.live
        let removed = Set(entries.keys).subtracting(live)
        entries = entries.filter { live.contains($0.key) }
        return removed
    }

    mutating func begin(_ domain: String) -> UUID? {
        guard live.contains(domain), entries[domain] == nil else { return nil }
        let token = UUID()
        entries[domain] = Entry(token: token)
        return token
    }

    mutating func restore(_ domain: String, value: Value) -> Bool {
        guard live.contains(domain), entries[domain] == nil else { return false }
        entries[domain] = Entry(token: UUID(), value: value)
        return true
    }

    func contains(_ domain: String) -> Bool {
        entries[domain] != nil
    }

    @discardableResult
    mutating func complete(_ domain: String, token: UUID, value: Value?) -> Bool {
        guard entries[domain]?.token == token else { return false }
        entries[domain]?.value = value
        return true
    }

    func value(for pane: PaneID) -> Value? {
        owners[pane].flatMap { entries[$0]?.value }
    }

    func value(forDomain domain: String) -> Value? {
        entries[domain]?.value
    }
}
