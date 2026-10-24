import Foundation

/// Writes the session off the main thread, at most 150 ms after a change,
/// so a crash loses no more than that. Each write also refreshes the backup.
final class SessionWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "computer.kiwi.session-writer", qos: .utility)
    private let delay: DispatchTimeInterval
    private var pending: (data: Data, path: URL)?
    private var scheduled = false

    init(delay: DispatchTimeInterval = .milliseconds(150)) {
        self.delay = delay
    }

    func write(_ data: Data, to path: URL) {
        queue.async { [self] in
            pending = (data, path)
            guard !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                drain()
            }
        }
    }

    func flush() {
        queue.sync { [self] in
            scheduled = false
            drainPending()
        }
    }

    private func drain() {
        scheduled = false
        drainPending()
    }

    private func drainPending() {
        guard let pending else { return }
        self.pending = nil
        do {
            try FileManager.default.createDirectory(at: pending.path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pending.data.write(to: pending.path, options: .atomic)
            try pending.data.write(to: Session.backupPath(for: pending.path), options: .atomic)
        } catch {
            // A missed write is not worth interrupting anyone over.
        }
    }
}

/// A tab that was closed, kept so ⇧⌘T can bring it back.
struct ClosedTab: Codable, Equatable {
    static let limit = 25

    var url: String
    /// The name you gave the tab. Nil when it went by the page's title.
    var name: String?
    var closed: Date

    /// Oldest first. The last one is what ⇧⌘T reopens.
    static func remember(_ tab: ClosedTab, in list: [ClosedTab]) -> [ClosedTab] {
        Array((list + [tab]).suffix(limit))
    }
}

/// How far a page was scrolled, and which document that was. A position
/// is only put back on the same address with the same title.
struct ScrollMark: Codable, Equatable {
    var pane: PaneID
    var url: String
    var title: String
    var y: Double

    func fits(url: URL?, title: String?) -> Bool {
        y > 0 && url?.absoluteString == self.url && (title ?? "") == self.title
    }

    /// The page reports its own scrollY and may set it to anything. A value
    /// JSON can't hold would stop every later session save.
    static func sampled(pane: PaneID, url: URL, title: String, y: Double) -> ScrollMark? {
        y > 0 && y.isFinite ? ScrollMark(pane: pane, url: url.absoluteString, title: title, y: y) : nil
    }
}

/// What reopens at launch. Form values, passwords, and back and forward
/// history are never part of it.
struct Session: Codable {
    private static let writer = SessionWriter()

    /// 2 added recently closed tabs and scroll positions.
    static let version: UInt32 = 2

    var version: UInt32
    var tabs: [Tab]
    var active: Int
    var next_tab: UInt64
    var next_pane: UInt64
    var next_split: UInt64
    var surfaces: [SurfacePair]
    var tint: Tint
    var sidebar: Float
    var sidebar_last: Float
    var closed: [ClosedTab] = []
    var scroll: [ScrollMark] = []

    /// Every version this build can read. Older ones gain empty new fields.
    var isKnown: Bool { (1...Session.version).contains(version) }

    func stamped() -> Session {
        var copy = self
        copy.version = Session.version
        return copy
    }

    /// Decode old workspaces without losing any of their web pages. A split
    /// view of web pages comes back as it was. Any other split, from layouts
    /// that also held terminals or more panes, becomes one tab per page.
    func browserOnly() -> Session {
        var copy = self
        let saved = Surfaces.restore(surfaces)
        let selected = tabs.indices.contains(active) ? tabs[active].active : nil
        copy.tabs = []
        copy.next_tab = max(next_tab, (tabs.map { $0.id.rawValue }.max() ?? 0) + 1)
        for tab in tabs {
            let leaves = tab.root.leaves()
            let pages = leaves.filter { saved.kind($0) == .browser || saved.kind($0) == .blank }
            if pages.count > 1, pages.count == leaves.count, pages.count <= Tab.maxPanes {
                copy.tabs.append(tab)
                if case .split(let id, _, _, _) = tab.root {
                    copy.next_split = max(copy.next_split, id.rawValue + 1)
                }
                continue
            }
            let primary = pages.contains(tab.active) ? tab.active : pages.first
            for page in pages {
                let id = page == primary ? tab.id : TabID(copy.next_tab)
                if page != primary { copy.next_tab += 1 }
                var restored = Tab(id: id, pane: page)
                restored.name = page == primary ? tab.name : nil
                copy.tabs.append(restored)
            }
        }
        copy.active = copy.tabs.firstIndex { $0.active == selected } ?? min(active, max(0, copy.tabs.count - 1))
        copy.surfaces = copy.tabs.flatMap(\.panes).map {
            SurfacePair(pane: $0, surface: Surface(kind: .browser, line: saved.line($0)))
        }
        copy.next_pane = max(next_pane, (copy.tabs.flatMap(\.panes).map(\.rawValue).max() ?? 0) + 1)
        return copy
    }

    static func path() -> URL? {
        if let named = ProcessInfo.processInfo.environment["INTERLINKED_SESSION"] {
            return URL(fileURLWithPath: named)
        }
        guard let home = FileManager.default.homeDirectoryForCurrentUser as URL? else { return nil }
        return home
            .appendingPathComponent("Library/Application Support/Interlinked")
            .appendingPathComponent("session.json")
    }

    static func backupPath(for path: URL) -> URL {
        path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".backup")
    }

    static func read() -> Session? {
        path().flatMap { read(at: $0) }
    }

    /// An unreadable session is kept aside as `session.json.corrupt-<time>`
    /// and the backup from the last good save opens instead.
    static func read(at path: URL, now: Date = Date()) -> Session? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        if let session = decode(path) { return session }
        let stamp = Int((now.timeIntervalSince1970 * 1_000).rounded())
        let aside = path.deletingLastPathComponent().appendingPathComponent("\(path.lastPathComponent).corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: path, to: aside)
        return decode(backupPath(for: path))
    }

    private static func decode(_ path: URL) -> Session? {
        guard let data = try? Data(contentsOf: path),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.isKnown
        else { return nil }
        return session.stamped()
    }

    static func data(_ session: Session) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(session.stamped())
    }

    static func write(_ data: Data) {
        guard let path = path() else { return }
        writer.write(data, to: path)
    }

    /// Finish already queued writes before the process exits.
    static func flush() {
        writer.flush()
    }
}

extension Session {
    enum CodingKeys: String, CodingKey {
        case version, tabs, active, next_tab, next_pane, next_split, surfaces, tint, sidebar, sidebar_last, closed, scroll
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt32.self, forKey: .version)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        active = try container.decode(Int.self, forKey: .active)
        next_tab = try container.decode(UInt64.self, forKey: .next_tab)
        next_pane = try container.decode(UInt64.self, forKey: .next_pane)
        next_split = try container.decode(UInt64.self, forKey: .next_split)
        surfaces = try container.decode([SurfacePair].self, forKey: .surfaces)
        // A tint from a newer build falls back rather than losing the session.
        tint = (try? container.decodeIfPresent(Tint.self, forKey: .tint)) ?? .ink
        sidebar = try container.decodeIfPresent(Float.self, forKey: .sidebar) ?? Float(Metrics.sidebarWidth)
        sidebar_last = try container.decodeIfPresent(Float.self, forKey: .sidebar_last) ?? Float(Metrics.sidebarWidth)
        closed = Array((try container.decodeIfPresent([ClosedTab].self, forKey: .closed) ?? []).suffix(ClosedTab.limit))
        scroll = try container.decodeIfPresent([ScrollMark].self, forKey: .scroll) ?? []
    }
}
