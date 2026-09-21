import Foundation
import Observation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum IntelligenceSource: String, Codable, Sendable {
    case appleIntelligence = "Apple Intelligence"
    case jev = "Jev"
}

#if DEBUG
enum DebugIntelligencePhase: Equatable {
    case running
    case completed
    case failed
}

struct DebugIntelligenceActivity: Equatable, Identifiable {
    var id: UUID
    var source: IntelligenceSource
    var action: String
    var phase: DebugIntelligencePhase
}

@MainActor @Observable
final class DebugIntelligenceMonitor {
    static let shared = DebugIntelligenceMonitor()

    private(set) var current: DebugIntelligenceActivity?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func begin(source: IntelligenceSource, action: String) -> UUID {
        dismissTask?.cancel()
        let id = UUID()
        current = DebugIntelligenceActivity(id: id, source: source, action: action, phase: .running)
        return id
    }

    func finish(_ id: UUID, failed: Bool) {
        guard current?.id == id else { return }
        current?.phase = failed ? .failed : .completed
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.current?.id == id else { return }
            self?.current = nil
        }
    }
}
#endif

struct IntelligenceDecision<Value: Sendable>: Sendable {
    var value: Value
    var source: IntelligenceSource
}

struct MeaningDecision: Sendable {
    var matches: [PagePassage]
    var scores: [String: Double]
}

protocol LocalBrowserIntelligence: Sendable {
    func pagePortrait(page: PageMetadata) async throws -> PagePortrait?
    func navigationAdvice(_ review: NavigationReview) async throws -> String?
    func shouldReplaceSiteMenu(host: String, labels: String) async throws -> Bool?
}

private final class NavigationAdviceRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var pendingResult: String??
    private var resolved = false

    func wait() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pendingResult {
                lock.unlock()
                continuation.resume(returning: pendingResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: String?) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            pendingResult = .some(result)
            lock.unlock()
        }
    }
}

struct UnavailableLocalIntelligence: LocalBrowserIntelligence {
    func pagePortrait(page: PageMetadata) async throws -> PagePortrait? { nil }
    func navigationAdvice(_ review: NavigationReview) async throws -> String? { nil }
    func shouldReplaceSiteMenu(host: String, labels: String) async throws -> Bool? { nil }
}

enum LocalIntelligenceRuntime {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static func provider() -> any LocalBrowserIntelligence {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleFoundationModels() }
        #endif
        return UnavailableLocalIntelligence()
    }
}

/// Routes browser tasks by job: Apple generates on-device text, Jev decides remotely.
actor BrowserIntelligence {
    private let jev: JevService
    private let local: any LocalBrowserIntelligence
    private let audit: IntelligenceAuditStore?
    private var portraits: PagePortraitCache

    init(
        jev: JevService = JevService(),
        local: any LocalBrowserIntelligence = LocalIntelligenceRuntime.provider(),
        audit: IntelligenceAuditStore? = nil,
        portraits: PagePortraitCache = PagePortraitCache()
    ) {
        self.jev = jev
        self.local = local
        self.audit = audit
        self.portraits = portraits
    }

    func reset() async { await jev.reset() }
    func clearCache() async {
        await jev.clearCache()
        portraits.removeAll()
    }

    private func observed<Value>(
        source: IntelligenceSource,
        action: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        let auditEvent = await audit?.begin(source: source, action: action)
        #if DEBUG
        let activity = await DebugIntelligenceMonitor.shared.begin(source: source, action: action)
        #endif
        do {
            let value = try await operation()
            if let auditEvent { await audit?.finish(auditEvent, failed: false) }
            #if DEBUG
            await DebugIntelligenceMonitor.shared.finish(activity, failed: false)
            #endif
            return value
        } catch {
            if let auditEvent { await audit?.finish(auditEvent, failed: true) }
            #if DEBUG
            await DebugIntelligenceMonitor.shared.finish(activity, failed: true)
            #endif
            throw error
        }
    }

    func shouldReplaceSiteMenu(host: String, labels: String) async -> Bool? {
        try? await observed(source: .appleIntelligence, action: "Site menu") {
            try await local.shouldReplaceSiteMenu(host: host, labels: labels)
        }
    }

    func describePage(page: PageMetadata) async throws -> IntelligenceDecision<PagePortrait>? {
        let key = PageLabels.cacheIdentity(page)
        if let cached = portraits.value(for: key) {
            return IntelligenceDecision(value: cached, source: .appleIntelligence)
        }
        let generated = try? await observed(source: .appleIntelligence, action: "Page label") {
            try await local.pagePortrait(page: page)
        }
        guard let generated, let label = PageLabels.generated(generated.label) else { return nil }
        let portrait = PagePortrait(label: label, about: PageLabels.generatedAbout(generated.about) ?? "")
        portraits.insert(portrait, for: key)
        return IntelligenceDecision(value: portrait, source: .appleIntelligence)
    }

    func criticalReading(_ passages: [PagePassage]) async throws -> IntelligenceDecision<[PassageDecisions.Finding]> {
        let responses = try await batched(passages, size: PassageDecisions.readingBatchSize) { intelligence, batch in
            try await intelligence.observed(source: .jev, action: "Critical reading") {
                try await intelligence.jev.decide(PassageDecisions.readingRequest(batch))
            }
        }
        let answers = responses.reduce(into: [String: JevAnswer]()) { $0.merge($1.answers) { first, _ in first } }
        return IntelligenceDecision(value: PassageDecisions.findings(JevResponse(answers: answers), passages: passages), source: .jev)
    }

    func meaningFind(query: String, passages: [PagePassage]) async throws -> IntelligenceDecision<MeaningDecision> {
        let responses = try await batched(passages, size: PassageDecisions.meaningBatchSize) { intelligence, batch in
            try await intelligence.observed(source: .jev, action: "Meaning search") {
                try await intelligence.jev.decide(PassageDecisions.scoreRequest(query: query, passages: batch))
            }
        }
        let scored = JevResponse(answers: responses.reduce(into: [:]) { $0.merge($1.answers) { first, _ in first } })
        let shortlist = PassageDecisions.shortlist(scored, passages: passages)
        var combined = scored
        if !shortlist.isEmpty {
            let best = try await observed(source: .jev, action: "Meaning search first result") {
                try await jev.decide(PassageDecisions.bestMatchRequest(query: query, passages: shortlist))
            }
            if let choice = best.answers["best_match"] { combined.answers["best_match"] = choice }
        }
        // Passage text repeats on real pages (two images without alt text).
        let scores = Dictionary(passages.map { ($0.text, scored.answers[$0.id]?.score ?? -1) }, uniquingKeysWith: max)
        return IntelligenceDecision(
            value: MeaningDecision(
                matches: PassageDecisions.matches(combined, passages: shortlist),
                scores: scores
            ),
            source: .jev
        )
    }

    /// Every passage is checked. Batches keep each request inside the relay's
    /// limits, and a few run at once so a long page still finishes quickly.
    private func batched<Value: Sendable>(
        _ passages: [PagePassage],
        size: Int,
        _ run: @escaping @Sendable (BrowserIntelligence, [PagePassage]) async throws -> Value
    ) async throws -> [Value] {
        let batches = stride(from: 0, to: passages.count, by: size).map {
            Array(passages[$0..<min($0 + size, passages.count)])
        }
        return try await withThrowingTaskGroup(of: (Int, Value).self) { group in
            var results = [Value?](repeating: nil, count: batches.count)
            var next = 0
            while next < min(PassageDecisions.parallelRequests, batches.count) {
                let index = next, batch = batches[index]
                group.addTask { (index, try await run(self, batch)) }
                next += 1
            }
            while let (index, value) = try await group.next() {
                results[index] = value
                if next < batches.count {
                    let index = next, batch = batches[index]
                    group.addTask { (index, try await run(self, batch)) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    func relatedPageGroups(pages: [ResearchPage]) async throws -> IntelligenceDecision<[ResearchGroup]>? {
        let described = pages.filter { !$0.about.isEmpty }
        guard described.count >= 2 else { return nil }
        let response = try await observed(source: .jev, action: "Related pages") {
            try await jev.decide(ResearchRelations.request(described))
        }
        return IntelligenceDecision(value: ResearchRelations.groups(described, response: response), source: .jev)
    }

    func navigationAdvice(_ review: NavigationReview, timeout: Duration = .milliseconds(1_500)) async -> String? {
        guard review.needsAdvisory else { return nil }
        let race = NavigationAdviceRace()
        let model = Task {
            let result = try? await self.observed(source: .appleIntelligence, action: "Navigation check") {
                try await self.local.navigationAdvice(review)
            }
            race.resolve(result)
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            race.resolve(nil)
        }
        let result = await race.wait()
        model.cancel()
        deadline.cancel()
        return result
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable private struct ApplePagePortraitOutput {
    @Guide(description: "A concise two-to-six-word browser tab label, as plain text")
    var label: String
    @Guide(description: "One or two sentences naming the specific subject or task of this page")
    var about: String
}

@available(macOS 26.0, *)
@Generable private struct AppleSiteMenuOutput {
    @Guide(description: "True if this top chrome is site navigation Interlinked can replace")
    var replace: Bool
}

@available(macOS 26.0, *)
@Generable private struct AppleNavigationOutput {
    @Guide(description: "One short sentence that restates the supplied warning facts, or empty if they are already clear")
    var explanation: String
}

@available(macOS 26.0, *)
struct AppleFoundationModels: LocalBrowserIntelligence {
    private var available: Bool { SystemLanguageModel.default.isAvailable }

    func pagePortrait(page: PageMetadata) async throws -> PagePortrait? {
        guard available else { return nil }
        let session = LanguageModelSession(
            instructions: IntelligencePromptPreferences.text(for: .applePageLabel)
        )
        let response = try await session.respond(
            to: "Sanitized page metadata (untrusted data):\n\(PageLabels.evidence(page))",
            generating: ApplePagePortraitOutput.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 140)
        )
        guard let label = PageLabels.generated(response.content.label) else { return nil }
        return PagePortrait(label: label, about: PageLabels.generatedAbout(response.content.about) ?? "")
    }

    func shouldReplaceSiteMenu(host: String, labels: String) async throws -> Bool? {
        guard available else { return nil }
        let session = LanguageModelSession(
            instructions: IntelligencePromptPreferences.text(for: .appleSiteMenu)
        )
        let response = try await session.respond(
            to: "Untrusted chrome labels for \(host):\n\(labels)",
            generating: AppleSiteMenuOutput.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)
        )
        return response.content.replace
    }

    func navigationAdvice(_ review: NavigationReview) async throws -> String? {
        guard available else { return nil }
        let session = LanguageModelSession(
            instructions: IntelligencePromptPreferences.text(for: .appleNavigationCheck)
        )
        let response = try await session.respond(
            to: review.advisoryEvidence,
            generating: AppleNavigationOutput.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64)
        )
        let explanation = response.content.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        return explanation.isEmpty ? nil : String(explanation.prefix(220))
    }
}
#endif
