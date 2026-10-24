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
