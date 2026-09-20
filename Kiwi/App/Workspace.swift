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
    var overviewOpen = false
    var quickSwitchOpen = false

    var sidebarCollapsed: Bool { sidebar <= 0 }

    @ObservationIgnored private var written: Data?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var control: ControlServer?

    var activeTab: Tab? {
        tabs.indices.contains(active) ? tabs[active] : nil
    }

    var activePane: PaneID? { activeTab?.active }

    func title(_ tab: Tab) -> String {
        OpenWork.title(customName: tab.name, pageTitle: hosts.titles[tab.active], fallback: surfaces.tabTitle(tab))
    }

    func setOverviewOpen(_ open: Bool) {
        guard open != overviewOpen else { return }
        if open {
            discardLine()
            hosts.capturePreviews()
            assistance.closePanel()
            assistance.related()
        }
        overviewOpen = open
        if !open { restoreFocus() }
    }

    func toggleOverview() { setOverviewOpen(!overviewOpen) }

    func selectWork(_ tab: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        activateTab(index)
    }

    func newPage() {
        openTab(kind: .browser)
        editActiveLine()
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
        forgetClosed()
        if tabs.isEmpty { setOverviewOpen(true) }
        keep()
    }

    func escape() {
        if assistance.panel != nil { assistance.closePanel() }
        else if editing != nil { discardLine() }
        else if overviewOpen { setOverviewOpen(false) }
        else { cancelListening() }
    }

    private func restoreFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.overviewOpen, self.editing == nil else { return }
            if let pane = self.activePane {
                self.hosts.focus(pane)
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        Workspace.shared = self
        assistance.workspace = self
        if let session = Session.read() {
            restore(session)
            if tabs.isEmpty { openTab() }
        } else {
            openTab()
        }
        control = ControlServer()
        control?.start { [weak self] request in
            guard let self else { return "error the app is gone" }
            return Control.dispatch(request, workspace: self)
        }
        installMonitors()
    }

    func stop() {
        assistance.history.save()
        keyMonitor.map(NSEvent.removeMonitor)
        flagsMonitor.map(NSEvent.removeMonitor)
        mouseMonitor.map(NSEvent.removeMonitor)
        control?.stop()
        Session.flush()
        Workspace.shared = nil
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
        keep()
    }

    func activateTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if editing != nil { discardLine() }
        assistance.changedTab()
        overviewOpen = false
        active = index
        if let pane = activePane { assistance.activated(pane) }
        restoreFocus()
        keep()
    }

    func cycleTabs(_ step: Int) {
        guard !tabs.isEmpty else { return }
        if editing != nil { discardLine() }
        assistance.changedTab()
        overviewOpen = false
        let count = tabs.count
        active = ((active + step) % count + count) % count
        if let pane = activePane { assistance.activated(pane) }
        restoreFocus()
        keep()
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
        assistance.activated(pane)
        keep()
    }

    func clickPane(_ pane: PaneID) {
        if editing != nil { editing = nil }
        if overviewOpen { overviewOpen = false }
        if quickSwitchOpen { quickSwitchOpen = false }
        if assistance.panel != nil && assistance.panel != .reading { assistance.closePanel() }
        if activePane != pane { activatePane(pane) }
    }

    @discardableResult
    func closePane(_ target: PaneID) -> Bool {
        if activePane == target { assistance.changedTab() }
        guard let index = tabs.firstIndex(where: { $0.contains(target) }) else { return false }
        if tabs[index].close(target) {
            forgetClosed()
            keep()
            return true
        }
        tabs.remove(at: index)
        active = min(active, max(0, tabs.count - 1))
        if let pane = activePane { assistance.activated(pane) }
        forgetClosed()
        keep()
        return true
    }

    func closeActive() {
        if let pane = activePane { _ = closePane(pane) }
        if tabs.isEmpty { setOverviewOpen(true) }
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

    private func takePane() -> PaneID {
        let id = PaneID(nextPane)
        nextPane += 1
        return id
    }

    private func forgetClosed() {
        hosts.forget(keep: paneAlive, kinds: { surfaces.kind($0) })
        surfaces.forget(keep: paneAlive)
        if let editing {
            let gone: Bool
            switch editing.target {
            case .pane(let pane): gone = !paneAlive(pane)
            case .tab(let tab): gone = !tabs.contains { $0.id == tab }
            }
            if gone { self.editing = nil }
        }
    }

    private func installMonitors() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard !PageControlRegion.contains(event) else { return event }
            guard let self, let pane = self.activePane, let browser = self.hosts.existingBrowser(pane),
                  browser.window === event.window, let root = event.window?.contentView,
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
                  hit === browser || hit.isDescendant(of: browser) else { return event }
            self.clickPane(pane)
            return event // Let links, selection and form controls receive the original click.
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 48 && (modifiers == .control || modifiers == [.control, .shift]) {
                self?.cycleTabs(modifiers.contains(.shift) ? -1 : 1)
                return nil
            }
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let fn = event.modifierFlags.contains(.function)
            let command = event.modifierFlags.contains(.command)
            self?.fnKey(held: fn, command: command)
            return event
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
