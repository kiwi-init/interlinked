import XCTest

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
            switch question.type {
            case .choice:
                JevAnswer(type: "choice", choice: question.criteria.keys.sorted().first, confidence: 0.9)
            case .noul:
                JevAnswer(type: "noul", noul: 0.9)
            case .score:
                JevAnswer(type: "score", score: 3.5)
            }
        })
    }
}

private actor FixtureLocalIntelligence: LocalBrowserIntelligence {
    let label: String?
    let about: String?
    let advice: String?
    let adviceDelay: Duration
    let adviceUnavailable: Bool
    private(set) var portraitCalls = 0
    private(set) var adviceCalls = 0

    init(
        label: String? = nil,
        about: String? = nil,
        advice: String? = nil,
        adviceDelay: Duration = .zero,
        adviceUnavailable: Bool = false
    ) {
        self.label = label
        self.about = about
        self.advice = advice
        self.adviceDelay = adviceDelay
        self.adviceUnavailable = adviceUnavailable
    }

    func pagePortrait(page: PageMetadata) async throws -> PagePortrait? {
        portraitCalls += 1
        guard let label, let clean = PageLabels.generated(label) else { return nil }
        return PagePortrait(label: clean, about: about ?? "About \(clean)")
    }
    func navigationAdvice(_ review: NavigationReview) async throws -> String? {
        adviceCalls += 1
        if adviceDelay != .zero { try? await Task.sleep(for: adviceDelay) }
        if adviceUnavailable { throw CancellationError() }
        return advice
    }
    func shouldReplaceSiteMenu(host: String, labels: String) async throws -> Bool? { true }
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
    func testCriticalReadingDefaultsToOnRequestAndPersistsAlwaysOn() throws {
        let name = "CriticalReadingPreferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertTrue(JevPreferences.enabled(in: defaults))
        XCTAssertEqual(CriticalReadingMode(defaults: defaults), .onRequest)
        XCTAssertFalse(AutomaticReadingConsent.accepted(in: defaults))

        defaults.set(false, forKey: JevPreferences.enabledKey)
        CriticalReadingMode.automatic.save(to: defaults)
        AutomaticReadingConsent.accept(in: defaults)
        XCTAssertFalse(JevPreferences.enabled(in: defaults))
        XCTAssertEqual(CriticalReadingMode(defaults: defaults), .automatic)
        XCTAssertTrue(AutomaticReadingConsent.accepted(in: defaults))
    }
}

@MainActor
final class IntelligenceAuditStoreTests: XCTestCase {
    private func temporaryFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterlinkedAuditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("activity.json"))
    }

    func testAuditPersistsOnlyOperationalMetadata() async throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = IntelligenceAuditStore(file: location.file, now: { date }, saveDelay: .milliseconds(10))

        let id = store.begin(source: .appleIntelligence, action: "Page label")
        store.finish(id, failed: false)
        await store.waitForPendingSave()
        let reloaded = IntelligenceAuditStore(file: location.file, now: { date })

        XCTAssertEqual(reloaded.events.count, 1)
        XCTAssertEqual(reloaded.events[0].source, .appleIntelligence)
        XCTAssertEqual(reloaded.events[0].action, "Page label")
        XCTAssertEqual(reloaded.events[0].outcome, .completed)

        let json = try String(contentsOf: location.file, encoding: .utf8)
        for forbidden in ["prompt", "pageText", "url", "query", "response", "credential", "errorMessage"] {
            XCTAssertFalse(json.contains("\"\(forbidden)\""))
        }
    }

    func testRecentShowsTwentyWhileExportIncludesEveryAction() throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = IntelligenceAuditStore(file: location.file)
        for index in 0..<25 {
            let id = store.begin(source: .jev, action: "Action \(index)")
            store.finish(id, failed: false)
        }

        XCTAssertEqual(store.recent.count, 20)
        XCTAssertEqual(store.events.count, 25)

        let export = location.directory.appendingPathComponent("export.json")
        try store.export(to: export)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: export)) as? [String: Any]
        )
        XCTAssertEqual((object["events"] as? [[String: Any]])?.count, 25)
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
    }

    func testUnfinishedActionIsMarkedInterruptedOnNextLaunch() throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let original = IntelligenceAuditStore(file: location.file, now: { started })
        original.begin(source: .jev, action: "Critical reading")
        original.flush()

        let recovered = IntelligenceAuditStore(
            file: location.file,
            now: { started.addingTimeInterval(3) }
        )
        XCTAssertEqual(recovered.events.first?.outcome, .interrupted)
        XCTAssertEqual(recovered.events.first?.durationMilliseconds, 3_000)
    }

    func testClearRemovesPersistedActivity() throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = IntelligenceAuditStore(file: location.file)
        store.begin(source: .jev, action: "Meaning search")
        store.flush()
        store.clear()

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(IntelligenceAuditStore(file: location.file).events.isEmpty)
    }

    func testEventsStayCappedAfterMoreInsertsThanTheLimit() throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let limit = IntelligenceAuditStore.eventLimit
        let store = IntelligenceAuditStore(file: location.file)
        for index in 0..<(limit + 25) {
            store.begin(source: .jev, action: "Action \(index)")
        }

        XCTAssertEqual(store.events.count, limit)
        XCTAssertEqual(store.events.first?.action, "Action \(limit + 24)")
        XCTAssertEqual(store.events.last?.action, "Action 25")
    }

    func testLoadAppliesTheCapToAnOversizedFile() throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let limit = IntelligenceAuditStore.eventLimit
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let events = (0..<(limit + 10)).map { index in
            IntelligenceAuditEvent(
                id: UUID(), source: .jev, action: "Action \(index)",
                startedAt: start.addingTimeInterval(Double(index)), finishedAt: nil,
                outcome: .completed, durationMilliseconds: 0
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: location.file)

        let store = IntelligenceAuditStore(file: location.file)
        XCTAssertEqual(store.events.count, limit)
        XCTAssertEqual(store.events.first?.action, "Action \(limit + 9)")
    }

    func testBurstOfEventsLandsInOneDebouncedWrite() async throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = IntelligenceAuditStore(file: location.file, saveDelay: .milliseconds(50))
        for index in 0..<40 {
            let id = store.begin(source: .jev, action: "Action \(index)")
            store.finish(id, failed: index.isMultiple(of: 2))
        }

        XCTAssertEqual(store.writeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.file.path))

        await store.waitForPendingSave()
        XCTAssertEqual(store.writeCount, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: location.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(IntelligenceAuditStore(file: location.file).events.count, 40)
    }

    func testReloadAfterSaveKeepsTheNewestEvents() async throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let limit = IntelligenceAuditStore.eventLimit
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = IntelligenceAuditStore(
            file: location.file,
            now: { clock },
            saveDelay: .milliseconds(10)
        )
        for index in 0..<(limit + 5) {
            clock = clock.addingTimeInterval(1)
            let id = store.begin(source: .jev, action: "Action \(index)")
            store.finish(id, failed: false)
        }
        await store.waitForPendingSave()

        let reloaded = IntelligenceAuditStore(file: location.file)
        XCTAssertEqual(reloaded.events, store.events)
        XCTAssertEqual(reloaded.events.first?.action, "Action \(limit + 4)")
        XCTAssertEqual(reloaded.events.last?.action, "Action 5")
    }

    func testClearWinsOverAPendingDebouncedSave() async throws {
        let location = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = IntelligenceAuditStore(file: location.file, saveDelay: .milliseconds(10))
        store.begin(source: .jev, action: "Meaning search")
        store.clear()
        await store.waitForPendingSave()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(IntelligenceAuditStore(file: location.file).events.isEmpty)
    }
}

final class BrowserIntelligenceTests: XCTestCase {
    private func page() -> PageMetadata {
        PageMetadata(document: "doc", url: "https://example.com/products/browser", title: "Example Browser",
                     heading: "A focused browser", summary: "Browse without losing context", breadcrumbs: ["Products"])
    }

    @MainActor
    func testProviderCallsAppearInTheUserAudit() async throws {
        let page = page(), expected = "Example browser research"
        let audit = IntelligenceAuditStore()
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: FixtureJev(), cache: JevDecisionCache(file: nil)),
            local: FixtureLocalIntelligence(label: expected, about: "A focused browser research page."),
            audit: audit,
            portraits: PagePortraitCache(file: nil)
        )

        _ = try await intelligence.describePage(page: page)

        XCTAssertEqual(audit.events.count, 1)
        XCTAssertEqual(audit.events.first?.source, .appleIntelligence)
        XCTAssertEqual(audit.events.first?.action, "Page label")
        XCTAssertEqual(audit.events.first?.outcome, .completed)
    }

    func testApplePortraitDoesNotCallJevAndCachesByMetadata() async throws {
        let page = page(), expected = "Focused Browser Research"
        let local = FixtureLocalIntelligence(label: expected, about: "Researching a focused browser.")
        let jev = FixtureJev()
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: jev, cache: JevDecisionCache(file: nil)),
            local: local,
            portraits: PagePortraitCache(file: nil)
        )

        let decision = try await intelligence.describePage(page: page)
        _ = try await intelligence.describePage(page: page)
        let calls = await jev.calls
        let portraits = await local.portraitCalls

        XCTAssertEqual(decision?.value.label, expected)
        XCTAssertEqual(decision?.value.about, "Researching a focused browser.")
        XCTAssertEqual(decision?.source, .appleIntelligence)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(portraits, 1)
    }

    func testBlankAppleLabelDoesNotCallJev() async throws {
        let page = page()
        let local = FixtureLocalIntelligence(label: "  \n ")
        let jev = FixtureJev()
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: jev, cache: JevDecisionCache(file: nil)),
            local: local,
            portraits: PagePortraitCache(file: nil)
        )

        let decision = try await intelligence.describePage(page: page)
        let calls = await jev.calls

        XCTAssertNil(decision)
        XCTAssertEqual(calls, 0)
    }

    func testLongPagesAreCheckedInFullInParallelBatches() async throws {
        let passages = (0..<200).map { PagePassage(id: "p\($0)", text: "Passage \($0) with enough words to read", role: "passage") }
        let jev = FixtureJev(delay: .milliseconds(20))
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: jev, cache: JevDecisionCache(file: nil)),
            local: FixtureLocalIntelligence(),
            portraits: PagePortraitCache(file: nil)
        )
        let found = try await intelligence.meaningFind(query: "passage", passages: passages)
        XCTAssertEqual(found.value.scores.count, 200)
        let reading = try await intelligence.criticalReading(passages)
        XCTAssertEqual(reading.value.count, 200)
        let calls = await jev.calls
        // 4 meaning batches of 60, one first-result pick, 5 reading batches of 40.
        XCTAssertEqual(calls, 4 + 1 + 5)
    }

    func testRelatedGroupsUseJevOnAboutsNotApple() async throws {
        let pages = [
            ResearchPage(id: "one", title: "First", detail: "", host: "one.test", about: "Sony A7 review"),
            ResearchPage(id: "two", title: "Second", detail: "", host: "two.test", about: "Sony A7 shop"),
            ResearchPage(id: "three", title: "Third", detail: "", host: "three.test", about: "Pasta recipes")
        ]
        let local = FixtureLocalIntelligence(label: "Ignored")
        let jev = FixtureJev()
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: jev, cache: JevDecisionCache(file: nil)),
            local: local,
            portraits: PagePortraitCache(file: nil)
        )

        let decision = try await intelligence.relatedPageGroups(pages: pages)
        let jevCalls = await jev.calls
        let portraits = await local.portraitCalls

        XCTAssertEqual(decision?.source, .jev)
        XCTAssertEqual(jevCalls, 1)
        XCTAssertEqual(portraits, 0)
        XCTAssertEqual(Set(decision?.value.first?.members ?? []), Set(["one", "two", "three"]))
    }

    func testNavigationAdviceRetainsTheWarningWhenAppleIntelligenceIsUnavailable() async throws {
        let local = FixtureLocalIntelligence(adviceUnavailable: true)
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: FixtureJev(), cache: JevDecisionCache(file: nil)),
            local: local,
            portraits: PagePortraitCache(file: nil)
        )
        let review = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://person:secret@example.test")),
            source: nil,
            kind: .link
        )
        let advice = await intelligence.navigationAdvice(review, timeout: .milliseconds(50))
        XCTAssertNil(advice)
        XCTAssertEqual(review.disposition, .warn)
        XCTAssertTrue(review.needsAdvisory)
    }

    func testNavigationAdviceSkipsRoutineWarnings() async throws {
        let local = FixtureLocalIntelligence(advice: "Should not run")
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: FixtureJev(), cache: JevDecisionCache(file: nil)),
            local: local,
            portraits: PagePortraitCache(file: nil)
        )
        let review = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://github.com:8443/")),
            source: try XCTUnwrap(URL(string: "https://example.com/")),
            kind: .link
        )
        let advice = await intelligence.navigationAdvice(review, timeout: .milliseconds(50))
        let calls = await local.adviceCalls
        XCTAssertTrue(review.reasons.contains(.unusualPort))
        XCTAssertFalse(review.needsAdvisory)
        XCTAssertNil(advice)
        XCTAssertEqual(calls, 0)
    }

    func testNavigationAdviceDeadlineDoesNotWaitForTheModel() async throws {
        let local = FixtureLocalIntelligence(advice: "Too late", adviceDelay: .seconds(2))
        let intelligence = BrowserIntelligence(
            jev: JevService(provider: FixtureJev(), cache: JevDecisionCache(file: nil)),
            local: local,
            portraits: PagePortraitCache(file: nil)
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
    func testPageBridgeUsesExtractionTextForHighlightValidation() {
        XCTAssertTrue(PageTextBridge.install.contains("nodeText(node)!==item.text"))
        XCTAssertFalse(PageTextBridge.install.contains("clean(node.innerText)!==item.text"))
    }
    func testPageBridgeWorksOnPlainHTTPPages() {
        // randomUUID is missing outside secure contexts; the bridge must not depend on it.
        XCTAssertTrue(PageTextBridge.install.contains("crypto.randomUUID?.()"))
        XCTAssertTrue(PageTextBridge.install.contains("crypto.getRandomValues"))
    }
    func testPageBridgeExtractsTheWholePage() {
        XCTAssertFalse(PageTextBridge.install.contains("passages.length>=limit"))
        XCTAssertTrue(PageTextBridge.install.contains("return {document:documentID,url:location.href,passages};"))
        XCTAssertTrue(PageTextBridge.install.contains("mostlyControls"))
    }
    func testHighlightsFollowThePageAppearance() {
        XCTAssertTrue(PageTextBridge.install.contains("highlight(items, current, document, scroll = true, dark)"))
        XCTAssertTrue(PageTextBridge.install.contains("{mark:'#6b5200',current:'#8f6c00',text:'#fff4cc'}"))
        XCTAssertTrue(PageTextBridge.install.contains("appearance(dark)"))
    }
    func testLabelsUseMetadataWithoutCandidatesOrURLSecrets() {
        XCTAssertEqual(PageLabels.fallback(page()), "Buy iPhone 18 Pro - Apple")
        let evidence = PageLabels.evidence(page("https://www.apple.com/buy?token=secret#private"))
        XCTAssertTrue(evidence.contains("Title: Buy iPhone 18 Pro - Apple"))
        XCTAssertTrue(evidence.contains("Host: www.apple.com"))
        XCTAssertFalse(evidence.contains("token"))
        XCTAssertFalse(evidence.contains("secret"))
        XCTAssertFalse(evidence.contains("/buy"))
        XCTAssertEqual(PageLabels.generated("  iPhone   comparison\nresults  "), "iPhone comparison results")
        XCTAssertNil(PageLabels.generated(" \n "))
        XCTAssertEqual(page().origin, "https://www.apple.com")
        let identity = PageLabels.cacheIdentity(page())
        XCTAssertTrue(identity.contains("www.apple.com"))
        XCTAssertTrue(identity.contains("/iphone-18-pro/buy"))
        XCTAssertFalse(identity.contains("token"))
        var renamed = page()
        renamed.title = "Different title"
        XCTAssertNotEqual(PageLabels.cacheIdentity(renamed), identity)
        XCTAssertEqual(PageLabels.cacheIdentity(page("https://www.apple.com/iphone-18-pro/buy?q=1")), identity)
    }
    func testMeaningFindReturnsOnlyOriginalPassagesInDocumentOrder() {
        let passages = [PagePassage(id: "p1", text: "Termination policy: cancel within 30 days."), PagePassage(id: "p2", text: "Delivery takes five days.")]
        let request = PassageDecisions.scoreRequest(query: "cancellation conditions", passages: passages)
        XCTAssertEqual(Set(request.questions.keys), ["p1", "p2"])
        let response = JevResponse(answers: ["p1": JevAnswer(type: "score", score: 3.9), "p2": JevAnswer(type: "score", score: 0.4), "fabricated": JevAnswer(type: "score", score: 4)])
        XCTAssertEqual(PassageDecisions.shortlist(response, passages: passages).map(\.id), ["p1"])
        XCTAssertEqual(PassageDecisions.matches(response, passages: passages), [passages[0]])
        XCTAssertTrue(PassageDecisions.matches(JevResponse(answers: [:]), passages: passages).isEmpty)
    }
    func testIntentScoresRankSupportBeforeIncidentalWordStems() throws {
        let passages = [PagePassage(id: "body", text: "Recursos que ajudam nas fotos.", role: "passage"),
                        PagePassage(id: "support", text: "Suporte", role: "link"),
                        PagePassage(id: "help", text: "Ajuda", role: "link")]
        let request = PassageDecisions.scoreRequest(query: "ajuda", passages: passages)
        let response = JevResponse(answers: ["body": JevAnswer(type: "score", score: 1),
                                            "support": JevAnswer(type: "score", score: 3.8),
                                            "help": JevAnswer(type: "score", score: 4)])
        XCTAssertNoThrow(try response.validated(for: request))
        XCTAssertEqual(PassageDecisions.shortlist(response, passages: passages).map(\.id), ["help", "support"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions["support"]?["type"] as? String, "score")
        XCTAssertEqual((questions["support"]?["criteria"] as? [String])?.count, 5)
        XCTAssertThrowsError(try JevResponse(answers: ["support": JevAnswer(type: "score", score: 5)]).validated(for: request))
    }
    func testBestAnswerSelectionOutranksIndependentScoresAndSurvivesCutoff() throws {
        let passages = [PagePassage(id: "time", text: "Delivery tomorrow", role: "passage"),
                        PagePassage(id: "price", text: "Shipping is free", role: "heading")]
        let scores = JevResponse(answers: ["time": JevAnswer(type: "score", score: 2.9), "price": JevAnswer(type: "score", score: 2.7)])
        let shortlist = PassageDecisions.shortlist(scores, passages: passages)
        let request = PassageDecisions.bestMatchRequest(query: "delivery price", passages: shortlist)
        XCTAssertEqual(request.questions["best_match"]?.criteria["price"], "heading")
        XCTAssertFalse((request.questions["best_match"]?.criteria["price"] ?? "").contains("Shipping"))
        XCTAssertNoThrow(try scores.validated(for: PassageDecisions.scoreRequest(query: "delivery price", passages: passages)))
        XCTAssertNoThrow(try JevResponse(answers: ["best_match": JevAnswer(type: "choice", choice: "price")]).validated(for: request))
        var response = scores
        response.answers["best_match"] = JevAnswer(type: "choice", choice: "price")
        XCTAssertEqual(PassageDecisions.matches(response, passages: shortlist).map(\.id), ["price", "time"])
        response.answers["best_match"] = JevAnswer(type: "choice", choice: "none")
        XCTAssertTrue(PassageDecisions.matches(response, passages: shortlist).isEmpty)
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
    func testReadingFiltersFragmentsAndSendsWholePassages() {
        let passages = [PagePassage(id: "short", text: "Too good."),
                        PagePassage(id: "heading", text: "A meaningful heading with enough words", role: "heading")] +
            (0..<85).map { PagePassage(id: "p\($0)", text: String(repeating: "substantive ", count: 200), role: "passage") }
        let candidates = PassageDecisions.readingCandidates(passages)
        XCTAssertEqual(candidates.count, 85)
        let request = PassageDecisions.readingRequest([candidates[0]])
        XCTAssertTrue(request.state.contains(candidates[0].text))
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
    func testBrowserHistoryRecordsVisitsAcrossPagesAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        let history = BrowserHistoryStore(file: file)

        history.record(URL(string: "https://one.test/first#section"), title: "First page")
        history.record(URL(string: "https://two.test/second"), title: "Second page")
        history.record(URL(string: "https://one.test/first"), title: "First page again")
        history.record(URL(string: "https://private.test/callback?auth=secret"), title: "Private")

        XCTAssertEqual(history.visits.map(\.title), ["First page again", "Second page", "First page"])
        XCTAssertEqual(history.visits.map(\.url), [
            "https://one.test/first", "https://two.test/second", "https://one.test/first"
        ])
        history.save()
        XCTAssertEqual(BrowserHistoryStore(file: file).visits, history.visits)
    }
    func testResearchGroupsKeepOriginalOrderAndUseExistingNames() {
        let pages = [ResearchPage(id: "3", title: "Sony A7 camera review", detail: "", host: "reviews.test"), ResearchPage(id: "1", title: "Sony A7 camera shop", detail: "", host: "store.test"), ResearchPage(id: "2", title: "Cooking dinner", detail: "", host: "food.test")]
        XCTAssertEqual(ResearchRelations.groups(pages).first?.members, ["3", "1"])
        let groups = ResearchRelations.groups(pages, response: JevResponse(answers: ["3_1": JevAnswer(type: "noul", noul: 0.9)]))
        XCTAssertEqual(groups.first?.title, pages[0].title)
        XCTAssertEqual(groups.first?.members, ["3", "1"])
        XCTAssertEqual(pages.map(\.id), ["3", "1", "2"])
        XCTAssertTrue(ResearchRelations.groups(pages, response: JevResponse(answers: [:])).isEmpty)
    }
    func testRelatedCliquesDoNotUseTransitivity() {
        let pages = [
            ResearchPage(id: "a", title: "A", detail: "", host: "a.test", about: "Sony A7 review"),
            ResearchPage(id: "b", title: "B", detail: "", host: "b.test", about: "Sony A7 shop"),
            ResearchPage(id: "c", title: "C", detail: "", host: "c.test", about: "Unrelated pasta")
        ]
        let chain = ResearchRelations.groups(pages, response: JevResponse(answers: [
            "a_b": JevAnswer(type: "noul", noul: 0.9),
            "b_c": JevAnswer(type: "noul", noul: 0.9),
            "a_c": JevAnswer(type: "noul", noul: 0.1)
        ]))
        XCTAssertEqual(chain.map { Set($0.members) }, [Set(["a", "b"])])
        let clique = ResearchRelations.groups(pages, response: JevResponse(answers: [
            "a_b": JevAnswer(type: "noul", noul: 0.9),
            "b_c": JevAnswer(type: "noul", noul: 0.9),
            "a_c": JevAnswer(type: "noul", noul: 0.9)
        ]))
        XCTAssertEqual(clique.map { Set($0.members) }, [Set(["a", "b", "c"])])
    }
    func testRelatedMergeKeepsFallbackGroupsThatIncludeUndescribedTabs() {
        let pages = [
            ResearchPage(id: "a", title: "Sony A7 camera review", detail: "", host: "a.test", about: "Sony A7 review"),
            ResearchPage(id: "b", title: "Sony A7 camera shop", detail: "", host: "b.test", about: "Sony A7 shop"),
            ResearchPage(id: "c", title: "Sony A7 camera listing", detail: "", host: "c.test", about: ""),
            ResearchPage(id: "d", title: "Cooking dinner recipes", detail: "", host: "d.test", about: "")
        ]
        let fallback = ResearchRelations.groups(pages)
        XCTAssertEqual(Set(fallback.first?.members ?? []), Set(["a", "b", "c"]))
        let remote = [ResearchGroup(id: "a", title: pages[0].title, members: ["a", "b"])]
        let merged = ResearchRelations.merge(remote: remote, fallback: fallback, pages: pages)
        XCTAssertEqual(Set(merged.first { $0.members.contains("a") }?.members ?? []), Set(["a", "b", "c"]))
        XCTAssertFalse(merged.contains { Set($0.members) == Set(["a", "b", "c", "d"]) })
        let declined = ResearchRelations.merge(remote: [], fallback: fallback, pages: pages)
        XCTAssertEqual(Set(declined.first?.members ?? []), Set(["a", "b", "c"]))
        XCTAssertTrue(ResearchRelations.merge(
            remote: [],
            fallback: [ResearchGroup(id: "a", title: "Sony", members: ["a", "b"])],
            pages: pages
        ).isEmpty)
    }
    func testSensitiveAndLocalPagesCannotBeShared() {
        XCTAssertFalse(page("http://127.0.0.1:8000/").publicWebPage)
        XCTAssertFalse(page("http://company.local/").publicWebPage)
        XCTAssertFalse(page("https://person:secret@example.com/").publicWebPage)
        var sensitive = page(); sensitive.sensitive = true
        XCTAssertFalse(sensitive.publicWebPage)
        XCTAssertTrue(page().publicWebPage)
    }
    func testSigningInDoesNotExcludeAPage() {
        let inbox = page("https://mail.example.com/inbox")
        XCTAssertTrue(inbox.publicWebPage)
        XCTAssertFalse(PageTextBridge.install.contains("document.cookie"))
        let payload = Data(#"{"document":"d","url":"https://mail.example.com/inbox","title":"Inbox","heading":"","summary":"","breadcrumbs":[],"sensitive":true}"#.utf8)
        XCTAssertEqual((try? JSONDecoder().decode(PageMetadata.self, from: payload))?.publicWebPage, false)
    }
}
