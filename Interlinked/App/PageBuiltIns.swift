import AppKit
import Observation

/// The page features Interlinked ships instead of browser extensions: an ad and
/// tracker blocker and a dark mode enforcer. Both act inside the engine.
@MainActor
@Observable
final class PageBuiltIns {
    static let lists = [
        URL(string: "https://easylist.to/easylist/easylist.txt")!,
        URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
    ]
    private static let refreshInterval: TimeInterval = 7 * 24 * 3600

    var blockingEnabled: Bool { didSet { if blockingEnabled != oldValue { save(); publishRules() } } }
    var darkMode: PageDarkMode { didSet { if darkMode != oldValue { save(); applyDarkMode() } } }
    private(set) var unblockedSites: Set<String>
    private(set) var lightSites: Set<String>
    private(set) var ruleCount = 0
    private(set) var listsUpdatedAt: Date?
    private(set) var updating = false
    private(set) var status = ""
    private(set) var blockedCounts: [PaneID: Int] = [:]
    private(set) var blockedTotal: Int

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var rules = FilterRules()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        blockingEnabled = defaults.object(forKey: "builtins.blocking") as? Bool ?? true
        darkMode = defaults.string(forKey: PageDarkMode.defaultsKey).flatMap(PageDarkMode.init) ?? .system
        unblockedSites = Set(defaults.stringArray(forKey: "builtins.unblockedSites") ?? [])
        lightSites = Set(defaults.stringArray(forKey: "builtins.lightSites") ?? [])
        blockedTotal = defaults.integer(forKey: "builtins.blockedTotal")
        cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Interlinked", isDirectory: true)
            .appendingPathComponent("blocking-rules.json")
    }

    func start(workspace: Workspace) {
        guard self.workspace == nil else { return }
        self.workspace = workspace
        loadCachedRules()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyDarkMode() }
        }
        if listsUpdatedAt.map({ Date().timeIntervalSince($0) > Self.refreshInterval }) ?? true {
            Task { await updateLists() }
        }
    }

    func stop() {
        appearanceObservation = nil
        defaults.set(blockedTotal, forKey: "builtins.blockedTotal")
        workspace = nil
    }

    // MARK: - Blocking

    func blocks(_ url: URL?) -> Bool {
        guard blockingEnabled else { return false }
        guard let site = SiteKey.site(url) else { return true }
        return !unblockedSites.contains(site)
    }

    func setBlocking(_ enabled: Bool, for url: URL?) {
        guard let site = SiteKey.site(url) else { return }
        if enabled { unblockedSites.remove(site) } else { unblockedSites.insert(site) }
        save()
        publishRules()
    }

    func removeUnblockedSite(_ site: String) {
        unblockedSites.remove(site)
        save()
        publishRules()
    }

    func blocked(_ count: Int, pane: PaneID) {
        blockedCounts[pane, default: 0] += count
        blockedTotal += count
    }

    func navigated(_ pane: PaneID) { blockedCounts[pane] = nil }

    func forget(keep: (PaneID) -> Bool) {
        blockedCounts = blockedCounts.filter { keep($0.key) }
    }

    func updateLists() async {
        guard !updating else { return }
        updating = true
        status = "Updating block lists…"
        defer { updating = false }
        var merged = FilterRules()
        for list in Self.lists {
            var request = URLRequest(url: list, timeoutInterval: 30)
            request.cachePolicy = .reloadRevalidatingCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else {
                status = "Could not update block lists. Using the saved copy."
                return
            }
            merged.merge(await Task.detached { FilterRules.parse(text) }.value)
        }
        guard !merged.isEmpty else {
            status = "The block lists were empty. Using the saved copy."
            return
        }
        rules = merged
        listsUpdatedAt = Date()
        status = ""
        let snapshot = CachedRules(updatedAt: listsUpdatedAt!, rules: merged)
        let url = cacheURL
        Task.detached {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
        publishRules()
    }

    private struct CachedRules: Codable {
        var updatedAt: Date
        var rules: FilterRules
    }

    private func loadCachedRules() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedRules.self, from: data) else {
            publishRules()
            return
        }
        rules = cached.rules
        listsUpdatedAt = cached.updatedAt
        publishRules()
    }

    private func publishRules() {
        ruleCount = rules.count
        guard blockingEnabled, !rules.isEmpty else {
            ILChromiumRuntime.disableContentBlocking()
            return
        }
        ILChromiumRuntime.setBlockedHosts(Array(rules.blocked), thirdPartyHosts: Array(rules.blockedThirdParty),
                                          allowedHosts: Array(rules.allowed), disabledSites: Array(unblockedSites))
    }

    // MARK: - Dark mode

    func darkens(_ url: URL?) -> Bool {
        let wanted: Bool
        switch darkMode {
        case .off: wanted = false
        case .always: wanted = true
        case .system: wanted = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        guard wanted, let site = SiteKey.site(url) else { return wanted }
        return !lightSites.contains(site)
    }

    func setDarkening(_ enabled: Bool, for url: URL?) {
        guard let site = SiteKey.site(url) else { return }
        if enabled { lightSites.remove(site) } else { lightSites.insert(site) }
        save()
        applyDarkMode()
    }

    func removeLightSite(_ site: String) {
        lightSites.remove(site)
        save()
        applyDarkMode()
    }

    func apply(to page: ChromiumPage) {
        page.forcedDarkMode = darkens(page.url)
    }

    private func applyDarkMode() {
        workspace?.hosts.forEachBrowser { apply(to: $0) }
    }

    private func save() {
        defaults.set(blockingEnabled, forKey: "builtins.blocking")
        defaults.set(darkMode.rawValue, forKey: PageDarkMode.defaultsKey)
        defaults.set(unblockedSites.sorted(), forKey: "builtins.unblockedSites")
        defaults.set(lightSites.sorted(), forKey: "builtins.lightSites")
    }
}
