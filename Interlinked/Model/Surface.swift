import Foundation

enum OpenWork {
    static func rows(count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let lanes = (count + 4) / 5
        let base = count / lanes, extra = count % lanes
        var start = 0
        return (0..<lanes).map { lane in
            let end = start + base + (lane < extra ? 1 : 0)
            defer { start = end }
            return start..<end
        }
    }

    static func title(customName: String?, pageTitle: String?, fallback: String) -> String {
        for candidate in [customName, pageTitle] {
            if let title = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return title
            }
        }
        return fallback
    }

    /// Every other tab, oldest first. A pinned tab leads so its ⌘1 never moves.
    static func switcherTabs(_ tabs: [Tab], current: TabID?, pinned: TabID? = nil) -> [Tab] {
        tabs.filter { $0.id != current }.sorted {
            if $0.id == pinned { return true }
            if $1.id == pinned { return false }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    static func shortcutIndex(_ characters: String) -> Int? {
        guard characters.count == 1, let digit = Int(characters), (1...9).contains(digit) else { return nil }
        return digit - 1
    }

    static func matches(_ query: String, title: String, details: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let text = ([title] + details).joined(separator: " ")
        return words.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

enum Kind: String, Codable, CaseIterable, Equatable, Hashable {
    case blank
    case browser
    case terminal
    case files
    case agent

    /// New pages are always browser pages. Other kinds only decode old sessions.
    static let offered: [(Kind, String)] = [(.browser, "1")]

    var name: String { rawValue }

    var lineIs: String {
        switch self {
        case .blank: return ""
        case .browser: return "an address"
        case .terminal: return "a folder"
        case .files: return "a path"
        case .agent: return "a task"
        }
    }

    var symbol: String {
        switch self {
        case .blank: return "plus"
        case .browser: return "globe"
        case .terminal: return "terminal"
        case .files: return "folder"
        case .agent: return "sparkle"
        }
    }

    /// What a compact Safari-style pill shows for this line.
    func compactLabel(for line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .blank:
            return ""
        case .browser:
            return CompactLine.searchQuery(trimmed) ?? CompactLine.host(trimmed)
        case .terminal, .files:
            return CompactLine.path(trimmed)
        case .agent:
            return trimmed
        }
    }

    static func parse(_ word: String) -> Kind? {
        switch word.lowercased() {
        case "blank", "empty", "nothing": return .blank
        case "browser", "web", "page", "safari", "chrome": return .browser
        case "terminal", "shell", "console", "command": return .terminal
        case "files", "file", "finder", "folder", "folders": return .files
        case "agent", "assistant", "claude": return .agent
        default: return nil
        }
    }
}

enum CompactLine {
    static func committed(_ text: String, original: String?) -> String {
        if let original, text == editable(original) { return original }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func searchQuery(_ line: String) -> String? {
        guard let parts = URLComponents(string: line),
              let host = parts.host?.lowercased() else { return nil }
        let key: String
        switch host {
        case "google.com", "www.google.com", "google.com.br", "www.google.com.br", "bing.com", "www.bing.com":
            guard parts.path == "/search" else { return nil }
            key = "q"
        case "duckduckgo.com", "www.duckduckgo.com": key = "q"
        default: return nil
        }
        // Search engines use form encoding: a literal + means a space, %2B means +.
        let query = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20") ?? ""
        return URLComponents(string: "https://search.invalid/?" + query)?.queryItems?
            .first(where: { $0.name == key })?.value
    }

    static func editable(_ line: String) -> String {
        if let query = searchQuery(line) { return query }
        guard var parts = URLComponents(string: line), parts.scheme == "https", parts.host != nil else { return line }
        // Keep meaningful parameters and encoded separators intact.
        let query = parts.percentEncodedQuery?.split(separator: "&").filter {
            let name = String($0.split(separator: "=", maxSplits: 1).first ?? "").removingPercentEncoding?.lowercased() ?? ""
            return !name.hasPrefix("utm_") && !["gclid", "fbclid", "msclkid"].contains(name)
        }.joined(separator: "&")
        parts.percentEncodedQuery = query?.isEmpty == false ? query : nil
        if parts.path == "/" { parts.path = "" }
        // Never make credentials look like part of the site's identity.
        parts.user = nil
        parts.password = nil
        let clean = parts.string ?? line
        return clean.replacingOccurrences(of: "^https://(www\\.)?", with: "", options: .regularExpression)
    }

    static func host(_ line: String) -> String {
        if line.isEmpty { return "" }
        let url = address(from: line)
        if url.scheme == "about" { return "" }
        var host = url.host ?? line
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host
    }

    static func path(_ line: String) -> String {
        if line.isEmpty { return "~" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = (line as NSString).expandingTildeInPath
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            path = "~/" + String(path.dropFirst(home.count + 1))
        }
        if path.count <= 28 { return path }
        return "…/" + (path as NSString).lastPathComponent
    }
}

struct SearchResult: Identifiable, Equatable {
    var title: String
    var url: URL
    var id: URL { url }

    static func fetch(_ query: String) async throws -> [SearchResult] {
        var endpoint = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        endpoint.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "q", value: query)
        ]
        let request = URLRequest(url: endpoint.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else { return [] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [SearchResult] {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [Any],
              payload.count > 1,
              let suggestions = payload[1] as? [String] else { return [] }
        var seen = Set<String>()
        return suggestions.compactMap { suggestion in
            let title = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(title.localizedLowercase).inserted else { return nil }
            var search = URLComponents(string: "https://www.google.com/search")!
            search.queryItems = [URLQueryItem(name: "q", value: title)]
            guard let url = search.url else { return nil }
            return SearchResult(title: title, url: url)
        }.prefix(3).map { $0 }
    }
}

struct Surface: Codable, Equatable {
    var kind: Kind = .blank
    var line: String = ""
}

struct Surfaces {
    private var surfaces: [PaneID: Surface] = [:]

    func line(_ pane: PaneID) -> String {
        surfaces[pane]?.line ?? ""
    }

    func kind(_ pane: PaneID) -> Kind {
        surfaces[pane]?.kind ?? .blank
    }

    func surface(_ pane: PaneID) -> Surface {
        surfaces[pane] ?? Surface()
    }

    mutating func setLine(_ pane: PaneID, _ line: String) {
        surfaces[pane, default: Surface()].line = line
    }

    mutating func setKind(_ pane: PaneID, _ kind: Kind) {
        var surface = surfaces[pane] ?? Surface()
        if surface.kind != kind {
            surface.line = ""
        }
        surface.kind = kind
        surfaces[pane] = surface
    }

    mutating func erase(_ pane: PaneID) {
        surfaces[pane]?.line = ""
    }

    mutating func forget(keep: (PaneID) -> Bool) {
        surfaces = surfaces.filter { keep($0.key) }
    }

    func tabTitle(_ tab: Tab) -> String {
        if let name = tab.name { return name }
        let k = kind(tab.active)
        let raw = line(tab.active)
        if !raw.isEmpty {
            let compact = k.compactLabel(for: raw)
            return compact.isEmpty ? raw : compact
        }
        switch k {
        case .blank: return "empty"
        case let kind: return kind.name
        }
    }

    func entries() -> [SurfacePair] {
        surfaces.keys.sorted { $0.rawValue < $1.rawValue }.map {
            SurfacePair(pane: $0, surface: surfaces[$0] ?? Surface())
        }
    }

    static func restore(_ entries: [SurfacePair]) -> Surfaces {
        var surfaces = Surfaces()
        for entry in entries {
            surfaces.surfaces[entry.pane] = entry.surface
        }
        return surfaces
    }
}

struct SurfacePair: Codable {
    var pane: PaneID
    var surface: Surface

    init(pane: PaneID, surface: Surface) {
        self.pane = pane
        self.surface = surface
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        pane = try container.decode(PaneID.self)
        surface = try container.decode(Surface.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(pane)
        try container.encode(surface)
    }
}

func address(from line: String) -> URL {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return URL(string: "about:blank")! }
    if let url = navigationURL(from: trimmed) { return url }
    var search = URLComponents(string: "https://www.google.com/search")!
    search.queryItems = [URLQueryItem(name: "q", value: trimmed)]
    search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return search.url!
}

/// Dotted hosts, local servers, and explicit schemes navigate; everything else searches.
func navigationURL(from line: String) -> URL? {
    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if let url = URL(string: text), let scheme = url.scheme,
       text.hasPrefix(scheme + "://") || ["about", "file", "mailto", "data"].contains(scheme.lowercased()) {
        return url
    }
    guard !text.contains(where: \.isWhitespace),
          var parts = URLComponents(string: "https://" + text),
          let host = parts.host, !host.isEmpty,
          host.contains(".") || host == "localhost" || host.hasPrefix("[") else { return nil }
    if host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "[::1]" {
        parts.scheme = "http"
    }
    return parts.url
}
