import Foundation
import Observation

struct BrowserHistoryVisit: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var title: String
    var visited: Date

    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? "" }
}

/// How long visits stay and how many are kept. Applied on load and on
/// every record, so an old file shrinks the first time it is read.
struct HistoryRetention: Equatable, Sendable {
    static let standard = HistoryRetention(days: 90, limit: 5_000)

    var days: Int
    var limit: Int

    /// Newest first in, newest first out.
    func kept(_ visits: [BrowserHistoryVisit], now: Date) -> [BrowserHistoryVisit] {
        let oldest = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return Array(visits.filter { $0.visited >= oldest }.prefix(limit))
    }
}

/// The spans the History panel can clear.
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour = "hour"
    case today
    case everything = "all"

    var id: Self { self }

    var title: String {
        switch self {
        case .lastHour: "Last hour"
        case .today: "Today"
        case .everything: "All history"
        }
    }

    /// The earliest visit the range covers. Nil covers every visit.
    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3_600)
        case .today: calendar.startOfDay(for: now)
        case .everything: nil
        }
    }
}

enum BrowserHistoryPreference {
    static let key = "privacy.browserHistory"

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// The history file. Version 1 was a bare array of visits.
private struct BrowserHistoryFile: Codable {
    static let version = 2

    var version: Int
    var visits: [BrowserHistoryVisit]
}

@MainActor @Observable
final class BrowserHistoryStore {
    private(set) var visits: [BrowserHistoryVisit] = []
    /// Off, nothing is recorded and what was recorded is gone.
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            BrowserHistoryPreference.set(enabled, in: defaults)
            if !enabled { clear() }
        }
    }
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let retention: HistoryRetention
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(
        file: URL? = nil,
        retention: HistoryRetention = .standard,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Interlinked/history.json")
        self.retention = retention
        self.defaults = defaults
        self.now = now
        enabled = BrowserHistoryPreference.enabled(in: defaults)
        guard enabled else {
            try? FileManager.default.removeItem(at: self.file)
            return
        }
        guard let data = try? Data(contentsOf: self.file) else { return }
        let decoder = JSONDecoder()
        if let saved = try? decoder.decode(BrowserHistoryFile.self, from: data) {
            visits = retention.kept(saved.visits, now: now())
            if visits.count != saved.visits.count { save() }
        } else if let legacy = try? decoder.decode([BrowserHistoryVisit].self, from: data) {
            visits = retention.kept(legacy, now: now())
            save()
        }
    }

    func record(_ url: URL?, title: String?) {
        guard enabled, let url = Self.storable(url) else { return }
        let address = url.absoluteString
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = cleanTitle.isEmpty ? CompactLine.host(address) : String(cleanTitle.prefix(180))
        let date = now()
        if visits.first?.url == address {
            visits[0].title = resolvedTitle
            visits[0].visited = date
        } else {
            visits.insert(BrowserHistoryVisit(
                id: UUID(), url: address, title: resolvedTitle, visited: date
            ), at: 0)
        }
        visits = retention.kept(visits, now: date)
        scheduleSave()
    }

    func remove(_ id: UUID) {
        visits.removeAll { $0.id == id }
        save()
    }

    /// Every visit to a site, over http or https, with or without www.
    func removeSite(_ host: String) {
        guard !host.isEmpty else { return }
        visits.removeAll { $0.host == host }
        save()
    }

    func remove(_ range: HistoryRange, calendar: Calendar = .current) {
        guard let start = range.start(now: now(), calendar: calendar) else { return clear() }
        visits.removeAll { $0.visited >= start }
        save()
    }

    func clear() {
        saveTask?.cancel()
        visits = []
        save()
    }

    func save() {
        saveTask?.cancel()
        let saved = BrowserHistoryFile(version: BrowserHistoryFile.version, visits: visits)
        guard let data = try? JSONEncoder().encode(saved) else { return }
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

    /// The pages Jev may compare: open tabs only, never browsing history.
    static func pages(
        tabs: [Tab],
        metadata: [PaneID: PageMetadata],
        portraits: [PaneID: PagePortrait]
    ) -> [ResearchPage] {
        tabs.prefix(8).compactMap { tab in
            guard let page = metadata[tab.active] else { return nil }
            return ResearchPage(
                id: String(tab.id.rawValue),
                title: page.title.isEmpty ? page.host : page.title,
                detail: page.summary,
                host: page.host,
                about: portraits[tab.active]?.about ?? ""
            )
        }
    }

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

    /// Keep Jev cliques for described tabs, and lexical groups that still involve
    /// tabs Apple never described. Do not revive a described-only lexical group
    /// that Jev declined.
    static func merge(remote: [ResearchGroup], fallback: [ResearchGroup], pages: [ResearchPage]) -> [ResearchGroup] {
        let described = Set(pages.filter { !$0.about.isEmpty }.map(\.id))
        var groups = remote
        var claimed = Set(remote.flatMap(\.members))
        for group in fallback {
            let extra = group.members.filter { !claimed.contains($0) }
            let undescribed = extra.filter { !described.contains($0) }
            guard !undescribed.isEmpty else { continue }
            if let host = group.members.first(where: { claimed.contains($0) }),
               let index = groups.firstIndex(where: { $0.members.contains(host) }) {
                let attached = pages.map(\.id).filter { undescribed.contains($0) && !groups[index].members.contains($0) }
                groups[index].members.append(contentsOf: attached)
                claimed.formUnion(attached)
            } else if extra.count > 1, let first = extra.first {
                groups.append(ResearchGroup(
                    id: first,
                    title: pages.first { $0.id == first }?.title ?? group.title,
                    members: extra
                ))
                claimed.formUnion(extra)
            }
        }
        return groups
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
