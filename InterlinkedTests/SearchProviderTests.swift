import XCTest

@MainActor
final class RemoteSuggestionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SearchProviderTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func type(_ text: String, into suggestions: RemoteSuggestions) {
        for end in text.indices.dropFirst() {
            suggestions.request(String(text[..<end])) { _ in }
        }
        suggestions.request(text) { _ in }
    }

    func testDisabledRemoteSuggestionsMakeNoRequestWhileTyping() async throws {
        let settings = SearchSettings(defaults: defaults)
        settings.remoteSuggestions = false
        let client = CountingClient()
        let suggestions = RemoteSuggestions(settings: settings, client: client, delay: .milliseconds(5))
        type("interlinked browser", into: suggestions)
        XCTAssertNil(suggestions.pending)
        try await Task.sleep(for: .milliseconds(100))
        let calls = await client.queries
        XCTAssertEqual(calls, [])
    }

    func testEnabledRemoteSuggestionsSendOnlyTheLastTypedTextToTheSuggestionProvider() async {
        let settings = SearchSettings(defaults: defaults)
        settings.provider = .brave
        let client = CountingClient()
        let suggestions = RemoteSuggestions(settings: settings, client: client, delay: .milliseconds(20))
        type("space x", into: suggestions)
        await suggestions.pending?.value
        var calls = await client.queries
        XCTAssertEqual(calls.map(\.query), ["space x"])
        XCTAssertEqual(calls.map(\.provider), [.brave])

        settings.suggestionOverride = .duckDuckGo
        var delivered: [SearchResult] = []
        suggestions.request("weather") { delivered = $0 }
        await suggestions.pending?.value
        calls = await client.queries
        XCTAssertEqual(calls.last?.provider, .duckDuckGo)
        XCTAssertEqual(delivered.first?.source, .provider(.duckDuckGo))
        XCTAssertEqual(delivered.first?.url.host, "search.brave.com", "Choosing a suggestion searches with the search provider")
    }

    func testSensitiveTextIsNeverSentEvenWhenRemoteSuggestionsAreOn() async throws {
        let client = CountingClient()
        let suggestions = RemoteSuggestions(settings: SearchSettings(defaults: defaults), client: client, delay: .milliseconds(5))
        for text in ["me@example.com", "localhost:3000", "~/Documents/taxes", "ghp_16C7e42F292c6912E7710c838347Ae178B4a"] {
            suggestions.request(text) { _ in }
            XCTAssertNil(suggestions.pending, text)
        }
        try await Task.sleep(for: .milliseconds(50))
        let calls = await client.queries
        XCTAssertEqual(calls, [])
    }

    func testSettingsDefaultToGoogleWithRemoteSuggestionsAndPersist() {
        let settings = SearchSettings(defaults: defaults)
        XCTAssertEqual(settings.provider, .google)
        XCTAssertTrue(settings.remoteSuggestions)
        XCTAssertNil(settings.suggestionOverride)
        XCTAssertEqual(settings.suggestionProvider, .google)

        settings.provider = .ecosia
        settings.remoteSuggestions = false
        settings.suggestionOverride = .bing
        let reopened = SearchSettings(defaults: defaults)
        XCTAssertEqual(reopened.provider, .ecosia)
        XCTAssertFalse(reopened.remoteSuggestions)
        XCTAssertEqual(reopened.suggestionProvider, .bing)
        XCTAssertEqual(SearchSettings.storedProvider(in: defaults), .ecosia)

        reopened.suggestionOverride = nil
        XCTAssertEqual(SearchSettings(defaults: defaults).suggestionProvider, .ecosia)
    }
}

private actor CountingClient: SuggestionClient {
    struct Call: Equatable {
        var query: String
        var provider: SearchProvider
    }

    private(set) var queries: [Call] = []

    func suggestions(for query: String, from provider: SearchProvider) async throws -> [String] {
        queries.append(Call(query: query, provider: provider))
        return [query + " one", query + " two"]
    }
}

final class SearchProviderTests: XCTestCase {
    private let samples: [SearchProvider: String] = [
        .google: #"["space",["spacex","space jam"],[],{"google:suggestsubtypes":[[512],[512]]}]"#,
        .duckDuckGo: #"[{"phrase":"spacex"},{"phrase":"space jam"}]"#,
        .bing: #"["space",["spacex","space jam"]]"#,
        .brave: #"["space",["spacex","space jam"]]"#,
        .ecosia: #"{"query":"space","suggestions":["spacex","space jam"],"contextData":[]}"#,
    ]

    private let empties: [SearchProvider: String] = [
        .google: #"["zzqx",[],[],{}]"#,
        .duckDuckGo: "[]",
        .bing: #"["zzqx",[]]"#,
        .brave: #"["zzqx",[]]"#,
        .ecosia: #"{"query":"zzqx","suggestions":[]}"#,
    ]

    func testEachProviderParsesItsSuggestionShape() {
        for provider in SearchProvider.allCases {
            XCTAssertEqual(provider.parseSuggestions(Data(samples[provider]!.utf8)), ["spacex", "space jam"], provider.name)
            XCTAssertEqual(provider.parseSuggestions(Data(empties[provider]!.utf8)), [], provider.name)
            XCTAssertEqual(provider.parseSuggestions(Data()), [], provider.name)
        }
    }

    func testEachProviderAsksItsOwnSuggestionEndpoint() {
        let expected: [SearchProvider: (String, String)] = [
            .google: ("suggestqueries.google.com", "q"),
            .duckDuckGo: ("duckduckgo.com", "q"),
            .bing: ("api.bing.com", "query"),
            .brave: ("search.brave.com", "q"),
            .ecosia: ("ac.ecosia.org", "q"),
        ]
        for provider in SearchProvider.allCases {
            let url = provider.suggestionURL(for: "C++ & café")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, expected[provider]!.0)
            XCTAssertEqual(items.first { $0.name == expected[provider]!.1 }?.value, "C++ & café")
        }
    }

    func testReturnBuildsTheChosenProvidersSearchURL() {
        let expected: [SearchProvider: String] = [
            .google: "https://www.google.com/search?q=space%20x%20C%2B%2B",
            .duckDuckGo: "https://duckduckgo.com/?q=space%20x%20C%2B%2B",
            .bing: "https://www.bing.com/search?q=space%20x%20C%2B%2B",
            .brave: "https://search.brave.com/search?q=space%20x%20C%2B%2B",
            .ecosia: "https://www.ecosia.org/search?q=space%20x%20C%2B%2B",
        ]
        for provider in SearchProvider.allCases {
            let url = address(from: " space x C++ ", provider: provider)
            XCTAssertEqual(url.absoluteString, expected[provider], provider.name)
            XCTAssertEqual(CompactLine.searchQuery(url.absoluteString), "space x C++", "the line shows the words for \(provider.name)")
        }
        XCTAssertEqual(address(from: "paper.design", provider: .bing).absoluteString, "https://paper.design")
    }

    func testSensitiveTextIsRejected() {
        let sensitive = [
            // URLs and hosts
            "https://example.com/private", "example.com/account", "docs.internal", "read https://example.com later",
            // IP and localhost addresses
            "localhost", "localhost:3000", "app.localhost", "192.168.1.20", "10.0.0.1:8080", "ping 172.16.0.4",
            "[::1]:8080", "fe80::1", "2001:db8::ff00:42:8329",
            // Email addresses and anything with @
            "me@example.com", "jonatas@interlinked", "@handle", "email me@example.com please",
            // Paths
            "/etc/hosts", "~/Documents/taxes.pdf", "./build/output", "../secrets", "~", "C:\\Users\\me", "open /Users/me/notes",
            // Tokens
            "ghp_16C7e42F292c6912E7710c838347Ae178B4a",
            "sk-proj-Ab3dEf6hIj9kLm2nOp5qRs8tUv1w",
            "d41d8cd98f00b204e9800998ecf8427e",
            "4111111111111111",
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            "token dGhpcyBpcyBhIHNlY3JldDEy",
            "550e8400-e29b-41d4-a716-446655440000",
            "averyveryverylongwordwithoutanyspacesatall",
            // Addresses inside other words
            "mybank.internal/accounts 2024",
            "open example.com/account?id=5 now",
        ]
        for text in sensitive {
            XCTAssertTrue(SuggestionPrivacy.isSensitive(text), text)
        }
    }

    func testOrdinaryQueriesAreAllowed() {
        let ordinary = [
            "space x", "weather tomorrow", "C++ tutorial", "iphone 17 pro max", "covid-19 vaccine",
            "how to cook rice", "node.js tutorial", "1/2 cup in grams", "a/b testing", "state-of-the-art",
            "what is 2+2", "rust vs go", "meeting at 10:30:00", "café near me", "internationalization", "site: reviews",
            "vue.js vs react", "pi is 3.14",
        ]
        for text in ordinary {
            XCTAssertFalse(SuggestionPrivacy.isSensitive(text), text)
        }
    }
}

final class LocalSuggestionTests: XCTestCase {
    private func visit(_ url: String, _ title: String) -> BrowserHistoryVisit {
        BrowserHistoryVisit(id: UUID(), url: url, title: title, visited: Date())
    }

    func testTabsAndHistoryRankByPrefixThenWordsWithTabsFirst() {
        let tabs = [
            LocalCandidate(title: "Pull requests · interlinked", url: "https://github.com/ojowwalker77/interlinked/pulls"),
            LocalCandidate(title: "Weather", url: "https://weather.com/"),
            LocalCandidate(title: "Git branching explained", url: "https://example.com/git"),
        ]
        let history = [
            visit("https://gitlab.com/explore", "Explore · GitLab"),
            visit("https://news.ycombinator.com/item?id=1", "Why git won"),
            visit("https://github.com/ojowwalker77/interlinked/pulls", "Pull requests · interlinked"),
            visit("https://github.com/features/actions", "GitHub Actions"),
        ]
        let results = LocalSuggestions.rank("git", tabs: tabs, history: history)
        XCTAssertEqual(results.map(\.url.absoluteString), [
            // Prefix of the address or title: tabs, then history newest first.
            "https://github.com/ojowwalker77/interlinked/pulls",
            "https://example.com/git",
            "https://gitlab.com/explore",
            "https://github.com/features/actions",
            // Word match only.
            "https://news.ycombinator.com/item?id=1",
        ])
        XCTAssertEqual(results.map(\.source), [.tab, .tab, .history, .history, .history])
        XCTAssertEqual(results.first?.source.label, "On this Mac")
    }

    func testEveryTypedWordMustStartAWord() {
        let tabs = [LocalCandidate(title: "Interlinked pull requests", url: "https://github.com/ojowwalker77/interlinked/pulls")]
        XCTAssertEqual(LocalSuggestions.rank("pull inter", tabs: tabs, history: []).count, 1)
        XCTAssertEqual(LocalSuggestions.rank("PULL", tabs: tabs, history: []).count, 1)
        XCTAssertTrue(LocalSuggestions.rank("ull", tabs: tabs, history: []).isEmpty)
        XCTAssertTrue(LocalSuggestions.rank("pull missing", tabs: tabs, history: []).isEmpty)
        XCTAssertTrue(LocalSuggestions.rank("  ", tabs: tabs, history: []).isEmpty)
    }

    func testATabThatDoesNotMatchKeepsTheHistoryVisitOfThatPage() {
        // The tab shows an AI label; the history visit keeps the page's own title.
        let page = "https://www.bbc.com/weather/2643743"
        let tabs = [LocalCandidate(title: "Weather forecast", url: page)]
        let history = [visit(page, "BBC Weather - London")]
        XCTAssertEqual(LocalSuggestions.rank("london", tabs: tabs, history: history).map(\.source), [.history])
        XCTAssertEqual(LocalSuggestions.rank("weather", tabs: tabs, history: history).map(\.source), [.tab])
    }

    func testAtMostEightUniquePages() {
        let history = (0..<20).map { visit("https://docs.example.com/page\($0 % 12)", "Docs \($0)") }
        let results = LocalSuggestions.rank("docs", tabs: [], history: history)
        XCTAssertEqual(results.count, LocalSuggestions.limit)
        XCTAssertEqual(Set(results.map(\.url)).count, results.count)
        XCTAssertEqual(results.first?.title, "Docs 0")
    }
}
