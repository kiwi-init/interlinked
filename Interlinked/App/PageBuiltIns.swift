import AppKit
import Observation

/// The page features Interlinked ships instead of browser extensions: an ad and
/// tracker blocker and a dark mode enforcer. Both act inside the engine.
@MainActor
@Observable
final class PageBuiltIns {
    // uBlock Origin's quick fixes answer ad-delivery changes within days.
    private static let refreshInterval: TimeInterval = 24 * 3600

    var blockingEnabled: Bool { didSet { if blockingEnabled != oldValue { save(); publishRules() } } }
    var darkMode: PageDarkMode { didSet { if darkMode != oldValue { save(); applyDarkMode() } } }
    private(set) var unblockedSites: Set<String>
    private(set) var lightSites: Set<String>
    private(set) var engineReady = false
    private(set) var listsUpdatedAt: Date?
    private(set) var updating = false
    private(set) var status = ""
    private(set) var blockedCounts: [PaneID: Int] = [:]
    private(set) var blockedTotal: Int

    @ObservationIgnored private weak var workspace: Workspace?
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
            .appendingPathComponent("blocker-engine.dat")
    }

    func start(workspace: Workspace) {
        guard self.workspace == nil else { return }
        self.workspace = workspace
        loadCachedRules()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyDarkMode() }
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
        var texts: [String] = []
        let trusted = NSMutableIndexSet()
        for list in BlockList.standard {
            var request = URLRequest(url: list.url, timeoutInterval: 30)
            request.cachePolicy = .reloadRevalidatingCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8), text.count > 1_000 else {
                status = "Could not download \(list.name). Using the saved copy."
                return
            }
            if list.trusted { trusted.add(texts.count) }
            texts.append(text)
        }
        let resources = Self.resourcesJSON
        let serialized = await Task.detached(priority: .utility) {
            ILChromiumRuntime.buildBlocker(withLists: texts, trustedLists: trusted as IndexSet, resourcesJSON: resources)
        }.value
        guard let serialized else {
            status = "The block lists could not be read. Using the saved copy."
            return
        }
        engineReady = true
        listsUpdatedAt = Date()
        defaults.set(listsUpdatedAt, forKey: "builtins.listsUpdatedAt")
        status = ""
        let url = cacheURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? serialized.write(to: url, options: .atomic)
        }
        publishRules()
    }

    /// uBlock Origin's scriptlets and stand-in resources, generated by
    /// script/build-blocker-resources.
    private static var resourcesJSON: String {
        Bundle.main.url(forResource: "blocker-resources", withExtension: "json")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "[]"
    }

    private func loadCachedRules() {
        publishRules()
        let url = cacheURL
        let resources = Self.resourcesJSON
        let updatedAt = defaults.object(forKey: "builtins.listsUpdatedAt") as? Date
        Task {
            let restored = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url)).map { ILChromiumRuntime.restoreBlocker(from: $0, resourcesJSON: resources) } ?? false
            }.value
            if restored {
                engineReady = true
                listsUpdatedAt = updatedAt
            }
            if !restored || updatedAt.map({ Date().timeIntervalSince($0) > Self.refreshInterval }) ?? true {
                await updateLists()
            }
        }
    }

    private func publishRules() {
        ILChromiumRuntime.setContentBlockingEnabled(blockingEnabled, disabledSites: Array(unblockedSites))
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
        let dark = darkens(page.url)
        guard page.forcedDarkMode != dark else { return }
        page.forcedDarkMode = dark
        PageTextBridge.appearanceChanged(page)
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
