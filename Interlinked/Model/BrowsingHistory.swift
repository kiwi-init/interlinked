import Foundation
import Observation

struct BrowserHistoryVisit: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var title: String
    var visited: Date

    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? "" }
}

@MainActor @Observable
final class BrowserHistoryStore {
    private(set) var visits: [BrowserHistoryVisit] = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Interlinked/history.json")
        if let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode([BrowserHistoryVisit].self, from: data) {
            visits = Array(saved.prefix(500))
        }
    }

    func record(_ url: URL?, title: String?) {
        guard let url = Self.storable(url) else { return }
        let address = url.absoluteString
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = cleanTitle.isEmpty ? CompactLine.host(address) : String(cleanTitle.prefix(180))
        if visits.first?.url == address {
            visits[0].title = resolvedTitle
            visits[0].visited = Date()
        } else {
            visits.insert(BrowserHistoryVisit(
                id: UUID(), url: address, title: resolvedTitle, visited: Date()
            ), at: 0)
        }
        visits = Array(visits.prefix(500))
        scheduleSave()
    }

    func remove(_ id: UUID) {
        visits.removeAll { $0.id == id }
        save()
    }

    func clear() {
        saveTask?.cancel()
        visits = []
        save()
    }

    func save() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(visits) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                self?.save()
            } catch { }
        }
    }

    nonisolated private static func storable(_ url: URL?) -> URL? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host != nil, parts.user == nil, parts.password == nil,
              parts.queryItems?.contains(where: {
                  $0.name.lowercased().range(of: "token|key|auth|session|code|password", options: .regularExpression) != nil
              }) != true else { return nil }
        parts.fragment = nil
        return parts.url
    }
}

struct HistoryVisit: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var title: String
    var summary: String
    var passages: [PagePassage]? = nil
    var visited: Date
    var host: String { URL(string: url)?.host ?? "" }
    var evidence: String { [title, summary, host].joined(separator: "\n") }
    var savedText: String { (passages ?? []).map(\.text).joined(separator: "\n") }
}

@MainActor @Observable
final class BrowsingHistory {
    private(set) var visits: [HistoryVisit] = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Interlinked/vault.json")
        if let data = try? Data(contentsOf: self.file), let saved = try? JSONDecoder().decode([HistoryVisit].self, from: data) {
            visits = Array(saved.prefix(500))
        }
    }
    func record(_ page: PageMetadata, passages: [PagePassage] = []) {
        // Password pages, local servers, credentials and likely tokens are never recorded.
        guard page.publicWebPage, let url = URLComponents(string: page.url),
              url.queryItems?.contains(where: { $0.name.lowercased().range(of: "token|key|auth|session|code|password", options: .regularExpression) != nil }) != true else { return }
        let old = visits.first { $0.url == page.url }
        visits.removeAll { $0.url == page.url }
        visits.insert(HistoryVisit(id: old?.id ?? UUID(), url: page.url, title: String(page.title.prefix(180)),
                                   summary: String(page.summary.prefix(240)), passages: passages, visited: Date()), at: 0)
        visits = Array(visits.prefix(500))
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation(); self?.save() } catch {}
        }
    }
    func clear() { saveTask?.cancel(); visits = []; save() }
    func remove(_ id: UUID) { visits.removeAll { $0.id == id }; save() }
    func save() {
        guard let data = try? JSONEncoder().encode(visits) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func candidates(_ query: String) -> [HistoryVisit] {
        let terms = PassageDecisions.words(query)
        return visits.enumerated().sorted {
            let a = PassageDecisions.words($0.element.evidence + " " + $0.element.savedText).intersection(terms).count
            let b = PassageDecisions.words($1.element.evidence + " " + $1.element.savedText).intersection(terms).count
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(24).map(\.element)
    }
    func exact(_ query: String) -> [HistoryVisit] {
        candidates(query).filter { OpenWork.matches(query, title: $0.title, details: [$0.host, $0.summary, $0.savedText]) }.prefix(3).map { $0 }
    }
    nonisolated static func request(_ query: String, visits: [HistoryVisit]) -> JevRequest {
        JevRequest(state: PassageDecisions.evidence(visits.map { visit in
            let snippets = PassageDecisions.candidates(query: query, passages: visit.passages ?? [], limit: 2).map(\.text).joined(separator: "\n")
            return PagePassage(id: visit.id.uuidString, text: visit.evidence + "\n" + String(snippets.prefix(900)))
        }), questions:
            Dictionary(uniqueKeysWithValues: visits.map { visit in
                (visit.id.uuidString, .relevant(IntelligencePromptPreferences.rendered(
                    .jevVaultSearch,
                    values: [
                        "page_id": visit.id.uuidString,
                        "query": String(reflecting: query)
                    ]
                )))
            }))
    }
    nonisolated static func ranked(_ response: JevResponse, visits: [HistoryVisit]) -> [HistoryVisit] {
        visits.enumerated().filter { (response.answers[$0.element.id.uuidString]?.noul ?? 0) >= 0.72 }.sorted {
            let a = response.answers[$0.element.id.uuidString]?.noul ?? 0, b = response.answers[$1.element.id.uuidString]?.noul ?? 0
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(3).map(\.element)
    }
}

struct ResearchPage: Sendable {
    var id: String
    var title: String
    var detail: String
    var host: String
}
struct ResearchGroup: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var members: [String]
}
enum ResearchRelations {
    static func pairs(_ pages: [ResearchPage]) -> [(String, ResearchPage, ResearchPage)] {
        pages.enumerated().flatMap { index, a in pages.dropFirst(index + 1).map { b in (a.id + "_" + b.id, a, b) } }
    }
    static func request(_ pages: [ResearchPage]) -> JevRequest {
        JevRequest(state: PassageDecisions.evidence(pages.map { PagePassage(id: $0.id, text: $0.title + "\n" + $0.detail + "\n" + $0.host) }), questions:
            Dictionary(uniqueKeysWithValues: pairs(pages).map { id, a, b in
                (id, .relevant(IntelligencePromptPreferences.rendered(
                    .jevRelatedPages,
                    values: [
                        "first_page_id": a.id,
                        "second_page_id": b.id
                    ]
                )))
            }))
    }
    static func groups(_ pages: [ResearchPage], response: JevResponse? = nil) -> [ResearchGroup] {
        let stops: Set<String> = ["the", "and", "for", "with", "from", "review", "reviews", "shop", "best", "www", "com"]
        let edges = pairs(pages).filter { id, a, b in
            if let response { return (response.answers[id]?.noul ?? 0) >= 0.8 }
            let common = PassageDecisions.words(a.title).intersection(PassageDecisions.words(b.title)).subtracting(stops)
            return common.count >= 2
        }
        var remaining = Set(pages.map(\.id)), result: [ResearchGroup] = []
        for page in pages where remaining.contains(page.id) {
            var members: Set<String> = [page.id], changed = true
            while changed {
                let count = members.count
                for (_, a, b) in edges where members.contains(a.id) || members.contains(b.id) { members.insert(a.id); members.insert(b.id) }
                changed = count != members.count
            }
            remaining.subtract(members)
            if members.count > 1 { result.append(ResearchGroup(id: page.id, title: page.title, members: pages.filter { members.contains($0.id) }.map(\.id))) }
        }
        return result
    }

    static func groups(_ pages: [ResearchPage], memberGroups: [[String]]) -> [ResearchGroup] {
        let allowed = Set(pages.map(\.id))
        var claimed = Set<String>()
        return memberGroups.compactMap { proposed in
            let members = pages.map(\.id).filter { allowed.contains($0) && proposed.contains($0) && claimed.insert($0).inserted }
            guard members.count > 1, let first = pages.first(where: { $0.id == members[0] }) else { return nil }
            return ResearchGroup(id: first.id, title: first.title, members: members)
        }
    }
}
