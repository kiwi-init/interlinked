import Foundation

/// One attempt per open hostname, shared by every tab, including unloaded tabs.
struct DomainIconCache<Value> {
    private struct Entry {
        var token: UUID
        var value: Value?
    }
    private var entries: [String: Entry] = [:]
    private(set) var owners: [PaneID: String] = [:]
    private(set) var pinned: Set<String> = []

    static func domain(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.host?.lowercased()
    }

    private var live: Set<String> { Set(owners.values).union(pinned) }

    mutating func retain(_ owners: [PaneID: String], pinned: Set<String> = []) -> Set<String> {
        self.owners = owners
        self.pinned = pinned
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

enum FaviconCandidates {
    static func urls(for page: URL, html: String? = nil) -> [URL] {
        var found: [URL] = []
        if let html { found.append(contentsOf: fromHTML(html, base: page)) }
        if let ico = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL { found.append(ico) }
        if let apple = URL(string: "/apple-touch-icon.png", relativeTo: page)?.absoluteURL { found.append(apple) }
        var seen = Set<URL>()
        let unique = found.filter { seen.insert($0).inserted }
        return unique.filter { !isSVG($0) } + unique.filter { isSVG($0) }
    }

    static func fromHTML(_ html: String, base: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\s[^>]*>", options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return tags.matches(in: html, range: range).compactMap { match in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            guard rel.contains("icon") else { return nil }
            guard let href = attribute("href", in: tag) else { return nil }
            return URL(string: href, relativeTo: base)?.absoluteURL
        }
    }

    static func isSVG(_ url: URL) -> Bool {
        url.path.lowercased().hasSuffix(".svg") || url.pathExtension.lowercased() == "svg"
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for index in 1...3 {
            if let range = Range(match.range(at: index), in: tag), !range.isEmpty {
                return String(tag[range])
            }
        }
        return nil
    }
}
