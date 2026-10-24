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
    case pages = "Pages"
    case intelligence = "Intelligence"
    case sites = "Sites"
    case privacy = "Privacy"

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
    let search = SearchSettings()
    @ObservationIgnored private lazy var remoteSuggestions = RemoteSuggestions(settings: search)
    var sidebar: CGFloat = Metrics.sidebarWidth
    var sidebarLast: CGFloat = Metrics.sidebarWidth
    var voice = Voice()
    let hosts = PaneHosts()
    let assistance = BrowserAssistance()
    let downloads = DownloadCenter()
    let permissions = WebsitePermissionStore()
    let navigationExceptions = NavigationExceptionStore()
    let browserHistory = BrowserHistoryStore()
    let builtIns = PageBuiltIns()
    let usefulInfo = UsefulInfo()
    let onboarding = OnboardingGuide()
    /// Blurs emails, phone numbers, card and document numbers, keys, and
    /// passwords on every page, for presenting or sharing the screen.
    var sharingScreenMode = SharingScreenModePreference.enabled() {
        didSet {
            guard sharingScreenMode != oldValue else { return }
            SharingScreenModePreference.set(sharingScreenMode)
            hosts.forEachBrowser { $0.sharingScreenShield = sharingScreenMode }
        }
    }
    let intelligenceAudit = IntelligenceAuditStore.shared
    var overviewOpen = false
    var identityOpen = false
    var pageHistoryOpen = false {
        didSet { if !pageHistoryOpen { historyClearing = false } }
    }
    /// The History panel shows the time ranges it can clear instead of visits.
    var historyClearing = false
    /// Oldest first. ⇧⌘T reopens the last.
    private(set) var recentlyClosed: [ClosedTab] = []
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
    /// SwiftUI's `openSettings`, handed over by the browser window.
    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var commandStateObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var control: ControlServer?
    @ObservationIgnored private var copiedPageURLTask: Task<Void, Never>?
    @ObservationIgnored private var scrollMarks: [PaneID: ScrollMark] = [:]
    @ObservationIgnored private var scrollPanes: Set<PaneID> = []
    @ObservationIgnored private var scrollTask: Task<Void, Never>?
    @ObservationIgnored private var scrollMonitor: Any?

    var activeTab: Tab? {
        tabs.indices.contains(active) ? tabs[active] : nil
    }

    var activePane: PaneID? { activeTab?.active }

    var quickTabs: [Tab] {
        OpenWork.switcherTabs(tabs, current: activeTab?.id, pinned: onboardingTab?.id)
    }

    /// The name a tab goes by everywhere: your name for it, else the label
    /// the page handle shows, else the page's own title.
    func title(_ tab: Tab) -> String {
        if tab.panes == [onboarding.pane] { return Self.onboardingTitle }
        return OpenWork.title(customName: tab.name, pageTitle: assistance.labels[tab.active] ?? hosts.titles[tab.active],
                       fallback: surfaces.tabTitle(tab))
    }

    func setOverviewOpen(_ open: Bool) {
        guard open != overviewOpen else { return }
        if open {
            discardLine()
            closeIdentity()
            pageHistoryOpen = false
            downloads.closePanel()
            hosts.capturePreviews()
            assistance.closePanel()
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
        // Before start() there is no page yet. Calling that empty would
        // autofocus the first render's address field, which can take focus
        // after start() has opened a launch URL and leave it in editing.
        guard started else { return false }
        guard let pane = activePane else { return true }
        if onboarding.contains(pane) { return false }
        return NewTabPage.matches(line: surfaces.line(pane))
    }

    var showsCopiedPageURL: Bool {
        CopiedPageURLFeedback.isShowing(copied: copiedPageURL, current: currentPageURL?.absoluteString)
    }

    func beginEmptyPageEditingIfNeeded() {
        guard isEmptyActivePage, !overviewOpen, !identityOpen, editing == nil else { return }
        guard case .idle = voice.state else { return }
        editActiveLine()
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
        guard let pane = activePane, !onboarding.contains(pane) else {
            openAddress(address)
            return
        }
        discardLine()
        surfaces.setKind(pane, .browser)
        surfaces.setLine(pane, address)
        navigate(pane, address)
        keep()
    }

    func openAddress(_ address: String) {
        openTab(kind: .browser)
        guard let pane = activePane else { return }
        surfaces.setLine(pane, address)
        navigate(pane, address)
        keep()
        restoreFocus()
    }

    func closeTab(_ id: TabID) {
        if let pane = onboarding.pane, tabs.first(where: { $0.id == id })?.contains(pane) == true {
            onboarding.protect()
            return
        }
        if activeTab?.id == id { assistance.changedTab() }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        rememberClosed(tabs[index])
        let selected = activeTab?.id
        tabs.remove(at: index)
        active = tabs.firstIndex(where: { $0.id == selected }) ?? min(active, max(0, tabs.count - 1))
        if let pane = activePane { assistance.activated(pane) }
        finishClosing()
    }

    func escape() {
        if usefulInfo.contactOpen { usefulInfo.contactOpen = false }
        else if historyClearing { historyClearing = false }
        else if pageHistoryOpen { pageHistoryOpen = false }
        else if downloads.panelOpen { downloads.closePanel() }
        else if assistance.escapeCloses { assistance.closePanel() }
        else if identityOpen { closeIdentity() }
        else if editing != nil {
            discardLine()
            beginEmptyPageEditingIfNeeded()
        }
        else if overviewOpen { setOverviewOpen(false) }
        else { cancelListening() }
    }

    /// Something Escape puts back. The page itself may hold focus, so the
    /// key monitor takes Escape for these rather than leaving it to SwiftUI.
    var escapeCloses: Bool {
        usefulInfo.contactOpen || pageHistoryOpen || downloads.panelOpen || assistance.escapeCloses || identityOpen
            || editing != nil || overviewOpen
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
        pageHistoryOpen = false
        downloads.closePanel()
        identityOpen = true
    }

    /// History and downloads morph the page handle, so they take its place
    /// from whatever else it was showing.
    func togglePageHistory() {
        let open = !pageHistoryOpen
        if open { preparePagePanel() }
        pageHistoryOpen = open
    }

    func beginClearingHistory() {
        guard pageHistoryOpen, !browserHistory.visits.isEmpty else { return }
        historyClearing = true
    }

    func clearHistory(_ range: HistoryRange) {
        browserHistory.remove(range)
        historyClearing = false
    }

    func toggleDownloads() {
        let open = !downloads.panelOpen
        if open { preparePagePanel() }
        downloads.togglePanel()
    }

    private func preparePagePanel() {
        discardLine()
        setOverviewOpen(false)
        closeIdentity()
        assistance.closePanel()
        pageHistoryOpen = false
        downloads.closePanel()
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
            // SwiftUI may attach the retained page view one run-loop turn
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
        ChromeCursor.install()
        // Vault, favorites, and bookmarks were removed. Nothing reads their files.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for file in ["Interlinked/vault.json", "Interlinked/saved-sites.json"] {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(file))
        }
        UserDefaults.standard.removeObject(forKey: "newTab.savedSites")
        builtIns.start(workspace: self)
        usefulInfo.workspace = self
        assistance.workspace = self
        downloads.refreshNotificationStatus()
        if ProcessInfo.processInfo.arguments.contains("-interlinked-ui-testing") {
            openTab()
        } else {
            if let session = Session.read() { restore(session) }
            #if DEBUG
            // Developer option: the whole flow, from the start, every launch.
            if onboarding.alwaysShow { onboarding.reset() }
            #endif
            if onboarding.showsAtLaunch { openOnboarding() }
            if tabs.isEmpty { openTab() }
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
        browserHistory.save()
        intelligenceAudit.flush()
        hosts.stopMemoryPressureMonitoring()
        builtIns.stop()
        keyMonitor.map(NSEvent.removeMonitor)
        flagsMonitor.map(NSEvent.removeMonitor)
        mouseMonitor.map(NSEvent.removeMonitor)
        scrollMonitor.map(NSEvent.removeMonitor)
        scrollTask?.cancel()
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
        // Onboarding is rebuilt at launch from its own saved progress.
        var saved = tabs
        if let pane = onboarding.pane {
            saved = tabs.compactMap { tab in
                guard tab.contains(pane) else { return tab }
                guard tab.isSplit else { return nil }
                var rest = tab
                rest.close(pane)
                return rest
            }
        }
        let current = activeTab?.id
        let savedPanes = Set(saved.flatMap(\.panes))
        return Session(
            version: 0,
            tabs: saved,
            active: saved.firstIndex { $0.id == current } ?? min(active, max(0, saved.count - 1)),
            next_tab: nextTab,
            next_pane: nextPane,
            next_split: nextSplit,
            surfaces: surfaces.entries(),
            tint: tint,
            sidebar: Float(sidebar),
            sidebar_last: Float(sidebarLast),
            closed: recentlyClosed,
            scroll: scrollMarks.values.filter { savedPanes.contains($0.pane) }.sorted { $0.pane.rawValue < $1.pane.rawValue }
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
        recentlyClosed = session.closed
        scrollMarks = [:]
        for mark in session.scroll where paneAlive(mark.pane) {
            scrollMarks[mark.pane] = mark
            hosts.expectScroll(mark)
        }
    }

    func keep() {
        noteOnboarding()
        hosts.syncFavicons(tabs: tabs, surfaces: surfaces)
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
        onboarding.record(.openedTab)
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
        releasePage(pane)
        keep()
    }

    /// An erased pane holds no page. Its page stops and is released, so its
    /// sound ends and its next address change can't refill the line.
    private func releasePage(_ pane: PaneID) {
        hosts.forget(keep: holdsPage, downloads: downloads)
        assistance.committed(pane)
        usefulInfo.committed(pane)
    }

    private func holdsPage(_ pane: PaneID) -> Bool {
        paneAlive(pane) && surfaces.holdsPage(pane)
    }

    func nameTab(_ tab: TabID, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        tabs[index].name = trimmed.isEmpty ? nil : trimmed
        keep()
    }

    func activatePane(_ pane: PaneID) {
        guard let index = tabs.firstIndex(where: { $0.contains(pane) }) else { return }
        if activePane != pane { assistance.changedTab() }
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
        if pageHistoryOpen { pageHistoryOpen = false }
        if downloads.panelOpen { downloads.closePanel() }
        if usefulInfo.contactOpen { usefulInfo.contactOpen = false }
        if assistance.panel != nil { assistance.closePanel() }
        hosts.touch(pane)
        if activePane != pane {
            activatePane(pane)
            beginEmptyPageEditingIfNeeded()
        }
    }

    @discardableResult
    func closePane(_ target: PaneID) -> Bool {
        // ⌘W and close buttons never close onboarding by accident.
        if onboarding.contains(target) {
            onboarding.protect()
            return false
        }
        if activePane == target { assistance.changedTab() }
        guard let index = tabs.firstIndex(where: { $0.contains(target) }) else { return false }
        // Closing the split ends a scene; the next one may open its own page.
        var advanced = false
        defer { if advanced { prepareOnboardingScene() } }
        if tabs[index].isSplit, let pane = onboarding.pane, tabs[index].contains(pane) {
            let before = onboarding.progress
            onboarding.record(.closedPane)
            advanced = onboarding.progress != before
        }
        rememberClosed(target, name: tabs[index].isSplit ? nil : tabs[index].name)
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

    // MARK: - Recently closed

    private func rememberClosed(_ tab: Tab) {
        for pane in tab.panes {
            rememberClosed(pane, name: pane == tab.active ? tab.name : nil)
        }
    }

    /// Pages only. A new tab page or the Onboarding tab has nothing to reopen.
    private func rememberClosed(_ pane: PaneID, name: String?) {
        guard !onboarding.contains(pane), surfaces.holdsPage(pane) else { return }
        let loaded = hosts.existingBrowser(pane)?.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let url = loaded?.absoluteString ?? surfaces.line(pane)
        recentlyClosed = ClosedTab.remember(ClosedTab(url: url, name: name, closed: Date()), in: recentlyClosed)
    }

    /// ⇧⌘T: the last closed page, in a new tab, with the name you gave it.
    func reopenClosedTab() {
        guard let closed = recentlyClosed.popLast() else { return }
        openAddress(closed.url)
        if let name = closed.name, let tab = activeTab?.id { nameTab(tab, name) }
    }

    // MARK: - Scroll position

    /// Scrolling or typing may have moved the visible pages. Once it stops,
    /// note how far each one is scrolled for the next launch.
    private func noteScrollSoon() {
        guard let tab = activeTab else { return }
        scrollPanes.formUnion(tab.panes)
        scrollTask?.cancel()
        scrollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let panes = self.scrollPanes
            self.scrollPanes = []
            await self.sampleScroll(panes)
        }
    }

    private func sampleScroll(_ panes: Set<PaneID>) async {
        var changed = false
        for pane in panes.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard !onboarding.contains(pane), let page = hosts.existingBrowser(pane), let url = page.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let value = try? await page.evaluateJavaScript("window.scrollY")
            guard paneAlive(pane), hosts.existingBrowser(pane) === page, page.url == url,
                  let y = (value as? NSNumber)?.doubleValue else { continue }
            let mark = y > 0 ? ScrollMark(pane: pane, url: url.absoluteString, title: page.title ?? "", y: y) : nil
            if scrollMarks[pane] != mark {
                scrollMarks[pane] = mark
                changed = true
            }
        }
        if changed { keep() }
    }

    /// A new document makes the old position meaningless.
    func noteDocumentChanged(_ pane: PaneID, url: URL?) {
        if let mark = scrollMarks[pane], mark.url != url?.absoluteString {
            scrollMarks[pane] = nil
        }
    }

    // MARK: - Onboarding

    static let onboardingTitle = "Welcome to Interlinked"

    var onboardingTab: Tab? {
        guard let pane = onboarding.pane else { return nil }
        return tabs.first { $0.contains(pane) }
    }

    /// Away from the Onboarding tab with something still to do: the coach
    /// carries the rest of the instruction onto whatever page is showing.
    var showsOnboardingCoach: Bool {
        guard let tab = onboardingTab else { return false }
        return activeTab?.id != tab.id && onboarding.progress.next != nil && !overviewOpen
    }

    /// Opens the Onboarding tab first in line, or goes back to it.
    func openOnboarding() {
        if editing != nil { discardLine() }
        overviewOpen = false
        if let pane = onboarding.pane, tabs.contains(where: { $0.contains(pane) }) {
            activatePane(pane)
            return
        }
        if onboarding.startsFresh { switchOffOnboardingFeatures() }
        let pane = takePane()
        tabs.insert(Tab(id: TabID(nextTab), pane: pane), at: 0)
        nextTab += 1
        active = 0
        onboarding.opened(in: pane)
        assistance.changedTab()
        keep()
        prepareOnboardingScene()
    }

    /// Records a step taken on the Onboarding page, like Next, and sets up
    /// whatever the scene it leads to needs.
    func advanceOnboarding(_ step: OnboardingStep) {
        onboarding.record(step)
        if step == .finished {
            closeOnboarding()
            return
        }
        prepareOnboardingScene()
    }

    /// A scene with a real page opens it beside Onboarding, focused, so its
    /// features act there. One side pane is reused from scene to scene, and
    /// a scene without a page closes it.
    private func prepareOnboardingScene() {
        guard onboarding.progress.next != nil, let pane = onboarding.pane,
              let index = tabs.firstIndex(where: { $0.contains(pane) }) else { return }
        let side = onboarding.sidePane.flatMap { tabs[index].contains($0) ? $0 : nil }
        guard let page = onboarding.progress.scene.page else {
            if let side {
                onboarding.sidePane = nil
                closePane(side)
            }
            return
        }
        if activeTab?.id != tabs[index].id { activateTab(index) }
        let target: PaneID
        if let existing = side ?? tabs[index].otherPane {
            target = existing
        } else {
            target = takePane()
            guard tabs[index].split(pane, axis: .columns, new: target, id: SplitID(nextSplit)) else { return }
            nextSplit += 1
        }
        onboarding.sidePane = target
        // The page gets the room; the instructions need little.
        tabs[index].ratio = page.onboardingShare
        let address = page.url.absoluteString
        if surfaces.line(target) != address {
            surfaces.setKind(target, .browser)
            surfaces.setLine(target, address)
            navigate(target, address)
        }
        activatePane(target)
        assistance.changedTab()
        keep()
        restoreFocus()
    }

    /// Find for me came back with something to show.
    func noteOnboardingFound() {
        guard onboardingTab != nil else { return }
        onboarding.record(.foundWithMeaning)
    }

    /// The deliberate way out. It will not open at launch again.
    func closeOnboarding() {
        guard let pane = onboarding.pane, let index = tabs.firstIndex(where: { $0.contains(pane) }) else {
            onboarding.dismissed()
            return
        }
        onboarding.dismissed()
        if tabs[index].isSplit {
            tabs[index].close(pane)
        } else {
            let selected = activeTab?.id
            tabs.remove(at: index)
            active = tabs.firstIndex { $0.id == selected } ?? min(active, max(0, tabs.count - 1))
        }
        finishClosing()
    }

    /// Steps that are states rather than actions: being back on the
    /// Onboarding tab, and seeing it split.
    func noteOnboarding() {
        guard let tab = onboardingTab else { return }
        if activeTab?.id == tab.id { onboarding.record(.cameBack) }
        if tab.isSplit { onboarding.record(.split) }
    }


    func binding(for feature: OnboardingFeature) -> Binding<Bool> {
        switch feature {
        case .appleIntelligence:
            Binding(
                get: { self.assistance.appleEnabled && LocalIntelligenceRuntime.isAvailable },
                set: { on in
                    // Not set up on this Mac yet: take them to where it is.
                    if on && !LocalIntelligenceRuntime.isAvailable {
                        Self.openAppleIntelligenceSettings()
                        return
                    }
                    self.assistance.appleEnabled = on
                    self.assistance.configure()
                }
            )
        case .jev:
            Binding(get: { self.assistance.enabled }, set: { on in
                self.assistance.enabled = on
                self.assistance.configure()
            })
        case .sharingScreen:
            Binding(get: { self.sharingScreenMode }, set: { self.sharingScreenMode = $0 })
        case .usefulInfo:
            Binding(get: { self.usefulInfo.showsAddress && self.usefulInfo.showsContact }, set: { on in
                self.usefulInfo.showsAddress = on
                self.usefulInfo.showsContact = on
            })
        case .adBlocking:
            Binding(get: { self.builtIns.blockingEnabled }, set: { self.builtIns.blockingEnabled = $0 })
        case .darkPages:
            Binding(get: { self.builtIns.darkMode != .off }, set: { self.builtIns.darkMode = $0 ? .system : .off })
        }
    }

    /// A line under a feature's description when it cannot simply switch on.
    func note(for feature: OnboardingFeature) -> String? {
        switch feature {
        case .appleIntelligence where !LocalIntelligenceRuntime.isAvailable:
            "Off on this Mac. The switch opens System Settings."
        case .darkPages where builtIns.darkModeWaitsForSystem:
            "Follows macOS, which is light. Choose Always in Settings to darken pages now."
        default: nil
        }
    }

    /// A feature whose switch would change nothing visible right now.
    func disables(_ feature: OnboardingFeature) -> Bool {
        feature == .darkPages && builtIns.darkModeWaitsForSystem
    }

    static func openAppleIntelligenceSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Features a fresh onboarding introduces start off, so switching them
    /// on is part of learning them.
    private func switchOffOnboardingFeatures() {
        builtIns.blockingEnabled = false
        builtIns.darkMode = .off
        sharingScreenMode = false
        usefulInfo.showsAddress = false
        usefulInfo.showsContact = false
        assistance.appleEnabled = false
        assistance.enabled = false
        assistance.configure()
    }

    /// ⌥⌘T: a new page beside this one, or a new tab when already split.
    func newPageBeside() {
        if activeTab?.canSplit == true { splitActive() } else { newPage() }
    }

    // MARK: - Split view

    /// Sets the first page's share of the width for the active tab's split.
    func setSplitRatio(_ ratio: Double) {
        guard activeTab?.isSplit == true else { return }
        tabs[active].ratio = ratio.clamped(to: Tab.ratioRange)
        keep()
    }

    var isSplit: Bool { activeTab?.isSplit ?? false }

    /// Opens a new page beside the focused one. It takes focus.
    func splitActive() {
        guard let pane = activePane, activeTab?.canSplit == true else { return }
        if editing != nil { discardLine() }
        overviewOpen = false
        let new = takePane()
        guard tabs[active].split(pane, axis: .columns, new: new, id: SplitID(nextSplit)) else { return }
        nextSplit += 1
        surfaces.setKind(new, .browser)
        assistance.changedTab()
        keep()
        editActiveLine()
    }

    /// Leaves split view without losing a page: the pane beside the focused
    /// one moves to its own tab, right after this one.
    func unsplit() {
        guard let tab = activeTab, let other = tab.otherPane, let pane = activePane else { return }
        if editing != nil { discardLine() }
        tabs[active].close(other)
        tabs[active].active = pane
        tabs.insert(Tab(id: TabID(nextTab), pane: other), at: active + 1)
        nextTab += 1
        keep()
        restoreFocus()
    }

    /// A page dragged from another tab lands on one side of this one. In a
    /// split it replaces the page on that side, which takes the dragged tab's
    /// place, so nothing closes.
    func dropTab(_ dragged: TabID, leading: Bool) {
        guard let current = activeTab, dragged != current.id,
              let source = tabs.firstIndex(where: { $0.id == dragged }) else { return }
        if editing != nil { discardLine() }
        overviewOpen = false
        let incoming = tabs[source].active
        var tab = current
        var emptiedSource = false
        if tab.isSplit {
            let replaced = leading ? tab.panes[0] : tab.panes[tab.panes.count - 1]
            tab.root.replace(replaced, with: incoming)
            tabs[source].root.replace(incoming, with: replaced)
            tabs[source].active = replaced
        } else {
            let pane = tab.active
            guard tab.split(pane, axis: .columns, new: incoming, id: SplitID(nextSplit)) else { return }
            nextSplit += 1
            if leading { tab.root.swap(pane, incoming) }
            if tabs[source].isSplit { tabs[source].close(incoming) } else { emptiedSource = true }
        }
        tab.active = incoming
        let currentID = current.id
        if let index = tabs.firstIndex(where: { $0.id == currentID }) { tabs[index] = tab }
        if emptiedSource { tabs.removeAll { $0.id == dragged } }
        active = tabs.firstIndex(where: { $0.id == currentID }) ?? active
        assistance.changedTab()
        hosts.touch(incoming)
        assistance.activated(incoming)
        keep()
        restoreFocus()
    }

    /// Best title for one page: what it calls itself, else where it is.
    func title(_ pane: PaneID) -> String {
        if onboarding.contains(pane) { return Self.onboardingTitle }
        let line = surfaces.line(pane)
        let fallback = line.isEmpty ? "New page" : surfaces.kind(pane).compactLabel(for: line)
        return OpenWork.title(customName: nil, pageTitle: assistance.labels[pane] ?? hosts.titles[pane],
                              fallback: fallback.isEmpty ? line : fallback)
    }

    func toggleSplitView() {
        isSplit ? unsplit() : splitActive()
    }

    func focusOtherPane() {
        guard let other = activeTab?.otherPane else { return }
        clickPane(other)
        restoreFocus()
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
        pageHistoryOpen = false
        downloads.closePanel()
        editing = LineEdit(target: target, text: text,
                           original: target.pane == nil ? nil : text)
    }

    private func refreshSearch() {
        remoteSuggestions.cancel()
        searchResults = []
        selectedSearchResult = nil
        guard let editing, let pane = editing.pane else { return }
        let query = editing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, editing.original.map({ $0 != query }) ?? true else { return }
        searchResults = LocalSuggestions.rank(query, tabs: localCandidates(excluding: pane), history: browserHistory.visits)
        remoteSuggestions.request(query) { [weak self] remote in
            guard let self, self.editing?.text == editing.text, self.editing?.target == editing.target else { return }
            let local = Set(self.searchResults.map(\.url))
            self.searchResults += remote.filter { !local.contains($0.url) }
        }
    }

    /// The pages open in other tabs, for local suggestions.
    private func localCandidates(excluding pane: PaneID) -> [LocalCandidate] {
        tabs.compactMap { tab in
            let page = tab.active
            guard !tab.contains(pane), !onboarding.contains(page), surfaces.kind(page) == .browser else { return nil }
            let line = surfaces.line(page)
            guard !line.isEmpty else { return nil }
            return LocalCandidate(title: title(tab), url: address(from: line).absoluteString)
        }
    }

    func moveSearchSelection(_ step: Int) {
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
        guard let pane = activePane, !onboarding.contains(pane) else {
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
        if let index = selectedSearchResult, searchResults.indices.contains(index) {
            openSearchResult(searchResults[index])
        } else { commitLine() }
    }

    func commitLine() {
        guard let editing else { return }
        let written = editing.value
        self.editing = nil
        switch editing.target {
        case .pane(let pane) where onboarding.contains(pane):
            // The Onboarding tab is not a web page: an address opens a new tab.
            if !written.isEmpty { openAddress(written) }
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
        // A closed pane must not get a page no tab can show.
        guard paneAlive(pane) else { return }
        guard surfaces.holdsPage(pane) else { return releasePage(pane) }
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
        guard let pane = DictationTarget.pane(started: voice.target, active: activePane, in: tabs) else {
            voice.markHeard(said: said, outcome: .refused("The page closed before dictation finished."))
            return
        }
        if said.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "clear" {
            clearPane(pane)
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
        guard !onboarding.contains(pane) else { return false }
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
        hosts.forget(keep: holdsPage, downloads: downloads)
        usefulInfo.prune(keep: paneAlive)
        surfaces.forget(keep: paneAlive)
        scrollMarks = scrollMarks.filter { paneAlive($0.key) }
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
            // In split view either page can be clicked; the one clicked leads.
            guard let self, let tab = self.activeTab, let root = event.window?.contentView,
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
                  let pane = tab.panes.first(where: { pane in
                      guard let browser = self.hosts.existingBrowser(pane), browser.window === event.window else { return false }
                      return hit === browser.nativeView || hit.isDescendant(of: browser.nativeView)
                  }) else { return event }
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
            if event.keyCode == 53, !self.composingText(in: event.window), self.escapeCloses {
                self.escape()
                return nil
            }
            if self.performApplicationShortcut(event) { return nil }
            self.noteScrollSoon()
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.browserWindow { self.noteScrollSoon() }
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

    /// Escape during input method composition cancels the candidates, not the
    /// edit or the open panel.
    private func composingText(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
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
        case ("t", [.command, .shift]):
            reopenClosedTab()
        case ("t", [.command, .option]):
            newPageBeside()
        case ("s", [.command, .control]):
            toggleOverview()
        case ("]", .command):
            cycleTabs(1)
        case ("[", .command):
            cycleTabs(-1)
        case ("f", .command):
            assistance.openFind()
        case ("g", .command):
            assistance.moveMatch(1)
        case ("g", [.command, .shift]):
            assistance.moveMatch(-1)
        case ("j", .command):
            toggleDownloads()
        case ("\\", .command):
            toggleSplitView()
        case ("\\", [.command, .option]):
            focusOtherPane()
        case ("s", [.command, .shift]):
            sharingScreenMode.toggle()
        case ("w", .command):
            closeActive()
        case ("l", .command):
            editActiveLine()
        case ("r", .command):
            reloadActivePage()
        case (",", .command):
            return openNativeSettings(.general)
        default:
            return false
        }
        return true
    }

    /// AppKit ignores `showSettingsWindow:` on macOS 14 and later, so ⌘, goes
    /// through SwiftUI's own action. Without it the Settings menu item takes
    /// the key, and the window keeps its state.
    @discardableResult
    func openNativeSettings(_ destination: SettingsDestination) -> Bool {
        guard let openSettings else { return false }
        settingsDestination = destination
        if assistance.panel != nil { assistance.closePanel() }
        editing = nil
        overviewOpen = false
        identityOpen = false
        openSettings()
        return true
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
