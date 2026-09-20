import XCTest
import WebKit

private actor FixtureJev: JevProvider {
    var calls = 0
    var failure: JevError?
    var delay: Duration
    init(failure: JevError? = nil, delay: Duration = .zero) { self.failure = failure; self.delay = delay }
    func decide(_ request: JevRequest) async throws -> JevResponse {
        calls += 1
        // Deliberately finish even when cancelled to verify stale completion protection.
        if delay != .zero { try? await Task.sleep(for: delay) }
        if let failure { throw failure }
        return JevResponse(answers: request.questions.mapValues { question in
            question.type == .choice
                ? JevAnswer(type: "choice", choice: question.criteria.keys.sorted().first, confidence: 0.9)
                : JevAnswer(type: "noul", noul: 0.9)
        })
    }
}

private actor FixtureLocalIntelligence: LocalBrowserIntelligence {
    let label: String?
    let vaultIDs: [UUID]?
    let memberGroups: [[String]]?
    let advice: String?
    let adviceDelay: Duration
    let adviceUnavailable: Bool
    private(set) var vaultInputCount = 0

    init(
        label: String? = nil,
        vaultIDs: [UUID]? = nil,
        memberGroups: [[String]]? = nil,
        advice: String? = nil,
        adviceDelay: Duration = .zero,
        adviceUnavailable: Bool = false
    ) {
        self.label = label
        self.vaultIDs = vaultIDs
        self.memberGroups = memberGroups
        self.advice = advice
        self.adviceDelay = adviceDelay
        self.adviceUnavailable = adviceUnavailable
    }

    func pageLabel(page: PageMetadata, candidates: [LabelCandidate]) async throws -> String? { label }
    func vaultMatches(query: String, visits: [HistoryVisit]) async throws -> [UUID]? {
        vaultInputCount = visits.count
        return vaultIDs
    }
    func relatedPageGroups(pages: [ResearchPage]) async throws -> [[String]]? { memberGroups }
    func navigationAdvice(_ review: NavigationReview) async throws -> String? {
        if adviceDelay != .zero { try? await Task.sleep(for: adviceDelay) }
        if adviceUnavailable { throw CancellationError() }
        return advice
    }
}

private final class JevURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw JevError.unavailable }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class JevServiceTests: XCTestCase {
    let request = JevRequest(state: "untrusted source", questions: ["page": .choice("Pick a supplied ID", ["a": "One", "b": "Two"])])

    func testValidatesIdentityAndAnswerTypesBeforeMapping() throws {
        let valid = JevResponse(answers: ["page": JevAnswer(type: "choice", choice: "a", confidence: 0.8)])
        XCTAssertNoThrow(try valid.validated(for: request))
        for response in [
            JevResponse(answers: ["page": JevAnswer(type: "choice", choice: "invented")]),
            JevResponse(answers: ["other": JevAnswer(type: "choice", choice: "a")]),
            JevResponse(answers: ["page": JevAnswer(type: "noul", noul: 0.9)]),
            JevResponse(answers: ["page": JevAnswer(type: "choice", choice: "a", probabilities: ["bad": 1])])
        ] { XCTAssertThrowsError(try response.validated(for: request)) }
        let score = JevRequest(state: "", questions: ["p": .relevant("Relevant?")])
        XCTAssertThrowsError(try JevResponse(answers: ["p": JevAnswer(type: "noul", noul: 2)]).validated(for: score))
    }
    func testCachesIdenticalDecisionsUntilExplicitlyCleared() async throws {
        let fixture = FixtureJev()
        let cached = JevService(provider: fixture, cache: JevDecisionCache(file: nil))
        _ = try await cached.decide(request); _ = try await cached.decide(request)
        let first = await fixture.calls; XCTAssertEqual(first, 1)
        await cached.reset(); _ = try await cached.decide(request)
        let afterReset = await fixture.calls; XCTAssertEqual(afterReset, 1)
        await cached.clearCache(); _ = try await cached.decide(request)
        let afterClear = await fixture.calls; XCTAssertEqual(afterClear, 2)
    }
    func testDecisionCacheSurvivesRelaunchAndExpiresAfterFiveDays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("JevDecisionCache.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 100)
        let firstProvider = FixtureJev()
        let first = JevService(provider: firstProvider, cache: JevDecisionCache(file: file, now: { clock }))
        _ = try await first.decide(request)

        let secondProvider = FixtureJev()
        let second = JevService(provider: secondProvider, cache: JevDecisionCache(file: file, now: { clock }))
        _ = try await second.decide(request)
        let cachedCalls = await secondProvider.calls; XCTAssertEqual(cachedCalls, 0)

        clock = clock.addingTimeInterval(JevDecisionCache.fiveDays + 1)
        let expired = JevService(provider: secondProvider, cache: JevDecisionCache(file: file, now: { clock }))
        _ = try await expired.decide(request)
        let expiredCalls = await secondProvider.calls; XCTAssertEqual(expiredCalls, 1)
    }
    func testCancellationAndResetCannotCacheLateProviderResponses() async throws {
        let fixture = FixtureJev(delay: .milliseconds(100)), service = JevService(provider: fixture, cache: JevDecisionCache(file: nil))
        let request = request
        let task = Task { try await service.decide(request) }
        while await fixture.calls == 0 { await Task.yield() }
        await service.reset()
        do { _ = try await task.value; XCTFail("Late completion was accepted") } catch {}
        _ = try await service.decide(request)
        let calls = await fixture.calls; XCTAssertEqual(calls, 2)
    }
    func testRateLimitsPauseInsteadOfRetrying() async throws {
        let fixture = FixtureJev(failure: .rateLimited), service = JevService(provider: fixture, cache: JevDecisionCache(file: nil))
        for _ in 0..<2 { do { _ = try await service.decide(request); XCTFail() } catch { XCTAssertEqual(error as? JevError, .rateLimited) } }
        let calls = await fixture.calls; XCTAssertEqual(calls, 1)
    }
    func testFullPageRequestsAreNotRejectedByLocalSizeOrQuestionCaps() async throws {
        let fixture = FixtureJev(), service = JevService(provider: fixture, cache: JevDecisionCache(file: nil))
        let fullPage = JevRequest(state: String(repeating: "Page content ", count: 50_000),
            questions: Dictionary(uniqueKeysWithValues: (0..<850).map { ("p\($0)", JevQuestion.relevant("Useful?")) }))
        let response = try await service.decide(fullPage)
        XCTAssertEqual(response.answers.count, 850)
        let calls = await fixture.calls; XCTAssertEqual(calls, 1)
    }
    func testOldNavigationAndQueryGenerationsAreRejected() {
        var revision = RequestRevision()
        let old = revision.advance(), current = revision.advance()
        XCTAssertFalse(revision.accepts(old)); XCTAssertTrue(revision.accepts(current))
    }
    func testOpenRouterUsesDedicatedDecisionsSchema() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        XCTAssertEqual(OpenRouterJev.endpoint.absoluteString, "https://openrouter.ai/api/alpha/decisions")
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.13")
        XCTAssertEqual(body["state"] as? String, "untrusted source")
        XCTAssertNil(body["messages"])
        XCTAssertEqual((body["provider"] as? [String: String])?["data_collection"], "deny")
        let fixture = Data(#"{"id":"gen-test","model":"typesafe/jev-1.13-20260917","answers":{"page":{"type":"choice","choice":"a","confidence":0.75,"probabilities":{"a":0.84,"b":0.16}}},"usage":{"input_tokens":100,"output_tokens":5}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(JevResponse.self, from: fixture).validated(for: request).answers["page"]?.choice, "a")
    }
    func testAbsentKeyDoesNotStartNetworkWork() async {
        let provider = OpenRouterJev(credential: { throw JevError.noKey })
        do { _ = try await provider.decide(request); XCTFail() } catch { XCTAssertEqual(error as? JevError, .noKey) }
    }
    func testRelayUsesSignedAppTransactionInsteadOfAnEmbeddedKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevURLProtocol.self]
        let session = URLSession(configuration: configuration)
        JevURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Interlinked-App-Transaction"), "apple-signed-transaction")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let data = try JSONEncoder().encode(JevResponse(answers: ["page": JevAnswer(type: "choice", choice: "a", confidence: 0.9)]))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        defer { JevURLProtocol.handler = nil }
        let provider = InterlinkedRelayJev(endpoint: URL(string: "https://relay.interlinked.test/v1/jev")!,
                                           session: session,
                                           appTransaction: { "apple-signed-transaction" })
        let response = try await provider.decide(request)
        XCTAssertEqual(response.answers["page"]?.choice, "a")
    }
    func testCriticalReadingRunsByDefaultAndPersistsOnRequestMode() throws {
        let name = "CriticalReadingPreferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertTrue(JevPreferences.enabled(in: defaults))
        XCTAssertEqual(CriticalReadingMode(defaults: defaults), .automatic)

        defaults.set(false, forKey: JevPreferences.enabledKey)
        CriticalReadingMode.onRequest.save(to: defaults)
        XCTAssertFalse(JevPreferences.enabled(in: defaults))
        XCTAssertEqual(CriticalReadingMode(defaults: defaults), .onRequest)
    }
}

final class BrowserIntelligenceTests: XCTestCase {
    private func page() -> PageMetadata {
        PageMetadata(document: "doc", url: "https://example.com/products/browser", title: "Example Browser",
                     heading: "A focused browser", summary: "Browse without losing context", breadcrumbs: ["Products"])
    }

    private func visit(_ index: Int) -> HistoryVisit {
        HistoryVisit(id: UUID(), url: "https://example.com/\(index)", title: "Saved page \(index)",
                     summary: "Research note \(index)", visited: Date(timeIntervalSince1970: TimeInterval(index)))
    }

    func testAppleLabelWinsWithoutCallingJev() async throws {
        let page = page(), candidates = ContextLabels.candidates(page)
        let expected = try XCTUnwrap(candidates.last?.text)
        let local = FixtureLocalIntelligence(label: expected)
        let jev = FixtureJev()
        let intelligence = BrowserIntelligence(jev: JevService(provider: jev, cache: JevDecisionCache(file: nil)), local: local)

        let decision = try await intelligence.refinePageLabel(page: page, candidates: candidates, allowJev: true)
        let calls = await jev.calls

        XCTAssertEqual(decision?.value, expected)
        XCTAssertEqual(decision?.source, .appleIntelligence)
        XCTAssertEqual(calls, 0)
    }

    func testInvalidAppleLabelFallsBackToJevOnlyWhenAllowed() async throws {
        let page = page(), candidates = ContextLabels.candidates(page)
        let local = FixtureLocalIntelligence(label: "invented label")
        let jev = FixtureJev()
        let intelligence = BrowserIntelligence(jev: JevService(provider: jev, cache: JevDecisionCache(file: nil)), local: local)

        let localOnly = try await intelligence.refinePageLabel(page: page, candidates: candidates, allowJev: false)
        let localOnlyCalls = await jev.calls
        XCTAssertNil(localOnly)
        XCTAssertEqual(localOnlyCalls, 0)

        let fallback = try await intelligence.refinePageLabel(page: page, candidates: candidates, allowJev: true)
        let fallbackCalls = await jev.calls
        XCTAssertEqual(fallback?.source, .jev)
        XCTAssertTrue(candidates.contains { $0.text == fallback?.value })
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testVaultUsesOnlySixLocalCandidatesAndValidatesReturnedIDs() async throws {
        let visits = (0..<9).map(visit)
        let local = FixtureLocalIntelligence(vaultIDs: [visits[4].id, UUID(), visits[1].id])
        let jev = FixtureJev()
        let intelligence = BrowserIntelligence(jev: JevService(provider: jev, cache: JevDecisionCache(file: nil)), local: local)

        let decision = try await intelligence.vaultMatches(query: "research", visits: visits, allowJev: true)
        let localCount = await local.vaultInputCount
        let jevCalls = await jev.calls

        XCTAssertEqual(decision?.source, .appleIntelligence)
        XCTAssertEqual(decision?.value.map(\.id), [visits[4].id, visits[1].id])
        XCTAssertEqual(localCount, 6)
        XCTAssertEqual(jevCalls, 0)
    }

    func testRelatedGroupsRejectUnknownAndDuplicateMembers() async throws {
        let pages = [
            ResearchPage(id: "one", title: "First", detail: "", host: "one.test"),
            ResearchPage(id: "two", title: "Second", detail: "", host: "two.test"),
            ResearchPage(id: "three", title: "Third", detail: "", host: "three.test")
        ]
        let local = FixtureLocalIntelligence(memberGroups: [["two", "unknown", "one"], ["one", "three"]])
        let intelligence = BrowserIntelligence(jev: JevService(provider: FixtureJev(), cache: JevDecisionCache(file: nil)), local: local)

        let decision = try await intelligence.relatedPageGroups(pages: pages, jevPages: [], allowJev: false)

        XCTAssertEqual(decision?.source, .appleIntelligence)
        XCTAssertEqual(decision?.value, [ResearchGroup(id: "one", title: "First", members: ["one", "two"])])
    }

    func testNavigationAdviceRetainsTheWarningWhenAppleIntelligenceIsUnavailable() async throws {
        let local = FixtureLocalIntelligence(adviceUnavailable: true)
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: FixtureJev(), cache: JevDecisionCache(file: nil)),
            local: local
        )
        let review = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://person:secret@example.test")),
            source: nil,
            kind: .link
        )
        let advice = await intelligence.navigationAdvice(review, timeout: .milliseconds(50))
        XCTAssertNil(advice)
        XCTAssertEqual(review.disposition, .warn)
    }

    func testNavigationAdviceDeadlineDoesNotWaitForTheModel() async throws {
        let local = FixtureLocalIntelligence(advice: "Too late", adviceDelay: .seconds(2))
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: FixtureJev(), cache: JevDecisionCache(file: nil)),
            local: local
        )
        let review = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://person:secret@example.test")),
            source: nil,
            kind: .link
        )
        let clock = ContinuousClock()
        let start = clock.now
        let advice = await intelligence.navigationAdvice(review, timeout: .milliseconds(40))
        XCTAssertNil(advice)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
        XCTAssertEqual(review.disposition, .warn)
    }
}

@MainActor final class ContextFeatureTests: XCTestCase {
    func page(_ url: String = "https://www.apple.com/iphone-18-pro/buy") -> PageMetadata {
        PageMetadata(document: "doc1", url: url, title: "Buy iPhone 18 Pro - Apple", heading: "Buy iPhone 18 Pro", summary: "Choose your iPhone", breadcrumbs: ["iPhone 18 Pro", "Buy"])
    }
    func testLabelsUseLocalCandidatesAndOpaquePathsFallBackToMetadata() {
        let choices = ContextLabels.candidates(page())
        XCTAssertEqual(choices.first?.text, "Apple · Buy iPhone 18 Pro")
        XCTAssertTrue(choices.contains { $0.text == "Apple · iPhone 18 Pro · Buy" })
        XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
        let opaque = page("https://www.apple.com/products/987654321")
        XCTAssertFalse(ContextLabels.candidates(opaque).first!.text.contains("987654321"))
        let response = JevResponse(answers: ["label": JevAnswer(type: "choice", choice: choices.last?.id, confidence: 0.9)])
        XCTAssertEqual(ContextLabels.selected(response, candidates: choices), "apple.com")
        XCTAssertNil(ContextLabels.selected(JevResponse(answers: ["label": JevAnswer(type: "choice", choice: "new words", confidence: 1)]), candidates: choices))
        XCTAssertFalse(ContextLabels.request(page("https://www.apple.com/buy?token=secret"), candidates: choices).state.contains("secret"))
        XCTAssertEqual(page().origin, "https://www.apple.com")
    }
    func testMeaningFindReturnsOnlyOriginalPassagesInDocumentOrder() {
        let passages = [PagePassage(id: "p1", text: "Termination policy: cancel within 30 days."), PagePassage(id: "p2", text: "Delivery takes five days.")]
        let request = PassageDecisions.findRequest(query: "cancellation conditions", passages: passages)
        XCTAssertEqual(Set(request.questions.keys), ["p1", "p2", "best_match"])
        let response = JevResponse(answers: ["p1": JevAnswer(type: "score", score: 3.9), "p2": JevAnswer(type: "score", score: 0.4), "fabricated": JevAnswer(type: "score", score: 4)])
        XCTAssertEqual(PassageDecisions.matches(response, passages: passages), [passages[0]])
        XCTAssertTrue(PassageDecisions.matches(JevResponse(answers: [:]), passages: passages).isEmpty)
        XCTAssertLessThanOrEqual(PassageDecisions.candidates(query: "", passages: (0..<100).map { PagePassage(id: "p\($0)", text: "Text") }).count, 40)
    }
    func testIntentScoresRankSupportBeforeIncidentalWordStems() throws {
        let passages = [PagePassage(id: "body", text: "Recursos que ajudam nas fotos.", role: "passage"),
                        PagePassage(id: "support", text: "Suporte", role: "link"),
                        PagePassage(id: "help", text: "Ajuda", role: "link")]
        let request = PassageDecisions.findRequest(query: "ajuda", passages: passages)
        let response = JevResponse(answers: ["best_match": JevAnswer(type: "choice", choice: "help"), "body": JevAnswer(type: "score", score: 1),
                                            "support": JevAnswer(type: "score", score: 3.8),
                                            "help": JevAnswer(type: "score", score: 4)])
        XCTAssertNoThrow(try response.validated(for: request))
        XCTAssertEqual(PassageDecisions.matches(response, passages: passages).map(\.id), ["help", "support"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions["support"]?["type"] as? String, "score")
        XCTAssertEqual((questions["support"]?["criteria"] as? [String])?.count, 5)
        XCTAssertThrowsError(try JevResponse(answers: ["support": JevAnswer(type: "score", score: 5)]).validated(for: request))
    }
    func testBestAnswerSelectionOutranksIndependentScoresAndSurvivesCutoff() throws {
        let passages = [PagePassage(id: "time", text: "Delivery tomorrow", role: "passage"),
                        PagePassage(id: "price", text: "Shipping is free", role: "heading")]
        let request = PassageDecisions.findRequest(query: "delivery price", passages: passages)
        var response = JevResponse(answers: ["best_match": JevAnswer(type: "choice", choice: "price"),
                                            "time": JevAnswer(type: "score", score: 2.9), "price": JevAnswer(type: "score", score: 2.7)])
        XCTAssertNoThrow(try response.validated(for: request))
        XCTAssertEqual(PassageDecisions.matches(response, passages: passages).map(\.id), ["price", "time"])
        response.answers["best_match"] = JevAnswer(type: "choice", choice: "none")
        XCTAssertTrue(PassageDecisions.matches(response, passages: passages).isEmpty)
    }
    func testDifferentLanguageQueryStillIncludesShortHeadingsAndControls() {
        let pages = (0..<80).map { PagePassage(id: "p\($0)", text: "A long body paragraph \($0)", role: "passage") } +
            [PagePassage(id: "mars", text: "Mars", role: "heading"), PagePassage(id: "support", text: "Suporte", role: "link")]
        let selected = PassageDecisions.candidates(query: "marte", passages: pages)
        XCTAssertTrue(selected.contains { $0.id == "mars" }); XCTAssertTrue(selected.contains { $0.id == "support" })
        XCTAssertLessThanOrEqual(selected.count, 40)
    }

    func testReadingUsesFixedCategoriesAndPreservesEvidenceWithoutTrainingExamples() {
        let passages = [PagePassage(id: "p1", text: "You must buy now or disappoint everyone."), PagePassage(id: "p2", text: "The study reports a range of estimates.")]
        let request = PassageDecisions.readingRequest(passages)
        XCTAssertEqual(Set(request.questions["p1"]!.criteria.keys), Set(PassageDecisions.Signal.allCases.map(\.rawValue)))
        XCTAssertEqual(request.questions["p1"]?.instructions, PassageDecisions.classificationInstruction + " Passage ID: p1.")
        XCTAssertFalse(request.state.contains("examples"))
        let response = JevResponse(answers: ["p1": JevAnswer(type: "choice", choice: "pressure", confidence: 0.8), "p2": JevAnswer(type: "choice", choice: "uncertain", confidence: 0.9)])
        let found = PassageDecisions.findings(response, passages: passages)
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.passage, passages[0]); XCTAssertEqual(found.first?.signal, .pressure)
    }
    func testReadingSuppressesShortFragmentsLowConfidenceAndWeakChoiceProbabilities() {
        let passages = [
            PagePassage(id: "fragment", text: "Irresistível."),
            PagePassage(id: "weak", text: "Order by Friday to receive free standard shipping."),
            PagePassage(id: "split", text: "This wording contains enough words to inspect responsibly."),
            PagePassage(id: "clear", text: "Buy now or prove that you do not care about your family.")
        ]
        let response = JevResponse(answers: [
            "fragment": JevAnswer(type: "choice", choice: "loaded", confidence: 0.99, probabilities: ["loaded": 0.99]),
            "weak": JevAnswer(type: "choice", choice: "pressure", confidence: PassageDecisions.displayConfidence - 0.01),
            "split": JevAnswer(type: "choice", choice: "loaded", confidence: 0.9, probabilities: ["loaded": PassageDecisions.displayCategoryProbability - 0.01, "none": 0.51]),
            "clear": JevAnswer(type: "choice", choice: "pressure", confidence: 0.4, probabilities: ["pressure": 0.55, "certainty": 0.4, "none": 0.05])
        ])
        XCTAssertEqual(PassageDecisions.findings(response, passages: passages), [.init(passage: passages[3], signal: .pressure)])
        XCTAssertTrue(PassageDecisions.classificationInstruction.contains("Default to none"))
        XCTAssertTrue(PassageDecisions.Signal.pressure.explanation.contains("normal deadline"))
        XCTAssertEqual(PassageDecisions.Signal.financialInterest.rawValue, "financial_interest")
        XCTAssertEqual(PassageDecisions.Signal.financialInterest.label, "Possible financial interest")
        XCTAssertTrue(PassageDecisions.Signal.financialInterest.explanation.contains("concrete reason"))
        XCTAssertEqual(PassageDecisions.Signal.politicalBias.rawValue, "political_bias")
        XCTAssertEqual(PassageDecisions.Signal.politicalBias.label, "Possible political bias")
        XCTAssertTrue(PassageDecisions.Signal.politicalBias.explanation.contains("partisan political framing"))
    }
    func testReadingFiltersFragmentsBoundsEvidenceAndBatchesLongPages() {
        let passages = [PagePassage(id: "short", text: "Too good."),
                        PagePassage(id: "heading", text: "A meaningful heading with enough words", role: "heading")] +
            (0..<85).map { PagePassage(id: "p\($0)", text: String(repeating: "substantive ", count: 200), role: "passage") }
        let candidates = PassageDecisions.readingCandidates(passages)
        let batches = PassageDecisions.readingBatches(candidates)
        XCTAssertEqual(candidates.count, 85)
        XCTAssertEqual(batches.map(\.count), [40, 40, 5])
        let request = PassageDecisions.readingRequest([candidates[0]])
        XCTAssertLessThanOrEqual(request.state.count, PassageDecisions.readingTextLimit + 120)
        XCTAssertEqual(Set(request.questions.keys), ["p0"])
    }
    func testReadingCanFlagLikelyAIGeneratedTextWithoutPresentingLowConfidenceGuesses() {
        let passages = [PagePassage(id: "likely", text: "A passage with repeated model-like patterns."),
                        PagePassage(id: "weak", text: "A short ordinary sentence.")]
        let response = JevResponse(answers: [
            "likely": JevAnswer(type: "choice", choice: "ai_generated", confidence: 0.75),
            "weak": JevAnswer(type: "choice", choice: "ai_generated", confidence: PassageDecisions.displayConfidence - 0.01)
        ])
        let found = PassageDecisions.findings(response, passages: passages)
        XCTAssertEqual(found, [.init(passage: passages[0], signal: .aiGenerated)])
        XCTAssertTrue(PassageDecisions.Signal.aiGenerated.explanation.contains("not proof"))
    }
    func testHistoryOnlyRanksRealVisitsAndDeletionPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = BrowsingHistory(file: dir.appendingPathComponent("history.json"))
        history.record(page()); history.record(page())
        history.record(page("https://www.apple.com/buy?token=secret"))
        XCTAssertEqual(history.visits.count, 1)
        let visits = history.candidates("phone I wanted"), id = try XCTUnwrap(visits.first?.id)
        let request = BrowsingHistory.request("phone I wanted", visits: visits)
        XCTAssertFalse(request.state.contains("https://"))
        let response = JevResponse(answers: [id.uuidString: JevAnswer(type: "noul", noul: 0.95), "invented": JevAnswer(type: "noul", noul: 1)])
        XCTAssertEqual(BrowsingHistory.ranked(response, visits: visits).map(\.id), [id])
        history.remove(id)
        XCTAssertTrue(BrowsingHistory(file: dir.appendingPathComponent("history.json")).visits.isEmpty)
    }
    func testResearchGroupsKeepOriginalOrderAndUseExistingNames() {
        let pages = [ResearchPage(id: "3", title: "Sony A7 camera review", detail: "", host: "reviews.test"), ResearchPage(id: "1", title: "Sony A7 camera shop", detail: "", host: "store.test"), ResearchPage(id: "2", title: "Cooking dinner", detail: "", host: "food.test")]
        XCTAssertEqual(ResearchRelations.groups(pages).first?.members, ["3", "1"])
        let groups = ResearchRelations.groups(pages, response: JevResponse(answers: ["3_1": JevAnswer(type: "noul", noul: 0.9)]))
        XCTAssertEqual(groups.first?.title, pages[0].title)
        XCTAssertEqual(pages.map(\.id), ["3", "1", "2"])
        XCTAssertTrue(ResearchRelations.groups(pages, response: JevResponse(answers: [:])).isEmpty)
    }
    func testSensitiveAndLocalPagesCannotBeShared() {
        XCTAssertFalse(page("http://127.0.0.1:8000/").publicWebPage)
        XCTAssertFalse(page("http://company.local/").publicWebPage)
        XCTAssertFalse(page("https://person:secret@example.com/").publicWebPage)
        var sensitive = page(); sensitive.sensitive = true
        XCTAssertFalse(sensitive.publicWebPage)
        XCTAssertTrue(page().publicWebPage)
    }
    func testPersonalFiltersMatchVisibleHeadingsLocallyAndPersistPerSite() throws {
        let passages = [
            PagePassage(id: "news", text: "Latest from our changelog", role: "heading"),
            PagePassage(id: "feed", text: "A repository you follow was updated.", role: "passage")
        ]
        XCTAssertEqual(PersonalFilterDecisions.localMatches(
            description: "idgaf about this latest from our changelog bs", passages: passages
        ).map(\.id), ["news"])
        let media = [PageFilterCandidate(id: "image", text: "Hero", role: "image", context: ""),
                     PageFilterCandidate(id: "video", text: "Film", role: "video", context: "")]
        XCTAssertEqual(PersonalFilterDecisions.localMatches(description: "all images and videos", candidates: media).map(\.id),
                       ["image", "video"])
        let words = [PageFilterCandidate(id: "pace", text: "pace", role: "text token", context: "We must pace the frontier")]
        XCTAssertEqual(PersonalFilterDecisions.localMatches(description: "the word pace", candidates: words).map(\.id), ["pace"])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("filters.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let filters = PersonalFilters(file: file)
        let rule = try XCTUnwrap(filters.add("Hide the changelog", host: "www.github.com"))
        XCTAssertEqual(filters.rules(for: "github.com").map(\.id), [rule.id])
        filters.toggle(rule.id)
        XCTAssertEqual(PersonalFilters(file: file).rules(for: "www.github.com").first?.isEnabled, false)
    }
    func testPersonalFilterSemanticMatchesRequireHighConfidenceAndOriginalIDs() {
        let candidates = [PageFilterCandidate(id: "card", text: "Product announcements", role: "heading", context: ""),
                          PageFilterCandidate(id: "feed", text: "Your activity", role: "heading", context: "")]
        let response = JevResponse(answers: [
            "card": JevAnswer(type: "noul", noul: PersonalFilterDecisions.matchThreshold),
            "feed": JevAnswer(type: "noul", noul: PersonalFilterDecisions.matchThreshold - 0.01),
            "invented": JevAnswer(type: "noul", noul: 1)
        ])
        XCTAssertEqual(PersonalFilterDecisions.matches(response, candidates: candidates), [candidates[0]])
        let request = PersonalFilterDecisions.request(description: "Hide product news", candidates: candidates)
        XCTAssertEqual(Set(request.questions.keys), Set(candidates.map(\.id)))
        XCTAssertTrue(request.state.contains("Hide product news"))
        XCTAssertTrue(request.state.contains("text"))
    }
}

@MainActor final class PageTextBridgeTests: XCTestCase, WKNavigationDelegate {
    var finished: XCTestExpectation?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?.fulfill() }
    func testExtractionKeepsLateHeadingsShortPricesAndEntireLongPassages() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Long page loaded")
        let paragraphs = (0..<850).map { "<p>Section \($0) " + String(repeating: "page content ", count: 10) + "</p>" }.joined()
        let long = String(repeating: "Detailed delivery information. ", count: 60) + "Final price: free."
        view.loadHTMLString("<html><body>" + paragraphs + "<h6>Frete grátis sempre</h6><p>R$ 0</p><p>" + long + "</p></body></html>", baseURL: URL(string: "https://fixture.example/delivery"))
        await fulfillment(of: [finished!], timeout: 10)
        let extracted = try await PageTextBridge.extract(view)
        XCTAssertEqual(extracted.passages.count, 853)
        XCTAssertTrue(extracted.passages.contains { $0.text == "Frete grátis sempre" && $0.role == "heading" })
        XCTAssertTrue(extracted.passages.contains { $0.text == "R$ 0" })
        XCTAssertEqual(extracted.passages.last?.text, long)
        XCTAssertFalse(extracted.truncated)
        let request = PassageDecisions.findRequest(query: "preço de entrega", passages: extracted.passages)
        XCTAssertEqual(request.questions.count, extracted.passages.count + 1)
        XCTAssertTrue(request.state.contains("Frete grátis sempre"))
    }
    func testReadingAnnotationsAnchorToSourceDismissAndInvalidateChangedText() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Annotation fixture loaded")
        view.loadHTMLString("<html><body><p id='source' style='margin:80px 0 0 100px;width:300px'>This is a passage for testing the annotation interface.</p></body></html>", baseURL: URL(string: "https://fixture.example/reading"))
        await fulfillment(of: [finished!], timeout: 10)
        let extract = try await PageTextBridge.extract(view)
        let passage = try XCTUnwrap(extract.passages.first)
        let shown = await PageTextBridge.annotate([.init(passage: passage, signal: .loaded)], document: extract.document, view: view)
        XCTAssertTrue(shown)
        let anchored = try await view.callAsyncJavaScript("""
            const host=document.querySelector('[id^="interlinked-reading-"]'), card=host.shadowRoot.querySelector('aside');
            const source=document.getElementById('source').getBoundingClientRect(), r=card.getBoundingClientRect();
            const beside=r.left>=source.right && r.right<=innerWidth && r.top>=0 && r.bottom<=innerHeight;
            document.body.dispatchEvent(new MouseEvent('click',{bubbles:true}));
            const dismissed=card.hidden;
            document.getElementById('source').dispatchEvent(new MouseEvent('click',{bubbles:true}));
            return beside && dismissed && !card.hidden && card.textContent.includes('Loaded wording');
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(anchored as? Bool, true)
        let invalidated = try await view.callAsyncJavaScript("""
            document.getElementById('source').textContent='The source changed.';
            await new Promise(resolve=>setTimeout(resolve,100));
            return !document.querySelector('[id^="interlinked-reading-"]');
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(invalidated as? Bool, true)
        let stale = await PageTextBridge.annotate([.init(passage: passage, signal: .loaded)], document: extract.document, view: view)
        XCTAssertFalse(stale)
    }
    func testReadingAnnotationsNeverScrollToOffscreenFindings() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Offscreen annotation fixture loaded")
        view.loadHTMLString("<html><body><p id='source' style='margin-top:1600px'>An offscreen passage that should wait for the reader.</p></body></html>", baseURL: URL(string: "https://fixture.example/no-scroll"))
        await fulfillment(of: [finished!], timeout: 10)
        let extract = try await PageTextBridge.extract(view)
        let passage = try XCTUnwrap(extract.passages.first)
        let before = try await view.callAsyncJavaScript("return scrollY;", arguments: [:], in: nil, contentWorld: .defaultClient) as? Double
        let shown = await PageTextBridge.annotate([.init(passage: passage, signal: .loaded)], document: extract.document, view: view)
        let state = try await view.callAsyncJavaScript("""
            const card=document.querySelector('[id^="interlinked-reading-"]').shadowRoot.querySelector('aside');
            return {scrollY, hidden:card.hidden};
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertTrue(shown)
        XCTAssertEqual(before, 0)
        XCTAssertEqual(state?["scrollY"] as? Double, before)
        XCTAssertEqual(state?["hidden"] as? Bool, true)
    }
    func testExtractionAndHighlightRejectChangedTextAndDocuments() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Fixture loaded")
        view.loadHTMLString("""
            <html><head><title>Terms</title><meta name="description" content="Cancellation details"></head><body><main>
            <nav><a href="/support">Suporte</a></nav><h1>Mars</h1><h2>Terms and conditions</h2><p id="policy">Termination policy: cancel within 30 days of purchase.</p>
            <form><textarea>Private account note never extract this.</textarea><input type="password" value="secret"></form>
            <p hidden>Hidden secret never extract this.</p></main></body></html>
            """, baseURL: URL(string: "https://fixture.example/terms"))
        await fulfillment(of: [finished!], timeout: 10)
        let metadata = try await PageTextBridge.metadata(view)
        XCTAssertTrue(metadata.sensitive)
        let extracted = try await PageTextBridge.extract(view)
        XCTAssertFalse(extracted.passages.map(\.text).joined().contains("secret"))
        XCTAssertFalse(extracted.passages.map(\.text).joined().contains("account"))
        XCTAssertTrue(extracted.passages.contains { $0.text == "Suporte" && $0.role == "link" })
        XCTAssertTrue(extracted.passages.contains { $0.text == "Mars" && $0.role == "heading" })
        let passage = try XCTUnwrap(extracted.passages.first { $0.text.hasPrefix("Termination") })
        let shown = await PageTextBridge.highlight(passage, document: extracted.document, view: view)
        XCTAssertTrue(shown)
        let yellow = try await view.callAsyncJavaScript("return Array.from(document.querySelectorAll('style')).some(s => s.textContent.includes('#ffe66a')) || !!document.querySelector('[data-interlinked-marked]');", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(yellow as? Bool, true)
        _ = try await view.evaluateJavaScript("document.getElementById('policy').textContent = 'Changed cancellation terms.'")
        let stale = await PageTextBridge.highlight(passage, document: extracted.document, view: view)
        XCTAssertFalse(stale)
        let fresh = try await PageTextBridge.extract(view)
        XCTAssertTrue(fresh.passages.contains { $0.text == "Changed cancellation terms." })
        let wrongDocument = await PageTextBridge.highlight(fresh.passages[0], document: "old-document", view: view)
        XCTAssertFalse(wrongDocument)
    }
    func testPersonalFilterHidesItsCardWithoutAffectingReadingClearOrThePage() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Personal filter fixture loaded")
        view.loadHTMLString("""
            <html><body><main>
              <article id='feed'><h1>Home</h1><p>Your repository activity remains visible.</p></article>
              <section id='changelog' style='border:1px solid #333;border-radius:12px;padding:12px'>
                <h2>Latest from our changelog</h2><p>Weekly product announcements.</p>
              </section>
            </main></body></html>
            """, baseURL: URL(string: "https://github.com/"))
        await fulfillment(of: [finished!], timeout: 10)
        let extract = try await PageTextBridge.extract(view)
        let heading = try XCTUnwrap(extract.passages.first { $0.text == "Latest from our changelog" })
        let rule = UUID()
        let counts = await PageTextBridge.applyFilters([rule: [heading]], document: extract.document, view: view)
        XCTAssertEqual(counts?[rule], 1)
        let hidden = try await view.callAsyncJavaScript(
            "return {card:getComputedStyle(document.getElementById('changelog')).display,feed:getComputedStyle(document.getElementById('feed')).display,scrollY};",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(hidden?["card"] as? String, "none")
        XCTAssertNotEqual(hidden?["feed"] as? String, "none")
        XCTAssertEqual(hidden?["scrollY"] as? Double, 0)

        PageTextBridge.clear(view)
        let stillHidden = try await view.callAsyncJavaScript(
            "return getComputedStyle(document.getElementById('changelog')).display;",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(stillHidden as? String, "none")
        await PageTextBridge.clearFilters(view)
        let restored = try await view.callAsyncJavaScript(
            "return getComputedStyle(document.getElementById('changelog')).display;",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertNotEqual(restored as? String, "none")
    }
    func testPersonalFilterCanHideImagesAndVideosAsLocalMediaTargets() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Media filter fixture loaded")
        view.loadHTMLString("""
            <html><body><main><h1>Products</h1>
              <picture id='picture'><img id='hero' alt='Hero product' style='display:block;width:120px;height:80px'></picture>
              <video id='movie' aria-label='Product film' style='display:block;width:120px;height:80px'></video>
              <p id='details'>Product details stay visible.</p>
            </main></body></html>
            """, baseURL: URL(string: "https://store.example/"))
        await fulfillment(of: [finished!], timeout: 10)
        let extract = try await PageTextBridge.extractFilterCandidates(view)
        let media = extract.candidates.filter { $0.role == "image" || $0.role == "video" }
        XCTAssertEqual(Set(media.map(\.role)), ["image", "video"])
        let rule = UUID()
        let counts = await PageTextBridge.applyFilterCandidates([rule: media], document: extract.document, view: view)
        XCTAssertEqual(counts?[rule], 2)
        let state = try await view.callAsyncJavaScript(
            "return {picture:getComputedStyle(document.getElementById('picture')).display,video:getComputedStyle(document.getElementById('movie')).display,details:getComputedStyle(document.getElementById('details')).display,scrollY};",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(state?["picture"] as? String, "none")
        XCTAssertEqual(state?["video"] as? String, "none")
        XCTAssertNotEqual(state?["details"] as? String, "none")
        XCTAssertEqual(state?["scrollY"] as? Double, 0)
        let dynamic = try await view.callAsyncJavaScript("""
            const image=document.createElement('img');image.id='dynamic';image.alt='Loaded later';document.body.append(image);
            return getComputedStyle(image).display;
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(dynamic as? String, "none")
    }
    func testPersonalFilterRedactsRequestedWordsWithoutRewritingPageText() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Word filter fixture loaded")
        view.loadHTMLString("<html><body><h1>We Must Pace the Frontier</h1><p>Pace matters, but pacemaker must remain.</p></body></html>",
                            baseURL: URL(string: "https://essay.example/"))
        await fulfillment(of: [finished!], timeout: 10)
        let extract = try await PageTextBridge.extractFilterCandidates(view)
        let matches = PersonalFilterDecisions.localMatches(description: "the word pace", candidates: extract.candidates)
            .filter { $0.role == "text token" }
        let rule = UUID()
        let counts = await PageTextBridge.applyFilterCandidates([rule: matches], document: extract.document, view: view)
        XCTAssertEqual(counts?[rule], 2)
        let state = try await view.callAsyncJavaScript("""
            return {text:document.body.innerText,
                    filterStyles:Array.from(document.querySelectorAll('style')).filter(style=>style.id.startsWith('interlinked-personal-filters-')).length,
                    highlights:CSS.highlights.size,scrollY};
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertTrue((state?["text"] as? String)?.contains("We Must Pace the Frontier") == true)
        XCTAssertEqual(state?["filterStyles"] as? Int, 1)
        XCTAssertEqual(state?["highlights"] as? Int, 1)
        XCTAssertEqual(state?["scrollY"] as? Double, 0)
    }
    func testPersonalFilterExposesSemanticTextRangesWithoutAKeywordParser() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Semantic text fixture loaded")
        view.loadHTMLString("<html><body><article><p>September 2026</p><p>The essay remains readable.</p></article></body></html>",
                            baseURL: URL(string: "https://essay.example/"))
        await fulfillment(of: [finished!], timeout: 10)
        let extract = try await PageTextBridge.extractFilterCandidates(view)
        let date = try XCTUnwrap(extract.candidates.first { $0.text == "September 2026" && $0.role == "text range" })
        let response = JevResponse(answers: [date.id: JevAnswer(type: "noul", noul: 0.96)])
        XCTAssertEqual(PersonalFilterDecisions.matches(response, candidates: [date]), [date])

        let rule = UUID()
        let counts = await PageTextBridge.applyFilterCandidates([rule: [date]], document: extract.document, view: view)
        XCTAssertEqual(counts?[rule], 1)
        let state = try await view.callAsyncJavaScript("return {text:document.body.innerText,highlights:CSS.highlights.size,scrollY};",
                                                       arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertTrue((state?["text"] as? String)?.contains("September 2026") == true)
        XCTAssertEqual(state?["highlights"] as? Int, 1)
        XCTAssertEqual(state?["scrollY"] as? Double, 0)
    }

    func testBackgroundDiscardProbeFailsClosedForUnsavedForms() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.navigationDelegate = self
        finished = expectation(description: "Discard safeguard fixture loaded")
        view.loadHTMLString("""
            <html><body style='height:2000px'>
              <input id='title' value=''><div id='editor' contenteditable='true'></div>
            </body></html>
            """, baseURL: URL(string: "https://fixture.example/discard"))
        await fulfillment(of: [finished!], timeout: 10)

        var probe = BrowserDiscardProbe.decode(try await view.evaluateJavaScript(BrowserDiscardProbe.script))
        XCTAssertEqual(probe, BrowserDiscardProbe(safe: true, scrollY: 0))

        _ = try await view.evaluateJavaScript("document.getElementById('title').value = 'unfinished'")
        probe = BrowserDiscardProbe.decode(try await view.evaluateJavaScript(BrowserDiscardProbe.script))
        XCTAssertEqual(probe?.safe, false)
    }
}
