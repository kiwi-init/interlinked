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
    static let matchThreshold = 0.85

    nonisolated static func ranked(_ response: JevResponse, visits: [HistoryVisit]) -> [HistoryVisit] {
        visits.enumerated().filter { (response.answers[$0.element.id.uuidString]?.noul ?? 0) >= matchThreshold }.sorted {
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
    var about: String = ""
}
struct ResearchGroup: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var members: [String]
}
enum ResearchRelations {
    static let groupThreshold = 0.85

    static func pairs(_ pages: [ResearchPage]) -> [(String, ResearchPage, ResearchPage)] {
        pages.enumerated().flatMap { index, a in pages.dropFirst(index + 1).map { b in (a.id + "_" + b.id, a, b) } }
    }
    static func request(_ pages: [ResearchPage]) -> JevRequest {
        let described = pages.map {
            PagePassage(id: $0.id, text: $0.about.isEmpty ? $0.title : $0.about)
        }
        return JevRequest(
            state: PassageDecisions.evidence(described),
            questions: Dictionary(uniqueKeysWithValues: pairs(pages).map { id, a, b in
                (id, .relevant(IntelligencePromptPreferences.rendered(
                    .jevRelatedPages,
                    values: [
                        "first_page_id": a.id,
                        "second_page_id": b.id
                    ]
                )))
            })
        )
    }

    /// Word-overlap fallback used when Apple never wrote an about paragraph.
    static func groups(_ pages: [ResearchPage]) -> [ResearchGroup] {
        connected(pages) { a, b, _ in
            let stops: Set<String> = ["the", "and", "for", "with", "from", "review", "reviews", "shop", "best", "www", "com"]
            return PassageDecisions.words(a.title).intersection(PassageDecisions.words(b.title)).subtracting(stops).count >= 2
        }
    }

    /// Jev groups: cliques only. A-B and B-C do not become {A,B,C}.
    static func groups(_ pages: [ResearchPage], response: JevResponse) -> [ResearchGroup] {
        cliques(pages) { a, b, id in
            (response.answers[id]?.noul ?? 0) >= groupThreshold
        }
    }

    private static func connected(
        _ pages: [ResearchPage],
        related: (ResearchPage, ResearchPage, String) -> Bool
    ) -> [ResearchGroup] {
        let edges = pairs(pages).filter { id, a, b in related(a, b, id) }
        var remaining = Set(pages.map(\.id)), result: [ResearchGroup] = []
        for page in pages where remaining.contains(page.id) {
            var members: Set<String> = [page.id], changed = true
            while changed {
                let count = members.count
                for (_, a, b) in edges where members.contains(a.id) || members.contains(b.id) {
                    members.insert(a.id)
                    members.insert(b.id)
                }
                changed = count != members.count
            }
            remaining.subtract(members)
            if members.count > 1 {
                result.append(ResearchGroup(
                    id: page.id,
                    title: page.title,
                    members: pages.filter { members.contains($0.id) }.map(\.id)
                ))
            }
        }
        return result
    }

    private static func cliques(
        _ pages: [ResearchPage],
        related: (ResearchPage, ResearchPage, String) -> Bool
    ) -> [ResearchGroup] {
        let n = pages.count
        guard n >= 2 else { return [] }
        var edge = Array(repeating: Array(repeating: false, count: n), count: n)
        for (id, a, b) in pairs(pages) {
            guard related(a, b, id),
                  let i = pages.firstIndex(where: { $0.id == a.id }),
                  let j = pages.firstIndex(where: { $0.id == b.id }) else { continue }
            edge[i][j] = true
            edge[j][i] = true
        }
        var claimed = Array(repeating: false, count: n)
        var result: [ResearchGroup] = []
        for size in stride(from: n, through: 2, by: -1) {
            func search(_ start: Int, _ picked: [Int]) {
                if picked.count == size {
                    guard picked.allSatisfy({ !claimed[$0] }) else { return }
                    for i in 0..<picked.count {
                        for j in (i + 1)..<picked.count where !edge[picked[i]][picked[j]] { return }
                    }
                    picked.forEach { claimed[$0] = true }
                    let members = picked.map { pages[$0].id }
                    result.append(ResearchGroup(id: pages[picked[0]].id, title: pages[picked[0]].title, members: members))
                    return
                }
                guard start < n else { return }
                for i in start..<n where !claimed[i] {
                    search(i + 1, picked + [i])
                }
            }
            search(0, [])
        }
        return result
    }
}
