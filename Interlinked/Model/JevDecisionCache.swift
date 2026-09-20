import Foundation

/// A five-day cache for exact Jev decisions. It stores request hashes and
/// responses, never page text, queries, URLs, or credentials.
struct JevDecisionCache {
    struct Entry: Codable {
        var createdAt: Date
        var response: JevResponse
    }

    static let fiveDays: TimeInterval = 5 * 24 * 60 * 60

    private let file: URL?
    private let lifetime: TimeInterval
    private let limit: Int
    private let now: () -> Date
    private var entries: [String: Entry]

    init(file: URL? = Self.defaultFile,
         lifetime: TimeInterval = Self.fiveDays,
         limit: Int = 512,
         now: @escaping () -> Date = Date.init) {
        self.file = file
        self.lifetime = lifetime
        self.limit = limit
        self.now = now
        entries = file.flatMap(Self.load) ?? [:]
        removeExpired()
        save()
    }

    mutating func value(for key: String) -> JevResponse? {
        guard let entry = entries[key] else { return nil }
        guard now().timeIntervalSince(entry.createdAt) < lifetime else {
            entries.removeValue(forKey: key)
            save()
            return nil
        }
        return entry.response
    }

    mutating func insert(_ response: JevResponse, for key: String) {
        removeExpired()
        if entries.count >= limit,
           let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(createdAt: now(), response: response)
        save()
    }

    mutating func removeAll() {
        entries.removeAll()
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }

    private mutating func removeExpired() {
        let cutoff = now().addingTimeInterval(-lifetime)
        entries = entries.filter { $0.value.createdAt > cutoff }
    }

    private static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Interlinked", isDirectory: true)
            .appendingPathComponent("JevDecisionCache.json")
    }

    private static func load(_ file: URL) -> [String: Entry]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([String: Entry].self, from: data)
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // A cache write must never break browsing or a live Jev response.
        }
    }
}
