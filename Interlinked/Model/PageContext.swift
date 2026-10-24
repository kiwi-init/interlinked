import Foundation

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
