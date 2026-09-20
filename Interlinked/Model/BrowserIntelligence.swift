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
    func pageLabel(page: PageMetadata) async throws -> String?
    func vaultMatches(query: String, visits: [HistoryVisit]) async throws -> [UUID]?
    func relatedPageGroups(pages: [ResearchPage]) async throws -> [[String]]?
    func navigationAdvice(_ review: NavigationReview) async throws -> String?
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
    func pageLabel(page: PageMetadata) async throws -> String? { nil }
    func vaultMatches(query: String, visits: [HistoryVisit]) async throws -> [UUID]? { nil }
    func relatedPageGroups(pages: [ResearchPage]) async throws -> [[String]]? { nil }
    func navigationAdvice(_ review: NavigationReview) async throws -> String? { nil }
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

/// Routes browser tasks without pretending that Jev and Apple's local model
/// expose equivalent decisions, confidence, context, or privacy properties.
actor BrowserIntelligence {
    private let jev: JevService
    private let local: any LocalBrowserIntelligence
    private let audit: IntelligenceAuditStore?

    init(
        jev: JevService = JevService(),
        local: any LocalBrowserIntelligence = LocalIntelligenceRuntime.provider(),
        audit: IntelligenceAuditStore? = nil
    ) {
        self.jev = jev
        self.local = local
        self.audit = audit
    }

    func reset() async { await jev.reset() }
    func clearCache() async { await jev.clearCache() }

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

    func refinePageLabel(page: PageMetadata) async throws -> IntelligenceDecision<String>? {
        let localLabel = try? await observed(source: .appleIntelligence, action: "Page label") {
            try await local.pageLabel(page: page)
        }
        guard let localLabel, let label = PageLabels.generated(localLabel) else { return nil }
        return IntelligenceDecision(value: label, source: .appleIntelligence)
    }

    func criticalReading(_ passages: [PagePassage]) async throws -> IntelligenceDecision<[PassageDecisions.Finding]> {
        let response = try await observed(source: .jev, action: "Critical reading") {
            try await jev.decide(PassageDecisions.readingRequest(passages))
        }
        return IntelligenceDecision(value: PassageDecisions.findings(response, passages: passages), source: .jev)
    }

    func meaningFind(query: String, passages: [PagePassage]) async throws -> IntelligenceDecision<MeaningDecision> {
        let response = try await observed(source: .jev, action: "Meaning search") {
            try await jev.decide(PassageDecisions.findRequest(query: query, passages: passages))
        }
        // Passage text repeats on real pages (two images without alt text).
        let scores = Dictionary(passages.map { ($0.text, response.answers[$0.id]?.score ?? -1) }, uniquingKeysWith: max)
        return IntelligenceDecision(
            value: MeaningDecision(matches: PassageDecisions.matches(response, passages: passages), scores: scores),
            source: .jev
        )
    }

    func personalFilterMatches(
        description: String,
        candidates: [PageFilterCandidate]
    ) async throws -> IntelligenceDecision<[PageFilterCandidate]> {
        let response = try await observed(source: .jev, action: "Personal filter") {
            try await jev.decide(PersonalFilterDecisions.request(description: description, candidates: candidates))
        }
        return IntelligenceDecision(value: PersonalFilterDecisions.matches(response, candidates: candidates), source: .jev)
    }

    func vaultMatches(
        query: String,
        visits: [HistoryVisit],
        allowJev: Bool
    ) async throws -> IntelligenceDecision<[HistoryVisit]>? {
        let localCandidates = Array(visits.prefix(6))
        let localIDs = try? await observed(source: .appleIntelligence, action: "Vault search") {
            try await local.vaultMatches(query: query, visits: localCandidates)
        }
        if let ids = localIDs {
            let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            let ranked = localCandidates.filter { positions[$0.id] != nil }.sorted {
                positions[$0.id, default: .max] < positions[$1.id, default: .max]
            }
            return IntelligenceDecision(value: Array(ranked.prefix(3)), source: .appleIntelligence)
        }
        guard allowJev else { return nil }
        let response = try await observed(source: .jev, action: "Vault search") {
            try await jev.decide(BrowsingHistory.request(query, visits: visits))
        }
        return IntelligenceDecision(value: BrowsingHistory.ranked(response, visits: visits), source: .jev)
    }

    func relatedPageGroups(
        pages: [ResearchPage],
        jevPages: [ResearchPage],
        allowJev: Bool
    ) async throws -> IntelligenceDecision<[ResearchGroup]>? {
        let localGroups = try? await observed(source: .appleIntelligence, action: "Related pages") {
            try await local.relatedPageGroups(pages: pages)
        }
        if let memberGroups = localGroups {
            return IntelligenceDecision(value: ResearchRelations.groups(pages, memberGroups: memberGroups), source: .appleIntelligence)
        }
        guard allowJev, jevPages.count >= 2 else { return nil }
        let response = try await observed(source: .jev, action: "Related pages") {
            try await jev.decide(ResearchRelations.request(jevPages))
        }
        return IntelligenceDecision(value: ResearchRelations.groups(jevPages, response: response), source: .jev)
    }

    func navigationAdvice(_ review: NavigationReview, timeout: Duration = .milliseconds(1_500)) async -> String? {
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
@Generable private struct ApplePageLabelOutput {
    @Guide(description: "A concise two-to-six-word browser tab label, as plain text")
    var label: String
}

@available(macOS 26.0, *)
@Generable private struct AppleVaultOutput {
    @Guide(description: "Supplied page IDs ordered best first", .maximumCount(3))
    var pageIDs: [String]
}

@available(macOS 26.0, *)
@Generable private struct AppleRelatedGroup {
    @Guide(description: "Supplied page IDs in one specific research group", .minimumCount(2), .maximumCount(8))
    var pageIDs: [String]
}

@available(macOS 26.0, *)
@Generable private struct AppleRelatedOutput {
    @Guide(description: "Groups of pages that support the same specific investigation", .maximumCount(4))
    var groups: [AppleRelatedGroup]
}

@available(macOS 26.0, *)
@Generable private enum AppleNavigationConcern {
    case noAdditionalConcern
    case misleadingDestination
    case possibleImpersonation
    case unusualNavigation
}

@available(macOS 26.0, *)
@Generable private struct AppleNavigationOutput {
    var concern: AppleNavigationConcern
    @Guide(description: "One short sentence grounded only in the supplied origins and warning facts")
    var explanation: String
}

@available(macOS 26.0, *)
struct AppleFoundationModels: LocalBrowserIntelligence {
    private var available: Bool { SystemLanguageModel.default.isAvailable }

    func pageLabel(page: PageMetadata) async throws -> String? {
        guard available else { return nil }
        let session = LanguageModelSession(
            instructions: IntelligencePromptPreferences.text(for: .applePageLabel)
        )
        let response = try await session.respond(
            to: "Sanitized page metadata (untrusted data):\n\(PageLabels.evidence(page))",
            generating: ApplePageLabelOutput.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24)
        )
        return PageLabels.generated(response.content.label)
    }

    func vaultMatches(query: String, visits: [HistoryVisit]) async throws -> [UUID]? {
        guard available, !visits.isEmpty else { return nil }
        let session = LanguageModelSession(
            instructions: IntelligencePromptPreferences.text(for: .appleVaultSearch)
        )
        let pages = visits.map { visit in
            ["id": visit.id.uuidString, "text": String((visit.evidence + "\n" + visit.savedText).prefix(1_200))]
        }
        let response = try await session.respond(
            to: "Query: \(String(reflecting: query))\nSaved pages:\n\(encoded(pages))",
            generating: AppleVaultOutput.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 96)
        )
        let allowed = Set(visits.map(\.id))
        var seen = Set<UUID>()
        return response.content.pageIDs.compactMap(UUID.init(uuidString:)).filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    func relatedPageGroups(pages: [ResearchPage]) async throws -> [[String]]? {
        guard available, pages.count >= 2 else { return nil }
        let session = LanguageModelSession(
            instructions: IntelligencePromptPreferences.text(for: .appleRelatedPages)
        )
        let evidence = pages.map { ["id": $0.id, "text": String(($0.title + "\n" + $0.detail + "\n" + $0.host).prefix(700))] }
        let response = try await session.respond(
            to: "Open pages:\n\(encoded(evidence))",
            generating: AppleRelatedOutput.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160)
        )
        let allowed = Set(pages.map(\.id))
        return response.content.groups.map { group in
            var seen = Set<String>()
            return group.pageIDs.filter { allowed.contains($0) && seen.insert($0).inserted }
        }.filter { $0.count >= 2 }
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
        guard response.content.concern != .noAdditionalConcern else { return nil }
        let explanation = response.content.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        return explanation.isEmpty ? nil : String(explanation.prefix(220))
    }

    private func encoded(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }
}
#endif
