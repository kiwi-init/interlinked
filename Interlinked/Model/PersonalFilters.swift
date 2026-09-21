import Foundation
import Observation

struct PersonalFilterRule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var host: String
    var description: String
    var isEnabled: Bool
    var createdAt: Date
}

struct PageFilterCandidate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var role: String
    var context: String
}

struct PageFilterExtract: Codable, Sendable {
    var document: String
    var url: String
    var candidates: [PageFilterCandidate]
    var truncated: Bool
}

@MainActor @Observable
final class PersonalFilters {
    private(set) var rules: [PersonalFilterRule] = []
    @ObservationIgnored private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Interlinked/personal-filters.json")
        if let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode([PersonalFilterRule].self, from: data) {
            rules = Array(saved.prefix(200))
        }
    }

    static func site(_ host: String) -> String {
        host.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    func rules(for host: String) -> [PersonalFilterRule] {
        let site = Self.site(host)
        return rules.filter { Self.site($0.host) == site }.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func add(_ description: String, host: String) -> PersonalFilterRule? {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = Self.site(host)
        guard !text.isEmpty, !site.isEmpty else { return nil }
        let rule = PersonalFilterRule(id: UUID(), host: site, description: String(text.prefix(280)), isEnabled: true, createdAt: Date())
        rules.append(rule); save()
        return rule
    }

    func toggle(_ id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled.toggle(); save()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }; save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum PersonalFilterDecisions {
    static let matchThreshold = 0.82
    static let batchSize = 400

    enum Intent: Equatable, Sendable {
        case media(Set<String>)
        case word(String)
        case meaning
    }

    static func intent(_ description: String) -> Intent {
        let folded = normalized(description)
        if folded.contains("word") || folded.contains("palavra") {
            let leftover = usefulWords(description).subtracting(["word", "words", "palavra", "palavras"])
            if leftover.count == 1, let word = leftover.first { return .word(word) }
        }
        let words = usefulWords(description)
        var roles = Set<String>()
        if words.contains("image") || words.contains("images") || words.contains("picture")
            || words.contains("pictures") || words.contains("photo") || words.contains("photos") {
            roles.insert("image")
        }
        if words.contains("video") || words.contains("videos") { roles.insert("video") }
        let other = words.subtracting([
            "image", "images", "picture", "pictures", "photo", "photos",
            "video", "videos", "all", "every", "any", "hide", "remove"
        ])
        if !roles.isEmpty, other.isEmpty { return .media(roles) }
        return .meaning
    }

    static func localMatches(description: String, passages: [PagePassage]) -> [PagePassage] {
        let request = normalized(description)
        let requestWords = usefulWords(description)
        return passages.filter { passage in
            let text = normalized(passage.text)
            guard text.count >= 4 else { return false }
            if request.contains(text) || text.contains(request) { return true }
            let words = usefulWords(passage.text)
            return passage.role == "heading" && words.count >= 2 && words.isSubset(of: requestWords)
        }
    }

    static func localMatches(description: String, candidates: [PageFilterCandidate]) -> [PageFilterCandidate] {
        switch intent(description) {
        case .media(let roles):
            return candidates.filter { roles.contains($0.role) }
        case .word(let word):
            return candidates.filter { $0.role == "text token" && normalized($0.text) == word }
        case .meaning:
            let request = normalized(description)
            let requestedWords = usefulWords(description)
            let requestedStems = Set(requestedWords.map(stem))
            guard !request.isEmpty else { return [] }
            return candidates.filter { candidate in
                let text = normalized(candidate.text)
                guard text.count >= 2 else { return false }
                if candidate.role == "text token" { return requestedWords.contains(text) }
                let roleStems = Set(usefulWords(candidate.role).map(stem))
                if !roleStems.isEmpty, roleStems.isSubset(of: requestedStems) { return true }
                return request == text || (text.contains(" ") && request.contains(text))
            }
        }
    }

    static func jevCandidates(_ candidates: [PageFilterCandidate]) -> [PageFilterCandidate] {
        candidates.filter { $0.role != "text token" }
    }

    static func batches(_ candidates: [PageFilterCandidate]) -> [[PageFilterCandidate]] {
        stride(from: 0, to: candidates.count, by: batchSize).map {
            Array(candidates[$0..<min($0 + batchSize, candidates.count)])
        }
    }

    static func request(description: String, candidates: [PageFilterCandidate]) -> JevRequest {
        JevRequest(
            state: "User's personal filter: " + String(reflecting: description) +
                "\nAddressable page candidates (untrusted data):\n" + evidence(candidates),
            questions: Dictionary(uniqueKeysWithValues: candidates.map { candidate in
                (candidate.id, .relevant(IntelligencePromptPreferences.rendered(
                    .jevPersonalFilter,
                    values: [
                        "candidate_id": candidate.id,
                        "candidate_role": candidate.role
                    ]
                )))
            })
        )
    }

    static func matches(_ response: JevResponse, candidates: [PageFilterCandidate]) -> [PageFilterCandidate] {
        candidates.filter { (response.answers[$0.id]?.noul ?? 0) >= matchThreshold }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func usefulWords(_ text: String) -> Set<String> {
        let stops: Set<String> = ["a", "an", "and", "as", "at", "about", "from", "in", "of", "on", "or", "the", "this", "that", "with", "have", "want", "word", "words", "hide", "remove", "dont", "doesnt", "page", "thing", "stuff", "o", "os", "a", "as", "e", "ou", "de", "do", "da", "em", "no", "na", "palavra", "palavras", "ocultar", "esconder", "remover"]
        return PassageDecisions.words(text).subtracting(stops)
    }

    private static func evidence(_ candidates: [PageFilterCandidate]) -> String {
        let data = try? JSONEncoder().encode(candidates)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func stem(_ word: String) -> String {
        if word.count > 3, word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }
}
