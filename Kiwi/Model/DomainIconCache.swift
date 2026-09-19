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

    mutating func retain(_ owners: [PaneID: String]) -> Set<String> {
        self.owners = owners
        let live = Set(owners.values)
        let removed = Set(entries.keys).subtracting(live)
        entries = entries.filter { live.contains($0.key) }
        return removed
    }

    mutating func begin(_ domain: String) -> UUID? {
        guard owners.values.contains(domain), entries[domain] == nil else { return nil }
        let token = UUID()
        entries[domain] = Entry(token: token)
        return token
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
}
