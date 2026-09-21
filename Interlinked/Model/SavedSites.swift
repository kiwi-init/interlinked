import Foundation
import Observation

enum SavedSiteKind: String, Codable, Equatable, Sendable {
    case favorite
    case bookmark

    var symbol: String {
        switch self {
        case .favorite: "heart.fill"
        case .bookmark: "bookmark.fill"
        }
    }

    var accessibilityName: String {
        switch self {
        case .favorite: "Favorites"
        case .bookmark: "Bookmarks"
        }
    }
}

enum NewTabSavedSitesPreference {
    static let key = "newTab.savedSites"

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

struct SavedSite: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var title: String
    var createdAt: Date
    var icon: Data?
}

enum NewTabArt {
    static let imageName = "NewTabArt"
    static let artistName = "Techniacus"
    static let artistURL = URL(string: "https://x.com/Techniacus")!
}

enum SavedSiteAddress {
    static let favoriteLimit = 8
    static let bookmarkLimit = 40

    static func normalize(_ raw: String) -> (url: String, title: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = navigationURL(from: trimmed) ?? URL(string: trimmed) else { return nil }
        guard var parts = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = parts.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return nil }
        parts.scheme = scheme
        parts.user = nil
        parts.password = nil
        parts.host = parts.host?.lowercased()
        if parts.path == "/" { parts.path = "" }
        guard let host = parts.host, !host.isEmpty, let address = parts.string else { return nil }
        let title = CompactLine.host(address)
        guard !title.isEmpty else { return nil }
        return (address, title)
    }
}

/// User-pinned shortcuts and bookmarks. A later Chrome/Safari import can fill these lists.
@MainActor @Observable
final class SavedSites {
    private(set) var favorites: [SavedSite] = []
    private(set) var bookmarks: [SavedSite] = []
    var showsOnNewTab: Bool {
        didSet { NewTabSavedSitesPreference.set(showsOnNewTab, in: defaults) }
    }
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults: UserDefaults

    init(file: URL? = nil, defaults: UserDefaults = .standard) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Interlinked/saved-sites.json")
        self.defaults = defaults
        showsOnNewTab = NewTabSavedSitesPreference.enabled(in: defaults)
        if let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode(Payload.self, from: data) {
            favorites = Array(saved.favorites.prefix(SavedSiteAddress.favoriteLimit))
            bookmarks = Array(saved.bookmarks.prefix(SavedSiteAddress.bookmarkLimit))
        }
    }

    func contains(_ url: String, in kind: SavedSiteKind) -> Bool {
        guard let address = SavedSiteAddress.normalize(url)?.url else { return false }
        return list(kind).contains { $0.url == address }
    }

    @discardableResult
    func add(_ raw: String, title: String?, to kind: SavedSiteKind) -> SavedSite? {
        guard let normalized = SavedSiteAddress.normalize(raw) else { return nil }
        if let existing = list(kind).first(where: { $0.url == normalized.url }) {
            return existing
        }
        guard list(kind).count < limit(kind) else { return nil }
        let given = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let site = SavedSite(
            id: UUID(),
            url: normalized.url,
            title: given.isEmpty ? normalized.title : String(given.prefix(80)),
            createdAt: Date(),
            icon: nil
        )
        switch kind {
        case .favorite: favorites.append(site)
        case .bookmark: bookmarks.append(site)
        }
        save()
        return site
    }

    func remove(_ id: UUID, from kind: SavedSiteKind) {
        switch kind {
        case .favorite: favorites.removeAll { $0.id == id }
        case .bookmark: bookmarks.removeAll { $0.id == id }
        }
        save()
    }

    @discardableResult
    func toggle(_ raw: String, title: String?, in kind: SavedSiteKind) -> Bool {
        guard let normalized = SavedSiteAddress.normalize(raw) else { return false }
        if let existing = list(kind).first(where: { $0.url == normalized.url }) {
            remove(existing.id, from: kind)
            return false
        }
        return add(raw, title: title, to: kind) != nil
    }

    var domains: Set<String> {
        Set((favorites + bookmarks).compactMap { DomainIconCache<Bool>.domain(URL(string: $0.url)) })
    }

    func setIcon(_ data: Data, id: UUID) {
        if let index = favorites.firstIndex(where: { $0.id == id }) {
            guard favorites[index].icon != data else { return }
            favorites[index].icon = data
            save()
        } else if let index = bookmarks.firstIndex(where: { $0.id == id }) {
            guard bookmarks[index].icon != data else { return }
            bookmarks[index].icon = data
            save()
        }
    }

    func fillMissingIcon(_ data: Data, domain: String) {
        var changed = false
        for index in favorites.indices where favorites[index].icon == nil {
            guard DomainIconCache<Bool>.domain(URL(string: favorites[index].url)) == domain else { continue }
            favorites[index].icon = data
            changed = true
        }
        for index in bookmarks.indices where bookmarks[index].icon == nil {
            guard DomainIconCache<Bool>.domain(URL(string: bookmarks[index].url)) == domain else { continue }
            bookmarks[index].icon = data
            changed = true
        }
        if changed { save() }
    }

    func save() {
        let payload = Payload(favorites: favorites, bookmarks: bookmarks)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func list(_ kind: SavedSiteKind) -> [SavedSite] {
        kind == .favorite ? favorites : bookmarks
    }

    private func limit(_ kind: SavedSiteKind) -> Int {
        kind == .favorite ? SavedSiteAddress.favoriteLimit : SavedSiteAddress.bookmarkLimit
    }

    private struct Payload: Codable {
        var favorites: [SavedSite]
        var bookmarks: [SavedSite]
    }
}
