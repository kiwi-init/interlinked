import Foundation
import CryptoKit

/// Entries cached before the page description was dropped still decode:
/// their `about` key is ignored.
struct PagePortrait: Codable, Equatable, Sendable {
    var label: String
}

/// Five-day cache for on-device page labels.
/// Keyed by host, path, and a hash of the metadata Apple actually saw.
struct PagePortraitCache {
    struct Entry: Codable {
        var createdAt: Date
        var portrait: PagePortrait
    }

    static let fiveDays: TimeInterval = 5 * 24 * 60 * 60

    private let file: URL?
    private let lifetime: TimeInterval
    private let limit: Int
    private let now: () -> Date
    private var entries: [String: Entry]

    init(
        file: URL? = Self.defaultFile,
        lifetime: TimeInterval = Self.fiveDays,
        limit: Int = 512,
        now: @escaping () -> Date = Date.init
    ) {
        self.file = file
        self.lifetime = lifetime
        self.limit = limit
        self.now = now
        entries = file.flatMap(Self.load) ?? [:]
        removeExpired()
        save()
    }

    mutating func value(for key: String) -> PagePortrait? {
        guard let entry = entries[key] else { return nil }
        guard now().timeIntervalSince(entry.createdAt) < lifetime else {
            entries.removeValue(forKey: key)
            save()
            return nil
        }
        return entry.portrait
    }

    mutating func insert(_ portrait: PagePortrait, for key: String) {
        removeExpired()
        if entries.count >= limit,
           let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(createdAt: now(), portrait: portrait)
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
        AppData.url("PagePortraits.json")
    }

    private static func load(_ file: URL) -> [String: Entry]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([String: Entry].self, from: data)
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // A cache write must never break browsing or a live Apple response.
        }
    }
}

extension PageLabels {
    /// Host + path + hash of the metadata sent to Apple. Query strings stay out of the key.
    static func cacheIdentity(_ page: PageMetadata) -> String {
        let host = page.host.lowercased()
        let path: String
        if let url = URL(string: page.url) {
            path = url.path.isEmpty ? "/" : url.path
        } else {
            path = "/"
        }
        let digest = SHA256.hash(data: Data(evidence(page).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return host + "\n" + path + "\n" + digest
    }

    /// The label a pane shows while its page is read: the page's own, unless
    /// the same document is read again and an AI label will be decided for it.
    /// Then the AI label stays until a different one arrives, so a page that
    /// moves its address as you scroll neither flickers nor glows again.
    static func whileReading(_ page: PageMetadata, current: String?, sameDocument: Bool, refines: Bool) -> String {
        if sameDocument, refines, let current { return current }
        return fallback(page)
    }
}
