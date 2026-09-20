import Foundation

private final class SessionWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "computer.kiwi.session-writer", qos: .utility)
    private var pending: (data: Data, path: URL)?
    private var scheduled = false

    func write(_ data: Data, to path: URL) {
        queue.async { [self] in
            pending = (data, path)
            guard !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in
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
        } catch {
            // A missed write is not worth interrupting anyone over.
        }
    }
}

struct Session: Codable {
    private static let writer = SessionWriter()

    static let version: UInt32 = 1

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

    var isKnown: Bool { version == Session.version }

    func stamped() -> Session {
        var copy = self
        copy.version = Session.version
        return copy
    }

    /// Decode old workspaces without losing any of their web pages.
    func browserOnly() -> Session {
        var copy = self
        let saved = Surfaces.restore(surfaces)
        let selected = tabs.indices.contains(active) ? tabs[active].active : nil
        copy.tabs = []
        copy.next_tab = max(next_tab, (tabs.map { $0.id.rawValue }.max() ?? 0) + 1)
        for tab in tabs {
            let pages = tab.root.leaves().filter { saved.kind($0) == .browser || saved.kind($0) == .blank }
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
        copy.surfaces = copy.tabs.map {
            SurfacePair(pane: $0.active, surface: Surface(kind: .browser, line: saved.line($0.active)))
        }
        copy.next_pane = max(next_pane, (copy.tabs.map { $0.active.rawValue }.max() ?? 0) + 1)
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

    static func read() -> Session? {
        guard let path = path(),
              let data = try? Data(contentsOf: path),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.isKnown
        else { return nil }
        return session
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
        case version, tabs, active, next_tab, next_pane, next_split, surfaces, tint, sidebar, sidebar_last
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
        tint = try container.decodeIfPresent(Tint.self, forKey: .tint) ?? .ink
        sidebar = try container.decodeIfPresent(Float.self, forKey: .sidebar) ?? Float(Metrics.sidebarWidth)
        sidebar_last = try container.decodeIfPresent(Float.self, forKey: .sidebar_last) ?? Float(Metrics.sidebarWidth)
    }
}
