import Foundation
import Observation

/// Where Return searches, and where typed words go for suggestions.
enum SearchProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case google
    case duckDuckGo = "duckduckgo"
    case bing
    case brave
    case ecosia

    var id: Self { self }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave"
        case .ecosia: "Ecosia"
        }
    }

    func searchURL(for query: String) -> URL {
        var search = URLComponents(string: searchTemplate)!
        search.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search engines read + as a space, so a typed plus is sent as %2B.
        search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return search.url!
    }

    func suggestionURL(for query: String) -> URL {
        var endpoint = URLComponents(string: suggestionTemplate)!
        endpoint.queryItems = suggestionParameters + [URLQueryItem(name: suggestionKey, value: query)]
        endpoint.percentEncodedQuery = endpoint.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return endpoint.url!
    }

    /// The suggested queries in the provider's order.
    func parseSuggestions(_ data: Data) -> [String] {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else { return [] }
        switch self {
        case .google, .bing, .brave:
            // OpenSearch: ["query", ["suggestion", ...], ...]
            guard let list = payload as? [Any], list.count > 1 else { return [] }
            return list[1] as? [String] ?? []
        case .duckDuckGo:
            // [{"phrase": "suggestion"}, ...]
            return (payload as? [[String: Any]])?.compactMap { $0["phrase"] as? String } ?? []
        case .ecosia:
            // {"query": "query", "suggestions": ["suggestion", ...]}
            return (payload as? [String: Any])?["suggestions"] as? [String] ?? []
        }
    }

    /// Whether a page address is this provider's results page.
    func isResultsPage(_ parts: URLComponents) -> Bool {
        guard let host = parts.host?.lowercased(), hosts.contains(host) else { return false }
        return self == .duckDuckGo || parts.path == "/search"
    }

    private var searchTemplate: String {
        switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .brave: "https://search.brave.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        }
    }

    private var suggestionTemplate: String {
        switch self {
        case .google: "https://suggestqueries.google.com/complete/search"
        case .duckDuckGo: "https://duckduckgo.com/ac/"
        case .bing: "https://api.bing.com/osjson.aspx"
        case .brave: "https://search.brave.com/api/suggest"
        case .ecosia: "https://ac.ecosia.org/autocomplete"
        }
    }

    private var suggestionParameters: [URLQueryItem] {
        self == .google ? [URLQueryItem(name: "client", value: "firefox")] : []
    }

    private var suggestionKey: String { self == .bing ? "query" : "q" }

    private var hosts: Set<String> {
        switch self {
        case .google: ["google.com", "www.google.com", "google.com.br", "www.google.com.br"]
        case .duckDuckGo: ["duckduckgo.com", "www.duckduckgo.com"]
        case .bing: ["bing.com", "www.bing.com"]
        case .brave: ["search.brave.com"]
        case .ecosia: ["ecosia.org", "www.ecosia.org"]
        }
    }
}

/// The search choices in Settings, kept in `UserDefaults`.
@MainActor @Observable
final class SearchSettings {
    nonisolated static let providerKey = "search.provider"
    nonisolated static let remoteSuggestionsKey = "search.remoteSuggestions"
    nonisolated static let suggestionProviderKey = "search.suggestionProvider"

    @ObservationIgnored private let defaults: UserDefaults

    var provider: SearchProvider {
        didSet { defaults.set(provider.rawValue, forKey: Self.providerKey) }
    }

    /// Off means suggestions come only from open tabs and history.
    var remoteSuggestions: Bool {
        didSet { defaults.set(remoteSuggestions, forKey: Self.remoteSuggestionsKey) }
    }

    /// Nil follows the search provider.
    var suggestionOverride: SearchProvider? {
        didSet { defaults.set(suggestionOverride?.rawValue, forKey: Self.suggestionProviderKey) }
    }

    var suggestionProvider: SearchProvider { suggestionOverride ?? provider }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = Self.storedProvider(in: defaults)
        remoteSuggestions = defaults.object(forKey: Self.remoteSuggestionsKey) as? Bool ?? true
        suggestionOverride = defaults.string(forKey: Self.suggestionProviderKey).flatMap(SearchProvider.init)
    }

    /// Google until the user picks another, so nothing changes silently.
    nonisolated static func storedProvider(in defaults: UserDefaults = .standard) -> SearchProvider {
        defaults.string(forKey: providerKey).flatMap(SearchProvider.init) ?? .google
    }
}

enum SuggestionPrivacy {
    /// Text that must never leave the Mac as a suggestion request: addresses,
    /// local hosts, emails, file paths, and anything shaped like a secret.
    static func isSensitive(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("@") || navigationURL(from: text) != nil { return true }
        return text.split(whereSeparator: \.isWhitespace).contains { word in
            let word = String(word)
            return word.contains("://") || isLocalAddress(word) || isPath(word) || isToken(word)
        }
    }

    private static func isLocalAddress(_ word: String) -> Bool {
        let word = word.lowercased()
        if word == "localhost" || word.hasPrefix("localhost:") || word.hasSuffix(".localhost") { return true }
        if word.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil { return true }
        // IPv6, bracketed or bare: compressed with ::, or written out in full.
        return (word.contains("::") || word.filter { $0 == ":" }.count >= 5)
            && word.range(of: #"^\[?[0-9a-f:.]+(%\w+)?\]?(:\d+)?$"#, options: .regularExpression) != nil
    }

    private static func isPath(_ word: String) -> Bool {
        ["/", "~/", "./", "../"].contains { word.hasPrefix($0) } || word == "~" || word.contains("\\")
            || word.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    private static func isToken(_ word: String) -> Bool {
        if word.count >= 32 { return true }
        if word.range(of: "[0-9A-Fa-f]{16,}", options: .regularExpression) != nil { return true }
        return word.ranges(of: #/[A-Za-z0-9+\/_]{20,}={0,2}/#).contains { run in
            let text = word[run]
            return text.contains(where: \.isLetter) && text.contains(where: \.isNumber)
        }
    }
}

/// An open tab's page, offered as a local suggestion.
struct LocalCandidate: Equatable {
    var title: String
    var url: String
}

enum LocalSuggestions {
    static let limit = 8

    /// Open tabs and history that start with the typed text, then those
    /// whose words start with each typed word. Tabs lead history within each
    /// tier, and history keeps its newest-first order.
    static func rank(_ query: String, tabs: [LocalCandidate], history: [BrowserHistoryVisit]) -> [SearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let typed = words(query)
        guard !query.isEmpty, !typed.isEmpty else { return [] }
        let candidates = tabs.map { ($0.title, $0.url, SearchResult.Source.tab) }
            + history.map { ($0.title, $0.url, SearchResult.Source.history) }
        var seen = Set<String>()
        let ranked: [(tier: Int, order: Int, result: SearchResult)] = candidates.enumerated().compactMap { order, candidate in
            let (title, address, source) = candidate
            guard let url = URL(string: address), seen.insert(url.absoluteString).inserted else { return nil }
            let place = CompactLine.editable(address).lowercased()
            let name = title.lowercased()
            let tier: Int
            if place.hasPrefix(query) || name.hasPrefix(query) {
                tier = 0
            } else {
                let known = words(name) + words(place)
                guard typed.allSatisfy({ word in known.contains { $0.hasPrefix(word) } }) else { return nil }
                tier = 1
            }
            let display = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (tier, order, SearchResult(title: display.isEmpty ? CompactLine.host(address) : display, url: url, source: source))
        }
        return ranked.sorted { ($0.tier, $0.order) < ($1.tier, $1.order) }.prefix(limit).map(\.result)
    }

    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

protocol SuggestionClient: Sendable {
    func suggestions(for query: String, from provider: SearchProvider) async throws -> [String]
}

struct NetworkSuggestionClient: SuggestionClient {
    func suggestions(for query: String, from provider: SearchProvider) async throws -> [String] {
        let request = URLRequest(url: provider.suggestionURL(for: query), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else { return [] }
        return provider.parseSuggestions(data)
    }
}

/// Sends typed words to the suggestion provider after a short pause, and
/// only when remote suggestions are on and the words are not private.
@MainActor
final class RemoteSuggestions {
    private let client: SuggestionClient
    private let settings: SearchSettings
    private let delay: Duration
    private(set) var pending: Task<Void, Never>?

    init(settings: SearchSettings, client: SuggestionClient = NetworkSuggestionClient(), delay: Duration = .milliseconds(350)) {
        self.settings = settings
        self.client = client
        self.delay = delay
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    func request(_ query: String, deliver: @escaping @MainActor ([SearchResult]) -> Void) {
        cancel()
        guard settings.remoteSuggestions, !SuggestionPrivacy.isSensitive(query) else { return }
        let source = settings.suggestionProvider, search = settings.provider
        pending = Task { [client, delay] in
            do {
                try await Task.sleep(for: delay)
                let titles = try await client.suggestions(for: query, from: source)
                try Task.checkCancellation()
                deliver(SearchResult.remote(titles, from: source, searchingWith: search))
            } catch { /* Return still searches when suggestions are unavailable. */ }
        }
    }
}
