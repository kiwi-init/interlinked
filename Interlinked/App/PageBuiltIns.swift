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
    private(set) var systemIsDark = false

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let resourcesCacheURL: URL
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        blockingEnabled = defaults.object(forKey: "builtins.blocking") as? Bool ?? true
        darkMode = defaults.string(forKey: PageDarkMode.defaultsKey).flatMap(PageDarkMode.init) ?? .system
        unblockedSites = Set(defaults.stringArray(forKey: "builtins.unblockedSites") ?? [])
        lightSites = Set(defaults.stringArray(forKey: "builtins.lightSites") ?? [])
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Interlinked", isDirectory: true)
        // blocker-engine.dat was built before the engine parsed procedural
        // filters and holds them as plain selectors, so it is rebuilt.
        cacheURL = directory.appendingPathComponent("blocker-engine-2.dat")
        resourcesCacheURL = directory.appendingPathComponent("blocker-resources.json")
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("blocker-engine.dat"))
    }

    func start(workspace: Workspace) {
        guard self.workspace == nil else { return }
        self.workspace = workspace
        loadCachedRules()
        systemIsDark = Self.appearanceIsDark
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.systemIsDark = Self.appearanceIsDark
                self?.applyDarkMode()
            }
        }
    }

    func stop() {
        appearanceObservation = nil
        refreshTask?.cancel()
        refreshTask = nil
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

    func updateLists() async {
        guard !updating else { return }
        updating = true
        status = "Updating block lists…"
        defer { updating = false }
        var texts: [String] = []
        var missing: [String] = []
        let trusted = NSMutableIndexSet()
        for list in BlockList.standard {
            var request = URLRequest(url: list.url, timeoutInterval: 30)
            request.cachePolicy = .reloadRevalidatingCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8), text.count > 1_000 else {
                missing.append(list.name)
                continue
            }
            if list.trusted { trusted.add(texts.count) }
            texts.append(text)
        }
        // A saved engine has every list, so it stays until all of them
        // download. Without one, block with what arrived; the hourly check
        // tries again because the lists are not marked updated.
        if let first = missing.first {
            if engineReady || texts.isEmpty {
                status = engineReady ? "Could not download \(first). Using the saved copy."
                                     : "Could not download the block lists. Blocking starts once they download."
                return
            }
        }
        if let remote = BlockerResources.remoteURL {
            await BlockerResources.refresh(from: remote, cache: resourcesCacheURL)
        }
        let resources = resourcesJSON
        let built = await Task.detached(priority: .utility) {
            BlockerEngine.build(lists: texts, trusted: trusted as IndexSet, resourcesJSON: resources)
        }.value
        guard let built, await ContentBlocker.shared.compile(built.ruleLists) else {
            status = "The block lists could not be read. Using the saved copy."
            return
        }
        ContentBlocker.shared.install(built.engine)
        engineReady = true
        if let first = missing.first {
            status = "Could not download \(first). Blocking with the other lists until it downloads."
        } else {
            listsUpdatedAt = Date()
            defaults.set(listsUpdatedAt, forKey: "builtins.listsUpdatedAt")
            status = ""
        }
        let url = cacheURL, serialized = built.serialized
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? serialized.write(to: url, options: .atomic)
        }
        publishRules()
    }

    /// uBlock Origin's scriptlets and stand-in resources: the remote copy when
    /// this build has a remote source, else the bundled one.
    private var resourcesJSON: String {
        BlockerResources.load(cache: BlockerResources.remoteURL == nil ? nil : resourcesCacheURL,
                              bundled: Bundle.main.url(forResource: "blocker-resources", withExtension: "json"))
    }

    private func loadCachedRules() {
        publishRules()
        #if DEBUG
        if let list = Self.uiTestFilters {
            // UI tests load test-fixtures/blocker-filters.txt instead of the
            // standard lists.
            let resources = resourcesJSON
            Task {
                guard let built = BlockerEngine.build(lists: [list], trusted: IndexSet(), resourcesJSON: resources),
                      await ContentBlocker.shared.compile(built.ruleLists) else { return }
                ContentBlocker.shared.install(built.engine)
                engineReady = true
                publishRules()
            }
            return
        }
        #endif
        let url = cacheURL
        let resources = resourcesJSON
        let updatedAt = defaults.object(forKey: "builtins.listsUpdatedAt") as? Date
        Task {
            let engine = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url)).flatMap { BlockerEngine.restore($0, resourcesJSON: resources) }
            }.value
            // WebKit keeps the compiled network rules; the engine keeps the rest.
            let restored = await ContentBlocker.shared.restoreRuleLists() && engine != nil
            if restored, let engine {
                ContentBlocker.shared.install(engine)
                engineReady = true
                listsUpdatedAt = updatedAt
                publishRules()
            }
            if !restored || updatedAt.map({ Date().timeIntervalSince($0) > Self.refreshInterval }) ?? true {
                await updateLists()
            }
        }
        keepListsFresh()
    }

    /// Lists refresh daily while the app stays open, and a failed download is
    /// tried again within the hour instead of at the next launch.
    private func keepListsFresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self, !Task.isCancelled else { return }
                if self.listsUpdatedAt.map({ Date().timeIntervalSince($0) > Self.refreshInterval }) ?? true {
                    await self.updateLists()
                }
            }
        }
    }

    #if DEBUG
    private static var uiTestFilters: String? {
        guard ProcessInfo.processInfo.arguments.contains("-interlinked-ui-testing"),
              let path = ProcessInfo.processInfo.environment["INTERLINKED_UI_TEST_FILTERS"] else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
    #endif

    private func publishRules() {
        ContentBlocker.shared.setEnabled(blockingEnabled, disabledSites: Array(unblockedSites))
        workspace?.hosts.forEachBrowser { $0.refreshContentBlocking() }
    }

    // MARK: - Dark mode

    func darkens(_ url: URL?) -> Bool {
        let wanted: Bool
        switch darkMode {
        case .off: wanted = false
        case .always: wanted = true
        case .system: wanted = Self.appearanceIsDark
        }
        guard wanted, let site = SiteKey.site(url) else { return wanted }
        return !lightSites.contains(site)
    }

    /// Matching macOS while macOS is light leaves every page as it is, so a
    /// switch for dark pages would appear to do nothing.
    var darkModeWaitsForSystem: Bool { darkMode == .system && !systemIsDark }

    private static var appearanceIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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

    func apply(to page: WebKitPage) {
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
