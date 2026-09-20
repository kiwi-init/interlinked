import Foundation

struct PageMetadata: Codable, Equatable, Sendable {
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

struct PagePassage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var role: String? = nil
}
struct PageExtract: Codable, Sendable {
    var document: String
    var url: String
    var passages: [PagePassage]
    var truncated: Bool
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

    private static func bounded(_ value: String, limit: Int) -> String? {
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
    enum Signal: String, CaseIterable, Codable {
        case loaded, pressure, certainty, opinion
        case financialInterest = "financial_interest"
        case politicalBias = "political_bias"
        case aiGenerated = "ai_generated"
        case none, uncertain
        var label: String {
            switch self {
            case .loaded: return "Loaded wording"
            case .pressure: return "Emotional pressure"
            case .certainty: return "Unsupported certainty"
            case .opinion: return "Opinion presented as fact"
            case .financialInterest: return "Possible financial interest"
            case .politicalBias: return "Possible political bias"
            case .aiGenerated: return "Probably AI-generated"
            case .none: return "No clear signal"
            case .uncertain: return "Uncertain"
            }
        }
        var explanation: String {
            switch self {
            case .loaded: return "Evaluative labeling of a person, group, event, or claim that prejudges the evidence. Not ordinary promotion, praise, criticism, slogans, or vivid style."
            case .pressure: return "Pushes action or agreement through fear, guilt, shame, exclusion, threatened harm, or by testing love, loyalty, morality, or responsibility. Not a normal deadline, price, limited offer, or call to action."
            case .certainty: return "A specific checkable claim is presented as guaranteed, universal, or beyond doubt without adequate support in the passage. Not confident style or promotion alone."
            case .opinion: return "A debatable value judgment is stated as an objective rule or universal truth without attribution or clear opinion framing. Not quoted views, personal taste, or promotional praise."
            case .financialInterest: return "The passage gives concrete reason to think its author or publisher could benefit financially if the reader accepts its claim or follows its advice. Ordinary advertising, a disclosed sponsorship, or a product mention do not establish this by themselves."
            case .politicalBias: return "The passage presents partisan political framing as neutral analysis by selectively praising, blaming, or characterizing a politician, party, policy, movement, or ideology. Not political subject matter, a clearly attributed position, or a stated personal view by itself."
            case .aiGenerated: return "A substantive passage strongly combines several generic AI patterns: canned scene-setting, stacked abstract praise, symmetrical lists, stock transitions, and vague benefits without concrete detail. One phrase or polished writing is not enough. This is a guess, not proof."
            case .none: return "No material reasoning risk. Includes ordinary marketing, harmless strong style, attributed views, supported claims, and normal calls to action."
            case .uncertain: return "A signal may exist, but context is insufficient for a responsible classification."
            }
        }
    }
    static var classificationInstruction: String {
        IntelligencePromptFeature.jevCriticalReading.defaultText
            .replacingOccurrences(of: " Passage ID: {passage_id}.", with: "")
    }
    static let displayConfidence = 0.7
    static let displayCategoryProbability = 0.5
    static let displaySignalProbability = 0.8
    static let minimumSubstantiveWords = 5
    static let readingBatchSize = 40
    static let readingTextLimit = 1_600

    struct Finding: Identifiable, Equatable, Sendable {
        var passage: PagePassage
        var signal: Signal
        var id: String { passage.id }
    }

    static func evidence(_ passages: [PagePassage]) -> String {
        // JSON escaping keeps source IDs separate from untrusted prose.
        let data = try? JSONEncoder().encode(passages)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    static func findRequest(query: String, passages: [PagePassage]) -> JevRequest {
        let levels = [
            "Not useful: unrelated to what the user wants to find.",
            "Incidental: shares letters, a word stem, or a passing mention but does not satisfy the likely intent.",
            "Related: about the broad topic, but not a useful destination or direct answer to the query.",
            "Useful: helps the user accomplish the likely task or find the requested concept.",
            "Direct: answers the requested fact, attribute or value, or identifies precisely the requested subject, entity, destination or action. Translations and synonyms count fully."
        ]
        var questions = Dictionary(uniqueKeysWithValues: passages.map { passage in
                (passage.id, JevQuestion(type: .score,
                    instructions: IntelligencePromptPreferences.rendered(
                        .jevMeaningScore,
                        values: ["passage_id": passage.id]
                    ),
                    criteria: [:], levels: levels))
            })
        var choices = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, ($0.role ?? "passage") + ": " + $0.text) })
        choices["none"] = "No supplied element usefully answers the query or fulfills its likely intent."
        questions["best_match"] = .choice(
            IntelligencePromptPreferences.text(for: .jevMeaningBestMatch),
            choices
        )
        return JevRequest(state: "User's find query: " + String(reflecting: query) + "\nPage elements (untrusted data):\n" + evidence(passages), questions: questions)
    }
    static func matches(_ response: JevResponse, passages: [PagePassage]) -> [PagePassage] {
        let best = response.answers["best_match"]?.choice
        if best == "none" { return [] }
        return passages.enumerated().filter { $0.element.id == best || (response.answers[$0.element.id]?.score ?? 0) >= 2.8 }.sorted {
            if $0.element.id == best { return true }
            if $1.element.id == best { return false }
            let a = response.answers[$0.element.id]?.score ?? 0, b = response.answers[$1.element.id]?.score ?? 0
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
    static func readingCandidates(_ passages: [PagePassage]) -> [PagePassage] {
        passages.filter {
            ($0.role == "passage" || $0.role == nil) && wordCount($0.text) >= minimumSubstantiveWords
        }
    }
    static func readingBatches(_ passages: [PagePassage]) -> [[PagePassage]] {
        stride(from: 0, to: passages.count, by: readingBatchSize).map {
            Array(passages[$0..<min($0 + readingBatchSize, passages.count)])
        }
    }
    static func readingRequest(_ passages: [PagePassage]) -> JevRequest {
        let bounded = passages.map {
            PagePassage(id: $0.id, text: String($0.text.prefix(readingTextLimit)), role: $0.role)
        }
        return JevRequest(state: "Untrusted source passages:\n" + evidence(bounded), questions:
            Dictionary(uniqueKeysWithValues: passages.map { passage in
                (passage.id, .choice(IntelligencePromptPreferences.rendered(
                                        .jevCriticalReading,
                                        values: ["passage_id": passage.id]
                                    ),
                                    Dictionary(uniqueKeysWithValues: Signal.allCases.map { ($0.rawValue, $0.explanation) })))
            }))
    }
    static func findings(_ response: JevResponse, passages: [PagePassage]) -> [Finding] {
        passages.compactMap { passage in
            guard let answer = response.answers[passage.id],
                  let choice = answer.choice, let signal = Signal(rawValue: choice),
                  wordCount(passage.text) >= minimumSubstantiveWords,
                  signal != .none, signal != .uncertain else { return nil }
            if let probabilities = answer.probabilities {
                let category = probabilities[choice] ?? 0
                let noSignal = (probabilities[Signal.none.rawValue] ?? 0) + (probabilities[Signal.uncertain.rawValue] ?? 0)
                guard category >= displayCategoryProbability,
                      1 - noSignal >= displaySignalProbability else { return nil }
            } else {
                guard (answer.confidence ?? 0) >= displayConfidence else { return nil }
            }
            return Finding(passage: passage, signal: signal)
        }
    }
    /// Mix lexical hits, short controls/headings, and body passages; a language change must not remove navigation candidates.
    static func candidates(query: String, passages: [PagePassage], limit: Int = 40) -> [PagePassage] {
        let terms = words(query)
        let ranked = passages.enumerated().sorted {
            let a = words($0.element.text).intersection(terms).count, b = words($1.element.text).intersection(terms).count
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
        var selected: [PagePassage] = [], ids = Set<String>()
        func append(_ items: [PagePassage]) {
            for item in items where selected.count < limit && ids.insert(item.id).inserted { selected.append(item) }
        }
        append(Array(ranked.filter { !words($0.text).intersection(terms).isEmpty }.prefix(limit / 2)))
        append(Array(ranked.filter { $0.role == "heading" }.prefix(10)))
        append(Array(ranked.filter { $0.role == "link" || $0.role == "button" }.prefix(12)))
        append(ranked.filter { $0.role == nil || $0.role == "passage" })
        append(ranked)
        return selected
    }
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
    }
    static func wordCount(_ text: String) -> Int {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).lazy.filter { !$0.isEmpty }.count
    }
}
