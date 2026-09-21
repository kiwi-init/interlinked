import AppKit
import SwiftUI

enum LineTarget: Hashable {
    case pane(PaneID)
    case tab(TabID)

    var pane: PaneID? {
        if case .pane(let id) = self { return id }
        return nil
    }

    var tab: TabID? {
        if case .tab(let id) = self { return id }
        return nil
    }
}

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general = "General"
    case intelligence = "Intelligence"
    case builtIns = "Built-ins"
    case data = "Data"
    case sites = "Sites"
    case about = "About"

    var id: Self { self }
}

struct LineEdit: Equatable {
    var target: LineTarget
    var text: String
    var original: String? = nil

    var value: String {
        CompactLine.committed(text, original: original)
    }

    var pane: PaneID? { target.pane }
    var tab: TabID? { target.tab }
}

/// All window state. Every shortcut, button, spoken command, and control-channel
/// request comes through here.
@MainActor
@Observable
final class Workspace {
    static weak var shared: Workspace?

    var tabs: [Tab] = []
    var active: Int = 0
    var nextTab: UInt64 = 1
    var nextPane: UInt64 = 1
    var nextSplit: UInt64 = 1
    var tint: Tint = .ink
    var surfaces = Surfaces()
    var editing: LineEdit? {
        didSet {
            if editing != oldValue { refreshSearch() }
        }
    }
    private(set) var searchResults: [SearchResult] = []
    var selectedSearchResult: Int?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    var sidebar: CGFloat = Metrics.sidebarWidth
    var sidebarLast: CGFloat = Metrics.sidebarWidth
    var voice = Voice()
    let hosts = PaneHosts()
    let assistance = BrowserAssistance()
    let downloads = DownloadCenter()
    let permissions = WebsitePermissionStore()
    let navigationExceptions = NavigationExceptionStore()
    let browserHistory = BrowserHistoryStore()
    let savedSites = SavedSites()
    let builtIns = PageBuiltIns()
    var newTabEditor: SavedSiteKind?
    var usesSiteMenu = SiteMenuPreference.enabled() {
        didSet {
            SiteMenuPreference.set(usesSiteMenu)
            if usesSiteMenu, let pane = activePane {
                declinedSiteMenu.remove(pane)
                captureSiteMenu(pane)
            } else {
                restoreAllSiteHeaders()
            }
        }
    }
    private(set) var siteMenus: [PaneID: SiteMenu] = [:]
    var siteMenuExpanded: String?
    var siteMenuSearching = false
    private var declinedSiteMenu: Set<PaneID> = []
    let intelligenceAudit = IntelligenceAuditStore.shared
    var overviewOpen = false
    var identityOpen = false
    var pageHistoryOpen = false
    var quickSwitchOpen = false
    var leftCommandKeyHeld = false
    var rightCommandKeyHeld = false
    var settingsDestination: SettingsDestination = .general
    private(set) var copiedPageURL: String?

    var sidebarCollapsed: Bool { sidebar <= 0 }

    @ObservationIgnored private var written: Data?
    @ObservationIgnored private var started = false
    @ObservationIgnored weak var browserWindow: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var commandStateObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var control: ControlServer?
    @ObservationIgnored private var copiedPageURLTask: Task<Void, Never>?

    var activeTab: Tab? {
        tabs.indices.contains(active) ? tabs[active] : nil
    }

    var activePane: PaneID? { activeTab?.active }

    var siteMenu: SiteMenu? { activePane.flatMap { siteMenus[$0] } }

    var quickTabs: [Tab] {
        OpenWork.switcherTabs(tabs, current: activeTab?.id)
    }

    func title(_ tab: Tab) -> String {
        OpenWork.title(customName: tab.name, pageTitle: hosts.titles[tab.active], fallback: surfaces.tabTitle(tab))
    }

    func setOverviewOpen(_ open: Bool) {
        guard open != overviewOpen else { return }
        if open {
            newTabEditor = nil
            discardLine()
            closeIdentity()
            hosts.capturePreviews()
            assistance.closePanel()
            assistance.related()
        }
        overviewOpen = open
        if !open {
            restoreFocus()
            beginEmptyPageEditingIfNeeded()
        }
    }

    func toggleOverview() { setOverviewOpen(!overviewOpen) }

    func selectWork(_ tab: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        activateTab(index)
    }

    @discardableResult
    func selectQuickTab(_ index: Int) -> Bool {
        guard quickTabs.indices.contains(index) else { return false }
        selectWork(quickTabs[index].id)
        return true
    }

    func toolboxShortcutLabel(_ shortcut: ToolboxShortcut) -> String {
        shortcut.label
    }

    func togglePersonalFilters() {
        downloads.closePanel()
        assistance.filterPanelOpen ? assistance.closeFilters() : assistance.openFilters()
    }

    var currentPageURL: URL? {
        guard let pane = activePane else { return nil }
        if let url = hosts.existingBrowser(pane)?.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        guard let url = URL(string: surfaces.line(pane)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var isEmptyActivePage: Bool {
        guard let pane = activePane else { return true }
        return NewTabPage.matches(line: surfaces.line(pane))
    }

    var showsCopiedPageURL: Bool {
        CopiedPageURLFeedback.isShowing(copied: copiedPageURL, current: currentPageURL?.absoluteString)
    }

    func beginEmptyPageEditingIfNeeded() {
        guard isEmptyActivePage, !overviewOpen, !identityOpen, editing == nil, newTabEditor == nil else { return }
        guard case .idle = voice.state else { return }
        editActiveLine()
    }

    func beginNewTabEditor(_ kind: SavedSiteKind) {
        newTabEditor = kind
        discardLine()
    }

    func cancelNewTabEditor() {
        guard newTabEditor != nil else { return }
        newTabEditor = nil
        beginEmptyPageEditingIfNeeded()
    }

    @discardableResult
    func submitNewTabSite(_ text: String) -> Bool {
        guard let kind = newTabEditor else { return false }
        guard let site = savedSites.add(text, title: nil, to: kind) else { return false }
        newTabEditor = nil
        rememberFavicon(for: site.url)
        beginEmptyPageEditingIfNeeded()
        return true
    }

    func openPage(_ address: String) {
        if newTabEditor != nil { newTabEditor = nil }
        if isEmptyActivePage, let pane = activePane {
            discardLine()
            surfaces.setKind(pane, .browser)
            surfaces.setLine(pane, address)
            navigate(pane, address)
            keep()
            return
        }
        openAddress(address)
    }

    func toggleCurrentPage(in kind: SavedSiteKind) {
        guard let url = currentPageURL else { return }
        let title = activePane.flatMap { hosts.titles[$0] }
        _ = savedSites.toggle(url.absoluteString, title: title, in: kind)
        if savedSites.contains(url.absoluteString, in: kind) {
            rememberFavicon(for: url.absoluteString)
        }
    }

    func rememberFavicon(for address: String) {
        guard let url = URL(string: address),
              let domain = DomainIconCache<NSImage>.domain(url) else { return }
        keep()
        if let data = hosts.storedIconData(for: domain) {
            savedSites.fillMissingIcon(data, domain: domain)
            return
        }
        if let pane = activePane, let image = hosts.favicons[pane],
           DomainIconCache<NSImage>.domain(currentPageURL) == domain,
           let data = hosts.pngData(image) {
            savedSites.fillMissingIcon(data, domain: domain)
            hosts.rememberIcon(data, for: domain)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let data = await self.hosts.fetchIcon(for: url) else { return }
            self.savedSites.fillMissingIcon(data, domain: domain)
        }
    }

    func refreshMissingSavedSiteIcons() {
        for site in savedSites.favorites + savedSites.bookmarks where site.icon == nil {
            rememberFavicon(for: site.url)
        }
    }

    @discardableResult
    func copyCurrentPageURL() -> Bool {
        guard let address = currentPageURL?.absoluteString else { return false }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(address, forType: .string) else { return false }
        copiedPageURLTask?.cancel()
        copiedPageURL = address
        copiedPageURLTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            self?.copiedPageURL = nil
        }
        return true
    }

    func newPage() {
        openTab(kind: .browser)
        editActiveLine()
    }

    func navigateActive(_ address: String) {
        guard let pane = activePane else {
            openAddress(address)
            return
        }
        if newTabEditor != nil { newTabEditor = nil }
        discardLine()
        surfaces.setKind(pane, .browser)
        surfaces.setLine(pane, address)
        navigate(pane, address)
        keep()
    }

    func noteSiteMenuDocumentChanged(_ pane: PaneID) {
        siteMenus[pane] = nil
        declinedSiteMenu.remove(pane)
        if activePane == pane { collapseSiteMenuChrome() }
    }

    func collapseSiteMenuChrome() {
        siteMenuExpanded = nil
        siteMenuSearching = false
    }

    func activateSiteMenuItem(_ item: SiteMenuItem) {
        if !item.children.isEmpty {
            siteMenuSearching = false
            siteMenuExpanded = item.id
            return
        }
        if !item.href.isEmpty {
            navigateActive(item.href)
            return
        }
        guard let pane = activePane, let view = hosts.existingBrowser(pane) else { return }
        Task { _ = await PageTextBridge.activateSiteMenuItem(view, id: item.id) }
    }

    func submitSiteSearch(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let search = siteMenu?.search, !text.isEmpty,
              var parts = URLComponents(string: search.action) else { return }
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == search.queryParam }
        items.append(URLQueryItem(name: search.queryParam, value: text))
        parts.queryItems = items
        guard let url = parts.url else { return }
        collapseSiteMenuChrome()
        navigateActive(url.absoluteString)
    }

    func captureSiteMenu(_ pane: PaneID) {
        guard usesSiteMenu, !declinedSiteMenu.contains(pane), paneAlive(pane), let view = hosts.existingBrowser(pane) else { return }
        if NewTabPage.matches(line: surfaces.line(pane)) {
            siteMenus[pane] = nil
            return
        }
        // The bar is the browser's, so it is up before the page answers.
        if siteMenus[pane] == nil, let baseline = SiteMenuPolicy.baseline(line: surfaces.line(pane)) {
            siteMenus[pane] = baseline
        }
        let pageURL = view.url
        Task { @MainActor [weak self] in
            guard let self, self.usesSiteMenu, !self.declinedSiteMenu.contains(pane), self.paneAlive(pane),
                  self.hosts.existingBrowser(pane) === view, view.url == pageURL else { return }
            let extracted = await PageTextBridge.siteMenu(view)
            guard self.usesSiteMenu, !self.declinedSiteMenu.contains(pane), self.paneAlive(pane),
                  self.hosts.existingBrowser(pane) === view, view.url == pageURL else { return }
            let accepted = extracted.flatMap { SiteMenuPolicy.accept($0) }
                ?? SiteMenuPolicy.baseline(line: self.surfaces.line(pane))
            guard let accepted else {
                self.siteMenus[pane] = nil
                return
            }
            if accepted.replacesChrome {
                guard await PageTextBridge.hideSiteMenu(view), self.paneAlive(pane),
                      self.hosts.existingBrowser(pane) === view, view.url == pageURL,
                      self.usesSiteMenu, !self.declinedSiteMenu.contains(pane) else { return }
            }
            self.siteMenus[pane] = accepted
        }
    }

    func restoreSiteHeader(_ pane: PaneID? = nil) {
        let target = pane ?? activePane
        guard let target else { return }
        declinedSiteMenu.insert(target)
        siteMenus[target] = nil
        collapseSiteMenuChrome()
        Task { @MainActor [weak self] in
            await PageTextBridge.showSiteMenu(self?.hosts.existingBrowser(target))
        }
    }

    func restoreAllSiteHeaders() {
        let panes = Array(siteMenus.keys)
        siteMenus.removeAll()
        Task { @MainActor [weak self] in
            for pane in panes {
                await PageTextBridge.showSiteMenu(self?.hosts.existingBrowser(pane))
            }
        }
    }

    func openAddress(_ address: String) {
        openTab(kind: .browser)
        guard let pane = activePane else { return }
        surfaces.setLine(pane, address)
        navigate(pane, address)
        keep()
    }

    func closeTab(_ id: TabID) {
        if activeTab?.id == id { assistance.changedTab() }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let selected = activeTab?.id
        tabs.remove(at: index)
        active = tabs.firstIndex(where: { $0.id == selected }) ?? min(active, max(0, tabs.count - 1))
        if let pane = activePane { assistance.activated(pane) }
        finishClosing()
    }

    func escape() {
        if newTabEditor != nil { cancelNewTabEditor() }
        else if pageHistoryOpen { pageHistoryOpen = false }
        else if downloads.panelOpen { downloads.closePanel() }
        else if assistance.filterPanelOpen { assistance.closeFilters() }
        else if assistance.panel != nil { assistance.closePanel() }
        else if identityOpen { closeIdentity() }
        else if siteMenuSearching || siteMenuExpanded != nil { collapseSiteMenuChrome() }
        else if editing != nil {
            discardLine()
            beginEmptyPageEditingIfNeeded()
        }
        else if overviewOpen { setOverviewOpen(false) }
        else { cancelListening() }
    }

    func toggleIdentity() {
        if identityOpen {
            closeIdentity()
            return
        }
        guard currentPageURL != nil else { return }
        discardLine()
        setOverviewOpen(false)
        assistance.closePanel()
        identityOpen = true
    }

    func closeIdentity() {
        guard identityOpen else { return }
        identityOpen = false
        restoreFocus()
    }

    private func restoreFocus() {
        let expectedPane = activePane
        DispatchQueue.main.async { [weak self] in
            guard let self, let pane = expectedPane,
                  self.activePane == pane, !self.overviewOpen, !self.identityOpen, self.editing == nil else { return }
            if self.hosts.focus(pane) { return }
            // SwiftUI may attach the retained Chromium view one run-loop turn
            // after the selected tab changes.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activePane == pane,
                      !self.overviewOpen, !self.identityOpen, self.editing == nil else { return }
                self.hosts.focus(pane)
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        Workspace.shared = self
        builtIns.start(workspace: self)
        assistance.workspace = self
        downloads.refreshNotificationStatus()
        if ProcessInfo.processInfo.arguments.contains("-interlinked-ui-testing") {
            openTab()
        } else if let session = Session.read() {
            restore(session)
            if tabs.isEmpty { openTab() }
        } else {
            openTab()
        }
        hosts.startMemoryPressureMonitoring(workspace: self)
        if let appDelegate = NSApp.delegate as? AppDelegate {
            openExternalURLs(appDelegate.takePendingWebURLs())
        }
        if let raw = ProcessInfo.processInfo.environment["INTERLINKED_UI_TEST_URL"],
           let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            openExternalURLs([url])
        }
        beginEmptyPageEditingIfNeeded()
        #if !TESTFLIGHT
            control = ControlServer()
            control?.start { [weak self] request in
                guard let self else { return "error the app is gone" }
                return Control.dispatch(request, workspace: self)
            }
        #endif
        installMonitors()
    }

    func stop() {
        copiedPageURLTask?.cancel()
        downloads.prepareForTermination()
        assistance.history.save()
        browserHistory.save()
        hosts.stopMemoryPressureMonitoring()
        builtIns.stop()
        keyMonitor.map(NSEvent.removeMonitor)
        flagsMonitor.map(NSEvent.removeMonitor)
        mouseMonitor.map(NSEvent.removeMonitor)
        commandStateObservers.forEach(NotificationCenter.default.removeObserver)
        commandStateObservers.removeAll()
        setCommandKeyState(CommandKeyState(left: false, right: false))
        control?.stop()
        Session.flush()
        Workspace.shared = nil
    }

    func openExternalURLs(_ urls: [URL]) {
        let routes = ExternalURLRouting.routes(
            for: urls,
            canReuseActivePage: activePane.map(canReuseForExternalURL) ?? false
        )
        guard !routes.isEmpty else { return }
        if editing != nil { discardLine() }
        for route in routes {
            if route.destination == .newPage { openTab(kind: .browser) }
            guard let pane = activePane else { continue }
            surfaces.setKind(pane, .browser)
            surfaces.setLine(pane, route.url.absoluteString)
            navigate(pane, route.url.absoluteString)
        }
        keep()
        NSApp.activate(ignoringOtherApps: true)
    }

    func recoverPane(_ pane: PaneID) {
        guard let recovery = hosts.beginRecovery(pane) else { return }
        surfaces.setKind(pane, .browser)
        surfaces.setLine(pane, recovery.url.absoluteString)
        if activePane == pane { navigate(pane, recovery.url.absoluteString) }
        keep()
    }

    func reloadActivePage() {
        guard let pane = activePane else { return }
        if hosts.recovery(for: pane) != nil {
            recoverPane(pane)
        } else {
            hosts.existingBrowser(pane)?.reload()
        }
    }


    func paneAlive(_ pane: PaneID) -> Bool {
        tabs.contains { $0.contains(pane) }
    }

    // MARK: - Session

    func session() -> Session {
        Session(
            version: 0,
            tabs: tabs,
            active: active,
            next_tab: nextTab,
            next_pane: nextPane,
            next_split: nextSplit,
            surfaces: surfaces.entries(),
            tint: tint,
            sidebar: Float(sidebar),
            sidebar_last: Float(sidebarLast)
        ).stamped()
    }

    func restore(_ saved: Session) {
        let session = saved.browserOnly()
        tabs = session.tabs
        active = min(session.active, max(0, tabs.count - 1))
        nextTab = session.next_tab
        nextPane = session.next_pane
        nextSplit = session.next_split
        surfaces = Surfaces.restore(session.surfaces)
        tint = session.tint
        sidebarLast = CGFloat(session.sidebar_last).clamped(to: Metrics.sidebarMin...Metrics.sidebarMax)
        if session.sidebar <= 0 {
            sidebar = 0
        } else {
            sidebar = CGFloat(session.sidebar).clamped(to: Metrics.sidebarMin...Metrics.sidebarMax)
        }

    }

    func keep() {
        hosts.syncFavicons(tabs: tabs, surfaces: surfaces, pinned: savedSites.domains)
        assistance.prune()
        let session = session()
        guard let data = Session.data(session) else { return }
        if data != written {
            written = data
            Session.write(data)
        }
    }

    // MARK: - Tabs and panes

    func openTab(kind: Kind = .browser) {
        if editing != nil { discardLine() }
        assistance.changedTab()
        overviewOpen = false
        let tab = Tab(id: TabID(nextTab), pane: takePane())
        nextTab += 1
        tabs.append(tab)
        active = tabs.count - 1
        if let pane = activePane { _ = setKind(pane, .browser) }
        keep()
    }

    func activateTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if editing != nil { discardLine() }
        assistance.changedTab()
        overviewOpen = false
        active = index
        if let pane = activePane {
            hosts.touch(pane)
            assistance.activated(pane)
        }
        restoreFocus()
        keep()
        beginEmptyPageEditingIfNeeded()
    }

    func cycleTabs(_ step: Int) {
        guard !tabs.isEmpty else { return }
        if editing != nil { discardLine() }
        assistance.changedTab()
        overviewOpen = false
        let count = tabs.count
        active = ((active + step) % count + count) % count
        if let pane = activePane {
            hosts.touch(pane)
            assistance.activated(pane)
        }
        restoreFocus()
        keep()
        beginEmptyPageEditingIfNeeded()
    }

    @discardableResult
    func setKind(_ pane: PaneID, _ kind: Kind) -> Bool {
        guard kind == .browser || kind == .blank else { return false }
        guard tabs.contains(where: { $0.contains(pane) }) else { return false }
        surfaces.setKind(pane, .browser)
        keep()
        return true
    }

    func clearPane(_ pane: PaneID) {
        surfaces.erase(pane)
        if editing?.target == .pane(pane) { discardLine() }
        keep()
    }

    func nameTab(_ tab: TabID, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        tabs[index].name = trimmed.isEmpty ? nil : trimmed
        keep()
    }

    func activatePane(_ pane: PaneID) {
        if activePane != pane { assistance.changedTab() }
        guard let index = tabs.firstIndex(where: { $0.contains(pane) }) else { return }
        active = index
        tabs[index].active = pane
        hosts.touch(pane)
        assistance.activated(pane)
        keep()
    }

    func clickPane(_ pane: PaneID) {
        if editing != nil { editing = nil }
        if identityOpen { closeIdentity() }
        if overviewOpen { overviewOpen = false }
        if quickSwitchOpen { quickSwitchOpen = false }
        if assistance.panel != nil && assistance.panel != .reading { assistance.closePanel() }
        hosts.touch(pane)
        if activePane != pane { activatePane(pane) }
    }

    @discardableResult
    func closePane(_ target: PaneID) -> Bool {
        if activePane == target { assistance.changedTab() }
        guard let index = tabs.firstIndex(where: { $0.contains(target) }) else { return false }
        if tabs[index].close(target) {
            finishClosing()
            return true
        }
        let selected = activeTab?.id
        tabs.remove(at: index)
        active = tabs.firstIndex(where: { $0.id == selected }) ?? min(active, max(0, tabs.count - 1))
        if let pane = activePane { assistance.activated(pane) }
        finishClosing()
        return true
    }

    func closeActive() {
        if let pane = activePane { _ = closePane(pane) }
    }

    func dropTab(_ dragged: TabID, slot: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == dragged }) else { return }
        guard from != slot, tabs.indices.contains(slot) else { return }
        let current = activeTab?.id
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: slot)
        if let current {
            active = tabs.firstIndex(where: { $0.id == current }) ?? active
        }
        keep()
    }

    func setTint(_ tint: Tint) {
        self.tint = tint
        keep()
    }

    func setSidebar(_ width: CGFloat) {
        let next: CGFloat = width <= 0 ? 0 : width.clamped(to: Metrics.sidebarMin...Metrics.sidebarMax)
        if next > 0 { sidebarLast = next }
        sidebar = next
        keep()
    }

    func toggleSidebar() {
        toggleOverview()
    }

    func settleSidebar() {
        setSidebar(Metrics.settleSidebar(sidebar))
    }

    // MARK: - Line

    @discardableResult
    func editLine(_ pane: PaneID) -> Bool {
        guard tabs.contains(where: { $0.contains(pane) }) else { return false }
        overviewOpen = false
        activatePane(pane)
        startWriting(.pane(pane), surfaces.line(pane))
        return true
    }

    func editActiveLine() {
        if let pane = activePane { _ = editLine(pane) }
        else { newPage() }
    }

    @discardableResult
    func editTab(_ tab: TabID) -> Bool {
        guard let open = tabs.first(where: { $0.id == tab }) else { return false }
        startWriting(.tab(tab), surfaces.tabTitle(open))
        return true
    }

    func startWriting(_ target: LineTarget, _ text: String) {
        assistance.closePanel()
        if editing?.target == target { return }
        commitLine()
        overviewOpen = false
        identityOpen = false
        editing = LineEdit(target: target, text: text,
                           original: target.pane == nil ? nil : text)
    }

    private func refreshSearch() {
        assistance.searchHistory(editing?.text ?? "", editing: editing?.pane != nil)
        searchTask?.cancel()
        searchResults = []
        selectedSearchResult = nil
        guard let editing, editing.pane != nil else { return }
        let query = editing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, navigationURL(from: query) == nil,
              editing.original.map({ $0 != query }) ?? true else { return }
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                let results = try await SearchResult.fetch(query)
                try Task.checkCancellation()
                guard let self, self.editing?.text == editing.text, self.editing?.target == editing.target else { return }
                self.searchResults = results
            } catch { /* Return still searches when previews are unavailable. */ }
        }
    }

    var addressResults: [SearchResult] {
        assistance.historyResults.compactMap { visit in URL(string: visit.url).map { SearchResult(title: visit.title, url: $0) } } + searchResults
    }

    func moveSearchSelection(_ step: Int) {
        let searchResults = addressResults
        guard !searchResults.isEmpty else { return }
        if let selectedSearchResult {
            let next = selectedSearchResult + step
            self.selectedSearchResult = searchResults.indices.contains(next) ? next : nil
        } else {
            selectedSearchResult = step < 0 ? searchResults.count - 1 : 0
        }
    }

    func openSearchResult(_ result: SearchResult) {
        guard editing?.pane != nil else { return }
        editing?.text = result.url.absoluteString
        commitLine()
    }

    func openHistoryVisit(_ visit: BrowserHistoryVisit) {
        pageHistoryOpen = false
        guard let pane = activePane else {
            openAddress(visit.url)
            return
        }
        discardLine()
        surfaces.setKind(pane, .browser)
        surfaces.setLine(pane, visit.url)
        navigate(pane, visit.url)
        keep()
    }

    func submitLine() {
        let searchResults = addressResults
        if let index = selectedSearchResult, searchResults.indices.contains(index) {
            openSearchResult(searchResults[index])
        } else { commitLine() }
    }

    func commitLine() {
        guard let editing else { return }
        let written = editing.value
        self.editing = nil
        switch editing.target {
        case .pane(let pane):
            if surfaces.kind(pane) == .blank && !written.isEmpty {
                surfaces.setKind(pane, .browser)
            }
            surfaces.setLine(pane, written)
            if surfaces.kind(pane) == .browser {
                navigate(pane, written)
            }
        case .tab(let tab):
            nameTab(tab, written)
        }
        keep()
        restoreFocus()
        beginEmptyPageEditingIfNeeded()
    }

    func discardLine() {
        editing = nil
        restoreFocus()
    }

    @discardableResult
    func typeInLine(_ text: String) -> Bool {
        guard editing != nil else { return false }
        editing?.text = text
        return true
    }

    func setLineFromHost(_ pane: PaneID, _ line: String) {
        if editing?.target == .pane(pane) { return }
        if surfaces.line(pane) != line {
            surfaces.setLine(pane, line)
            keep()
        }
    }

    func navigate(_ pane: PaneID, _ line: String) {
        let view = hosts.browser(for: pane, workspace: self)
        let url = address(from: line)
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }

    // MARK: - Voice

    func fnKey(held: Bool, command: Bool) {
        if held == voice.fnHeld {
            if held, command, voice.mode == .write, quietlyListening {
                cancelListening()
                startListening(.command)
            }
            return
        }
        voice.fnHeld = held
        if held {
            if command {
                toggleListening(.command)
            } else {
                startListening(.write)
            }
        } else if voice.mode == .write {
            stopListening()
        }
    }

    func toggleListening(_ mode: VoiceMode) {
        if voice.state.isListening {
            cancelListening()
        } else {
            startListening(mode)
        }
    }

    func cancelListening() {
        voice.cancel()
    }

    @discardableResult
    func startListening(_ mode: VoiceMode) -> Bool {
        voice.start(mode: mode, target: activePane) { [weak self] said, mode, _ in
            guard let self else { return }
            switch mode {
            case .command:
                _ = self.act(said)
            case .write:
                self.dictate(said)
            }
        }
        return true
    }

    func stopListening() {
        voice.stop()
    }

    func dictate(_ said: String) {
        let pane = voice.target ?? activePane
        guard let pane else { return }
        if said.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "clear" {
            surfaces.erase(pane)
        } else {
            surfaces.setLine(pane, said)
            if surfaces.kind(pane) == .browser {
                navigate(pane, said)
            }
        }
        voice.markHeard(said: said, outcome: .written)
        keep()
    }

    @discardableResult
    func act(_ said: String) -> VoiceOutcome {
        guard let command = Intent.command(said) else {
            let outcome = VoiceOutcome.notACommand
            voice.markHeard(said: said, outcome: outcome)
            return outcome
        }
        let reply = Control.dispatch(command, workspace: self)
        let outcome: VoiceOutcome
        if reply.hasPrefix("error ") {
            outcome = .refused(String(reply.dropFirst(6)))
        } else {
            outcome = .ran(command)
        }
        voice.markHeard(said: said, outcome: outcome)
        return outcome
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Private

    private var quietlyListening: Bool {
        if case .listening(let heard, _) = voice.state { return heard.isEmpty }
        if case .starting = voice.state { return true }
        return false
    }

    private func canReuseForExternalURL(_ pane: PaneID) -> Bool {
        let line = surfaces.line(pane).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty || line == "about:blank" else { return false }
        guard let url = hosts.existingBrowser(pane)?.url else { return true }
        return url.absoluteString == "about:blank"
    }

    private func takePane() -> PaneID {
        let id = PaneID(nextPane)
        nextPane += 1
        return id
    }

    private func forgetClosed() {
        hosts.forget(keep: paneAlive, kinds: { surfaces.kind($0) }, downloads: downloads)
        builtIns.forget(keep: paneAlive)
        surfaces.forget(keep: paneAlive)
        siteMenus = siteMenus.filter { paneAlive($0.key) }
        declinedSiteMenu = declinedSiteMenu.filter(paneAlive)
        if let editing {
            let gone: Bool
            switch editing.target {
            case .pane(let pane): gone = !paneAlive(pane)
            case .tab(let tab): gone = !tabs.contains { $0.id == tab }
            }
            if gone { self.editing = nil }
        }
    }

    private func finishClosing() {
        forgetClosed()
        if TabClosingPolicy.opensReplacementTab(remainingTabCount: tabs.count) {
            newPage()
        } else {
            restoreFocus()
            keep()
        }
    }

    private func installMonitors() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.synchronizeCommandKeyState()
            guard !PageControlRegion.contains(event) else { return event }
            guard let self, let pane = self.activePane, let browser = self.hosts.existingBrowser(pane),
                  browser.window === event.window, let root = event.window?.contentView,
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
                  hit === browser.nativeView || hit.isDescendant(of: browser.nativeView) else { return event }
            self.clickPane(pane)
            return event // Let links, selection and form controls receive the original click.
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Settings, About, and open or save panels keep their own keys.
            guard event.window === self.browserWindow, NSApp.modalWindow == nil else {
                if NSApp.modalWindow == nil, event.window !== self.browserWindow,
                   event.window?.sheetParent == nil, self.closesWindow(event) {
                    event.window?.performClose(nil)
                    return nil
                }
                return event
            }
            if event.keyCode == 53,
               self.pageHistoryOpen || self.downloads.panelOpen || self.assistance.filterPanelOpen || self.assistance.panel != nil ||
               self.editing != nil || self.overviewOpen {
                self.escape()
                return nil
            }
            if self.performApplicationShortcut(event) { return nil }
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let fn = event.modifierFlags.contains(.function)
            let command = event.modifierFlags.contains(.command)
            let previous = CommandKeyState(left: self.leftCommandKeyHeld, right: self.rightCommandKeyHeld)
            let keys = CommandKeyState.updating(
                previous,
                eventKeyCode: event.keyCode,
                rawModifierFlags: event.modifierFlags.rawValue
            )
            self.setCommandKeyState(keys)
            self.fnKey(held: fn, command: command)
            return event
        }

        let center = NotificationCenter.default
        commandStateObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setCommandKeyState(CommandKeyState(left: false, right: false))
                }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setCommandKeyState(CommandKeyState(left: false, right: false))
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.synchronizeCommandKeyState()
                }
            },
        ]
    }

    private func closesWindow(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "w"
    }

    private func setCommandKeyState(_ state: CommandKeyState) {
        leftCommandKeyHeld = state.left
        rightCommandKeyHeld = state.right
    }

    private func synchronizeCommandKeyState() {
        setCommandKeyState(CommandKeyState.current())
    }

    private func performApplicationShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
        let character = event.charactersIgnoringModifiers?.lowercased()

        if PageURLCopyShortcut.matches(
            character: character,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            function: modifiers.contains(.function)
        ) {
            return copyCurrentPageURL()
        }

        if modifiers == .command, let character, let index = OpenWork.shortcutIndex(character) {
            return selectQuickTab(index)
        }

        if event.keyCode == 48 && (modifiers == .control || modifiers == [.control, .shift]) {
            cycleTabs(modifiers.contains(.shift) ? -1 : 1)
            return true
        }

        switch (character, modifiers) {
        case ("t", .command):
            newPage()
        case ("s", .command):
            assistance.saveToVault()
        case ("s", [.command, .control]):
            toggleOverview()
        case ("]", .command):
            cycleTabs(1)
        case ("[", .command):
            cycleTabs(-1)
        case ("f", [.command, .shift]):
            togglePersonalFilters()
        case ("f", .command):
            assistance.openFind()
        case ("g", .command):
            assistance.moveMatch(1)
        case ("g", [.command, .shift]):
            assistance.moveMatch(-1)
        case ("j", .command):
            assistance.closeFilters()
            if assistance.panel != nil { assistance.closePanel() }
            downloads.togglePanel()
        case ("w", .command):
            closeActive()
        case ("l", .command):
            editActiveLine()
        case ("r", .command):
            reloadActivePage()
        case (",", .command):
            openNativeSettings()
        default:
            return false
        }
        return true
    }

    private func openNativeSettings() {
        settingsDestination = .general
        assistance.closeFilters()
        if assistance.panel != nil { assistance.closePanel() }
        editing = nil
        overviewOpen = false
        identityOpen = false
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
