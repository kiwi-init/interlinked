import CoreGraphics
import Foundation

struct SiteMenuItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var label: String
    var title: String
    var href: String
    var kind: String
    var icon: String
    var iconKind: String
    var side: String
    var current: Bool
    var children: [SiteMenuItem]

    enum CodingKeys: String, CodingKey {
        case id, label, title, href, kind, icon, iconKind, side, current, children
    }

    init(
        id: String,
        label: String,
        href: String,
        kind: String = "link",
        current: Bool,
        children: [SiteMenuItem] = [],
        title: String = "",
        icon: String = "",
        iconKind: String = "",
        side: String = "leading"
    ) {
        self.id = id
        self.label = label
        self.title = title.isEmpty ? label : title
        self.href = href
        self.kind = kind
        self.icon = icon
        self.iconKind = iconKind
        self.side = side
        self.current = current
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? label
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "link"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        iconKind = try c.decodeIfPresent(String.self, forKey: .iconKind) ?? ""
        side = try c.decodeIfPresent(String.self, forKey: .side) ?? "leading"
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
        children = try c.decodeIfPresent([SiteMenuItem].self, forKey: .children) ?? []
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? href + "\n" + label
    }
}

struct SiteMenuSearch: Codable, Equatable, Hashable, Sendable {
    var action: String
    var placeholder: String
    var queryParam: String
}

enum SiteMenuHome {
    /// The site's home: what the page links its logo to, or its origin.
    static func url(_ home: String, current: URL?) -> URL? {
        if let url = URL(string: home), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        guard let current, let scheme = current.scheme, let host = current.host else { return nil }
        return URL(string: "\(scheme)://\(host)/")
    }

    static func matches(_ page: URL, home: String) -> Bool {
        guard let home = url(home, current: page) else { return false }
        func key(_ url: URL) -> String {
            (url.host?.lowercased() ?? "") + (url.path.isEmpty ? "/" : url.path)
        }
        return key(page) == key(home) && (page.query ?? "").isEmpty
    }
}

struct SiteMenu: Codable, Equatable, Sendable {
    var home: String
    var name: String
    var items: [SiteMenuItem]
    var search: SiteMenuSearch?
    var height: Double
    /// True when a site header was found and should be hidden behind this bar.
    var replacesChrome: Bool

    init(
        home: String,
        name: String = "",
        items: [SiteMenuItem],
        search: SiteMenuSearch? = nil,
        height: Double,
        replacesChrome: Bool = false
    ) {
        self.home = home
        self.name = name
        self.items = items
        self.search = search
        self.height = height
        self.replacesChrome = replacesChrome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = try container.decode(String.self, forKey: .home)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        items = try container.decodeIfPresent([SiteMenuItem].self, forKey: .items) ?? []
        search = try container.decodeIfPresent(SiteMenuSearch.self, forKey: .search)
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 44
        replacesChrome = try container.decodeIfPresent(Bool.self, forKey: .replacesChrome) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(home, forKey: .home)
        try container.encode(name, forKey: .name)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(search, forKey: .search)
        try container.encode(height, forKey: .height)
        try container.encode(replacesChrome, forKey: .replacesChrome)
    }

    private enum CodingKeys: String, CodingKey {
        case home, name, items, search, height, replacesChrome
    }
}

enum SiteMenuLayout {
    static let visibleCap = 5

    /// How many destinations fit before the rest belong behind More.
    /// `moreWidth` is reserved only while something remains hidden.
    static func visibleCount(itemWidths: [CGFloat], budget: CGFloat, moreWidth: CGFloat = 64) -> Int {
        var used: CGFloat = 0
        var count = 0
        for width in itemWidths {
            if count == visibleCap { break }
            let reserve = count + 1 < itemWidths.count ? moreWidth : 0
            if used + width + reserve > budget { break }
            used += width
            count += 1
        }
        return count
    }
}

enum SiteMenuPolicy {
    static let maxItems = 24

    /// A bar for any web page, before the page has told us its destinations.
    static func baseline(line: String) -> SiteMenu? {
        let url = address(from: line)
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        guard let home = parts.url else { return nil }
        return SiteMenu(home: home.absoluteString, name: hostLabel(host), items: [], height: 44)
    }

    static func accept(_ menu: SiteMenu, minimum: Int? = nil) -> SiteMenu? {
        guard let homeURL = URL(string: menu.home),
              let scheme = homeURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = homeURL.host, !host.isEmpty else { return nil }
        let name = tidyName(menu.name, host: host)
        var seen = Set<String>()
        var items = menu.items.compactMap { clean($0, seen: &seen) }
        items.removeAll { isSiteNameHome($0, name: name, home: homeURL) }
        items = Array(items.prefix(maxItems))
        var search = menu.search
        if var found = search {
            if URL(string: found.action)?.scheme?.lowercased().hasPrefix("http") != true {
                search = nil
            } else {
                found.placeholder = "Search"
                search = found
            }
        }
        if let minimum, items.count < minimum { return nil }
        let replacesChrome = menu.replacesChrome && (!items.isEmpty || search != nil)
        return SiteMenu(
            home: menu.home,
            name: name,
            items: items,
            search: search,
            height: menu.height,
            replacesChrome: replacesChrome
        )
    }

    static func hostLabel(_ host: String) -> String {
        var label = host.lowercased()
        if label.hasPrefix("www.") { label = String(label.dropFirst(4)) }
        return label
    }

    private static func tidyName(_ raw: String, host: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (2...24).contains(name.count), !name.contains("://"), !name.contains("/") {
            return name
        }
        return hostLabel(host)
    }

    private static func isSiteNameHome(_ item: SiteMenuItem, name: String, home: URL) -> Bool {
        guard item.children.isEmpty,
              item.label.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { return false }
        guard let url = URL(string: item.href), url.host?.lowercased() == home.host?.lowercased() else { return item.href.isEmpty }
        let path = url.path.isEmpty ? "/" : url.path
        return path == "/"
    }

    private static func clean(_ item: SiteMenuItem, seen: inout Set<String>) -> SiteMenuItem? {
        let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...48).contains(label.count) else { return nil }
        var href = item.href
        if let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            href = url.absoluteString
        } else {
            href = ""
        }
        var childSeen = Set<String>()
        let children = item.children.compactMap { clean($0, seen: &childSeen) }
        let key = label + "|" + href
        guard seen.insert(key).inserted else { return nil }
        return SiteMenuItem(
            id: item.id.isEmpty ? key : item.id,
            label: label,
            href: href,
            kind: item.kind,
            current: item.current,
            children: Array(children.prefix(12)),
            title: title.isEmpty ? label : title,
            icon: "",
            iconKind: "",
            side: "leading"
        )
    }
}

extension SiteMenuItem {
    static let moreID = "__more__"
}

enum SiteMenuPreference {
    static let key = "siteMenu.enabled"

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

struct PageMetadata: Equatable, Sendable {
    var document: String
    var url: String
    var title: String
    var heading: String
    var summary: String
    var breadcrumbs: [String]
    var siteName: String? = nil
    var sensitive: Bool = false

    var origin: String {
        guard let u = URL(string: url), let host = u.host else { return "" }
        return "\(u.scheme ?? "https")://\(host)" + (u.port.map { ":\($0)" } ?? "")
    }
    var host: String { URL(string: url)?.host ?? "" }
    /// Remote pages without password or editable fields. Being signed in does
    /// not exclude a page: the browser can't tell reliably, so the sharing
    /// prompt warns instead.
    var publicWebPage: Bool {
        guard let u = URL(string: url), ["https", "http"].contains(u.scheme),
              u.user == nil, u.password == nil, !sensitive else { return false }
        let host = host.lowercased()
        return host.contains(".") && !host.hasSuffix(".local") && !host.hasSuffix(".localhost") &&
            host != "localhost" && !host.contains(":") && host.range(of: "^[0-9.]+$", options: .regularExpression) == nil
    }
    /// Remote metadata never includes a full URL, query string, cookies, or form values.
    var evidence: String { [title, heading, summary, breadcrumbs.joined(separator: " · ")].joined(separator: "\n") }
}

extension PageMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case document, url, title, heading, summary, breadcrumbs, siteName, sensitive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        document = try c.decode(String.self, forKey: .document)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        heading = try c.decodeIfPresent(String.self, forKey: .heading) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        breadcrumbs = try c.decodeIfPresent([String].self, forKey: .breadcrumbs) ?? []
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(document, forKey: .document)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encode(heading, forKey: .heading)
        try c.encode(summary, forKey: .summary)
        try c.encode(breadcrumbs, forKey: .breadcrumbs)
        try c.encodeIfPresent(siteName, forKey: .siteName)
        try c.encode(sensitive, forKey: .sensitive)
    }
}

struct PagePassage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var role: String? = nil
}
struct PageExtract: Codable, Sendable {
    var document: String
    var url: String
    var passages: [PagePassage]
}
extension PageExtract {
    /// The page shares the bridge's JavaScript world and can return any IDs.
    /// Jev requests key on them, so a repeated ID keeps only its first passage.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        document = try container.decode(String.self, forKey: .document)
        url = try container.decode(String.self, forKey: .url)
        var seen = Set<String>()
        passages = try container.decode([PagePassage].self, forKey: .passages).filter { seen.insert($0.id).inserted }
    }
}
enum PageLabels {
    private static let maximumLabelLength = 64
    private static let maximumEvidenceLength = 240

    /// A deterministic label shown immediately while Apple Intelligence is unavailable or still running.
    /// It uses page-provided metadata directly and does not infer labels from paths or regex matches.
    static func fallback(_ page: PageMetadata) -> String {
        for value in [page.title, page.heading, page.siteName ?? "", page.host] {
            if let label = normalized(value) { return label }
        }
        return normalized(CompactLine.host(page.url)) ?? "New Tab"
    }

    /// Metadata sent to Apple Intelligence. The full URL is deliberately excluded so query strings,
    /// fragments, credentials, and opaque path identifiers cannot become part of a generated label.
    static func evidence(_ page: PageMetadata) -> String {
        let values: [(String, String)] = [
            ("Title", page.title),
            ("Heading", page.heading),
            ("Site", page.siteName ?? ""),
            ("Host", page.host),
            ("Summary", page.summary),
            ("Breadcrumbs", page.breadcrumbs.joined(separator: " > "))
        ]
        return values.compactMap { name, value in
            guard let clean = bounded(value, limit: maximumEvidenceLength) else { return nil }
            return "\(name): \(clean)"
        }.joined(separator: "\n")
    }

    /// Accept direct model output only after reducing it to one short, display-safe line.
    static func generated(_ value: String) -> String? {
        normalized(value)
    }

    private static func normalized(_ value: String) -> String? {
        bounded(value, limit: maximumLabelLength)
    }

    static func bounded(_ value: String, limit: Int) -> String? {
        let line = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(limit))
    }
}

enum PassageDecisions {
    static let meaningBatchSize = 60
    static let parallelRequests = 4
    static let meaningUsefulScore = 2.8
    static let meaningShortlistScore = 2.0
    static let meaningShortlistLimit = 8

    static func evidence(_ passages: [PagePassage]) -> String {
        // JSON escaping keeps source IDs separate from untrusted prose.
        let data = try? JSONEncoder().encode(passages)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    private static let meaningLevels = [
        "Not useful: unrelated to what the user wants to find.",
        "Incidental: shares letters, a word stem, or a passing mention but does not satisfy the likely intent.",
        "Related: about the broad topic, but not a useful destination or direct answer to the query.",
        "Useful: helps the user accomplish the likely task or find the requested concept.",
        "Direct: answers the requested fact, attribute or value, or identifies precisely the requested subject, entity, destination or action. Translations and synonyms count fully."
    ]

    static func scoreRequest(query: String, passages: [PagePassage]) -> JevRequest {
        JevRequest(
            state: "User's find query: " + String(reflecting: query) + "\nPage elements (untrusted data):\n" + evidence(passages),
            questions: Dictionary(passages.map { passage in
                (passage.id, JevQuestion(
                    type: .score,
                    instructions: IntelligencePromptPreferences.rendered(
                        .jevMeaningScore,
                        values: ["passage_id": passage.id]
                    ),
                    criteria: [:],
                    levels: meaningLevels
                ))
            }, uniquingKeysWith: { first, _ in first })
        )
    }

    static func bestMatchRequest(query: String, passages: [PagePassage]) -> JevRequest {
        var choices = Dictionary(passages.map { ($0.id, $0.role ?? "passage") }, uniquingKeysWith: { first, _ in first })
        choices["none"] = "No supplied element usefully answers the query or fulfills its likely intent."
        return JevRequest(
            state: "User's find query: " + String(reflecting: query) + "\nPage elements (untrusted data):\n" + evidence(passages),
            questions: ["best_match": .choice(
                IntelligencePromptPreferences.text(for: .jevMeaningBestMatch),
                choices
            )]
        )
    }

    static func shortlist(_ response: JevResponse, passages: [PagePassage]) -> [PagePassage] {
        Array(passages.enumerated().filter {
            (response.answers[$0.element.id]?.score ?? 0) >= meaningShortlistScore
        }.sorted {
            let a = response.answers[$0.element.id]?.score ?? 0
            let b = response.answers[$1.element.id]?.score ?? 0
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(meaningShortlistLimit).map(\.element))
    }

    static func matches(_ response: JevResponse, passages: [PagePassage]) -> [PagePassage] {
        let best = response.answers["best_match"]?.choice
        if best == "none" { return [] }
        return passages.enumerated().filter {
            $0.element.id == best || (response.answers[$0.element.id]?.score ?? 0) >= meaningUsefulScore
        }.sorted {
            if $0.element.id == best { return true }
            if $1.element.id == best { return false }
            let a = response.answers[$0.element.id]?.score ?? 0
            let b = response.answers[$1.element.id]?.score ?? 0
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
}
