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
    func testCachesIdenticalDecisionsAndResetReleasesThem() async throws {
        let fixture = FixtureJev()
        let cached = JevService(provider: fixture)
        _ = try await cached.decide(request); _ = try await cached.decide(request)
        let first = await fixture.calls; XCTAssertEqual(first, 1)
        await cached.reset(); _ = try await cached.decide(request)
        let second = await fixture.calls; XCTAssertEqual(second, 2)
    }
    func testCancellationAndResetCannotCacheLateProviderResponses() async throws {
        let fixture = FixtureJev(delay: .milliseconds(100)), service = JevService(provider: fixture)
        let request = request
        let task = Task { try await service.decide(request) }
        while await fixture.calls == 0 { await Task.yield() }
        await service.reset()
        do { _ = try await task.value; XCTFail("Late completion was accepted") } catch {}
        _ = try await service.decide(request)
        let calls = await fixture.calls; XCTAssertEqual(calls, 2)
    }
    func testRateLimitsPauseInsteadOfRetrying() async throws {
        let fixture = FixtureJev(failure: .rateLimited), service = JevService(provider: fixture)
        for _ in 0..<2 { do { _ = try await service.decide(request); XCTFail() } catch { XCTAssertEqual(error as? JevError, .rateLimited) } }
        let calls = await fixture.calls; XCTAssertEqual(calls, 1)
    }
    func testFullPageRequestsAreNotRejectedByLocalSizeOrQuestionCaps() async throws {
        let fixture = FixtureJev(), service = JevService(provider: fixture)
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
        XCTAssertFalse(request.state.contains("examples"))
        let response = JevResponse(answers: ["p1": JevAnswer(type: "choice", choice: "pressure", confidence: 0.8), "p2": JevAnswer(type: "choice", choice: "uncertain", confidence: 0.9)])
        let found = PassageDecisions.findings(response, passages: passages)
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.passage, passages[0]); XCTAssertEqual(found.first?.signal, .pressure)
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
            const host=document.querySelector('[id^="kiwi-reading-"]'), card=host.shadowRoot.querySelector('aside');
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
            return !document.querySelector('[id^="kiwi-reading-"]');
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(invalidated as? Bool, true)
        let stale = await PageTextBridge.annotate([.init(passage: passage, signal: .loaded)], document: extract.document, view: view)
        XCTAssertFalse(stale)
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
        let yellow = try await view.callAsyncJavaScript("return Array.from(document.querySelectorAll('style')).some(s => s.textContent.includes('#ffe66a')) || !!document.querySelector('[data-kiwi-marked]');", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(yellow as? Bool, true)
        _ = try await view.evaluateJavaScript("document.getElementById('policy').textContent = 'Changed cancellation terms.'")
        let stale = await PageTextBridge.highlight(passage, document: extracted.document, view: view)
        XCTAssertFalse(stale)
        let fresh = try await PageTextBridge.extract(view)
        XCTAssertTrue(fresh.passages.contains { $0.text == "Changed cancellation terms." })
        let wrongDocument = await PageTextBridge.highlight(fresh.passages[0], document: "old-document", view: view)
        XCTAssertFalse(wrongDocument)
    }
}
