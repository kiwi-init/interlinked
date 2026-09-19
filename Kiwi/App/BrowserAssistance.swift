import AppKit
import Observation
import WebKit

struct JevLabelEffect: Equatable {
    var id = UUID()
    var pane: PaneID
}

@MainActor @Observable
final class BrowserAssistance {
    enum Panel { case find, reading, permission }
    var panel: Panel?
    var query = ""
    var byMeaning = true
    var status = ""
    var busy = false
    var findings: [PassageDecisions.Finding] = []
    var matches: [PagePassage] = []
    var matchIndex = 0
    var historyResults: [HistoryVisit] = []
    var historyStatus = ""
    var vaultStatus = ""
    var lastDecisionStatus = ""
    var findScores: [String: Double] = [:]
    var exactMatched = false
    var historySharing = false
    var groups: [ResearchGroup] = []
    private(set) var metadata: [PaneID: PageMetadata] = [:]
    private(set) var labels: [PaneID: String] = [:]
    private(set) var labelEffect: JevLabelEffect?
    private(set) var grants: [PaneID: String] = [:]
    let history = BrowsingHistory()
    var enabled = UserDefaults.standard.bool(forKey: "jev.enabled")
    var automaticLabels = UserDefaults.standard.bool(forKey: "jev.labels")
    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private var service: JevService
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [String: RequestRevision] = [:]
    @ObservationIgnored private var resultDocument = ""
    @ObservationIgnored private var nextPanel: Panel?

    init(service: JevService = JevService()) {
        self.service = service
        refreshCredentialStatus()
    }
    var current: PageMetadata? { workspace?.activePane.flatMap { metadata[$0] } }
    var canShare: Bool { current?.publicWebPage == true }
    var shared: Bool { workspace?.activePane.map { grants[$0] == metadata[$0]?.document && grants[$0] != nil } ?? false }
    var origin: String { current?.origin ?? "" }
    private(set) var hasKey = false

    private func refreshCredentialStatus() {
        let key = "credentials", revision = token("credentials")
        tasks[key] = Task { [weak self] in
            // Even a noninteractive Keychain query can wait on another query's
            // authorization lock. Never let that block the browser's main thread.
            let exists = await Task.detached { JevCredential.exists() }.value
            guard let self, self.accepts(key, revision) else { return }
            self.hasKey = exists
        }
    }

    func label(_ pane: PaneID, url: String) -> String {
        if let value = labels[pane] { return value }
        let page = metadata[pane] ?? PageMetadata(document: "", url: url, title: "", heading: "", summary: "", breadcrumbs: [])
        return ContextLabels.candidates(page).first?.text ?? CompactLine.host(url)
    }

    private func cancel(_ key: String) {
        tasks.removeValue(forKey: key)?.cancel()
        _ = revisions[key, default: RequestRevision()].advance()
    }
    private func token(_ key: String) -> UUID { cancel(key); return revisions[key]!.value }
    private func accepts(_ key: String, _ token: UUID) -> Bool { revisions[key]?.accepts(token) == true && !Task.isCancelled }
    private func errorMessage(_ error: Error) -> String { (error as? JevError)?.errorDescription ?? JevError.unavailable.errorDescription! }
    private func requireReady() throws {
        guard enabled else { throw JevError.disabled }
        guard hasKey else { throw JevError.noKey }
    }

    func committed(_ pane: PaneID) {
        for key in ["metadata-\(pane.rawValue)", "label-\(pane.rawValue)"] { cancel(key) }
        metadata.removeValue(forKey: pane); labels.removeValue(forKey: pane); grants.removeValue(forKey: pane)
        if labelEffect?.pane == pane { labelEffect = nil }
        cancel("groups"); groups = []
        if workspace?.activePane == pane { closePanel() }
    }
    func loaded(_ pane: PaneID, view: WKWebView) {
        let key = "metadata-\(pane.rawValue)", revision = token("metadata-\(pane.rawValue)"), url = view.url
        tasks[key] = Task { [weak self, weak view] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self, let view else { return }
                let page = try await PageTextBridge.metadata(view)
                guard self.accepts(key, revision), view.url == url, self.workspace?.paneAlive(pane) == true,
                      page.url == view.url?.absoluteString else { return }
                if self.metadata[pane]?.document != page.document { self.grants.removeValue(forKey: pane) }
                self.metadata[pane] = page
                self.labels[pane] = ContextLabels.candidates(page).first?.text
                if self.enabled && self.automaticLabels && self.hasKey && page.publicWebPage {
                    self.grants[pane] = page.document
                    self.selectLabel(pane, page: page)
                }
            } catch { /* The address and normal browsing remain available. */ }
        }
    }
    func prune() {
        guard let workspace else { return }
        for pane in metadata.keys where !workspace.paneAlive(pane) { committed(pane) }
    }
    func changedTab() { closePanel(); historySharing = false; vaultStatus = "" }

    func configure() {
        UserDefaults.standard.set(enabled, forKey: "jev.enabled")
        UserDefaults.standard.set(automaticLabels, forKey: "jev.labels")
        for key in Array(tasks.keys) { cancel(key) }
        refreshCredentialStatus()
        grants.removeAll(); historySharing = false; busy = false
        matches = []; findings = []; groups = []
        labelEffect = nil
        labels = metadata.mapValues { ContextLabels.candidates($0).first?.text ?? $0.host }
        Task { await service.reset() }
        status = enabled ? "Share this page to use Jev." : JevError.disabled.errorDescription!
    }
    func clearHistory() {
        cancel("history"); history.clear(); historyResults = []; historySharing = false; historyStatus = "Vault cleared."
        Task { await service.reset() }
    }
    func forgetVisit(_ id: UUID) {
        cancel("history"); history.remove(id); historyResults.removeAll { $0.id == id }
        Task { await service.reset() }
    }

    func requestSharing(for destination: Panel? = nil) {
        workspace?.discardLine(); workspace?.setOverviewOpen(false)
        nextPanel = destination; panel = .permission
        status = ""
    }
    func allowPage() {
        do {
            try requireReady()
            guard let pane = workspace?.activePane, let page = metadata[pane], page.publicWebPage else {
                status = "This page is local, editable, or contains a password field. Page sharing is unavailable."; return
            }
            grants[pane] = page.document
            selectLabel(pane, page: page)
            panel = nextPanel
            if panel == .find { findChanged() }
            if panel == .reading { review() }
        } catch { status = errorMessage(error) }
    }
    func revokePage() {
        if let pane = workspace?.activePane { grants.removeValue(forKey: pane); cancel("label-\(pane.rawValue)") }
        cancel("find"); cancel("reading"); cancel("groups"); busy = false; matches = []; findings = []; groups = []
        Task { await service.reset() }
    }
    private func selectLabel(_ pane: PaneID, page: PageMetadata) {
        let candidates = ContextLabels.candidates(page)
        guard !candidates.isEmpty else { return }
        let key = "label-\(pane.rawValue)", revision = token("label-\(pane.rawValue)")
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.service.decide(ContextLabels.request(page, candidates: candidates))
                guard self.accepts(key, revision), self.grants[pane] == page.document,
                      self.metadata[pane]?.document == page.document else { return }
                if let label = ContextLabels.selected(response, candidates: candidates), label != self.labels[pane] {
                    self.labels[pane] = label
                    self.labelEffect = JevLabelEffect(pane: pane)
                }
                self.lastDecisionStatus = "Live Jev label decision received"
            } catch { if self.accepts(key, revision) { self.lastDecisionStatus = self.errorMessage(error) } }
        }
    }

    var savedInVault: Bool { current.map { page in history.visits.contains { $0.url == page.url } } ?? false }
    func saveToVault() {
        guard let pane = workspace?.activePane, let view = workspace?.hosts.existingBrowser(pane) else { return }
        let key = "vault", revision = token("vault"), url = view.url
        vaultStatus = "Saving page…"
        tasks[key] = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                let page = try await PageTextBridge.metadata(view)
                guard page.publicWebPage else { self.vaultStatus = "Local, editable, and password pages are not saved."; return }
                let extract = try await PageTextBridge.extract(view)
                guard self.accepts(key, revision), view.url == url, page.document == extract.document else { return }
                self.history.record(page, passages: extract.passages)
                self.history.save()
                self.vaultStatus = "Saved to Vault on this Mac"
            } catch { if self.accepts(key, revision) { self.vaultStatus = "Couldn't read this page. Try again after it loads." } }
        }
    }

    func openFind() {
        workspace?.discardLine(); workspace?.setOverviewOpen(false)
        panel = .find
        findChanged()
    }
    func closePanel() {
        cancel("find"); cancel("exact"); cancel("reading"); panel = nil; nextPanel = nil
        busy = false; matches = []; findings = []; status = ""
        if let pane = workspace?.activePane { PageTextBridge.clear(workspace?.hosts.existingBrowser(pane)) }
    }
    func findChanged() {
        cancel("find"); cancel("exact"); matches = []; findScores = [:]; matchIndex = 0; busy = false; exactMatched = false
        if let pane = workspace?.activePane { PageTextBridge.clear(workspace?.hosts.existingBrowser(pane)) }
        guard panel == .find else { return }
        if query.isEmpty { status = "Find in this page"; return }
        exactFind(backwards: false)
        guard byMeaning else { return }
        guard enabled, hasKey else { status = "Exact find is available. Enable Jev in Settings for meaning search."; return }
        guard let pane = workspace?.activePane, let page = metadata[pane], page.publicWebPage else {
            status = "Exact find only on local, editable, or password pages."; return
        }
        if !shared { grants[pane] = page.document; selectLabel(pane, page: page) }
        runPassages(reading: false)
    }
    func exactFind(backwards: Bool) {
        guard !query.isEmpty, let pane = workspace?.activePane, let view = workspace?.hosts.existingBrowser(pane) else { return }
        let key = "exact", revision = token(key), query = query
        let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true
        view.find(query, configuration: config) { [weak self, weak view] result in
            guard let self, self.accepts(key, revision), self.workspace?.activePane == pane, view != nil else { return }
            self.exactMatched = result.matchFound
            if !self.busy && self.matches.isEmpty { self.status = result.matchFound ? "Exact match" : "No exact match" }
        }
    }
    func moveMatch(_ step: Int) {
        if !byMeaning || matches.isEmpty { exactFind(backwards: step < 0); return }
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + step + matches.count) % matches.count
        show(matches[matchIndex])
    }
    func openReading() {
        closePanel()
        workspace?.discardLine(); workspace?.setOverviewOpen(false)
        panel = .reading; findings = []; status = "Check wording in the current page."
        review()
    }
    func review() {
        do { try requireReady() } catch { status = errorMessage(error); return }
        guard let pane = workspace?.activePane, let page = metadata[pane], page.publicWebPage else {
            status = "Reading checks are unavailable on local, editable, or password pages."; return
        }
        grants[pane] = page.document
        runPassages(reading: true)
    }
    private func runPassages(reading: Bool) {
        let key = reading ? "reading" : "find", revision = token(reading ? "reading" : "find")
        guard let pane = workspace?.activePane, let page = metadata[pane], let view = workspace?.hosts.existingBrowser(pane) else { return }
        let query = query
        busy = true; status = reading ? "Checking selected passages…" : "Finding related passages…"
        tasks[key] = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                try self.requireReady()
                try await Task.sleep(for: .milliseconds(400))
                let extract = try await PageTextBridge.extract(view)
                guard self.accepts(key, revision), extract.document == page.document, extract.url == view.url?.absoluteString else { return }
                let candidates = reading ? extract.passages.filter { $0.role == "passage" || $0.role == nil } : extract.passages
                guard !candidates.isEmpty else { self.busy = false; self.status = "No readable passages found. Exact find still works."; return }
                let request = reading ? PassageDecisions.readingRequest(candidates) : PassageDecisions.findRequest(query: query, passages: candidates)
                let response = try await self.service.decide(request)
                guard self.accepts(key, revision), self.workspace?.activePane == pane, self.grants[pane] == page.document,
                      view.url?.absoluteString == extract.url else { return }
                self.resultDocument = extract.document; self.busy = false
                self.lastDecisionStatus = "Jev decision received for " + (reading ? "reading" : "find")
                let coverage = "Checked \(candidates.count) passages" + (extract.truncated ? "; page coverage is limited." : ".")
                if reading {
                    self.findings = PassageDecisions.findings(response, passages: candidates)
                    self.status = (self.findings.isEmpty ? "No clear signals selected. " : "Possible wording signals. ") + coverage
                    let shown = await PageTextBridge.annotate(self.findings, document: extract.document, view: view)
                    if !self.accepts(key, revision) || self.panel != .reading { return }
                    if !shown { self.findings = []; self.status = "The page changed. Run the check again." }
                } else {
                    self.findScores = Dictionary(uniqueKeysWithValues: candidates.map { ($0.text, response.answers[$0.id]?.score ?? -1) })
                    self.matches = PassageDecisions.matches(response, passages: candidates)
                    self.status = self.matches.isEmpty ? "No clear meaning matches. \(coverage)" : "\(self.matches.count) possible matches. \(coverage)"
                    if let first = self.matches.first { self.show(first) }
                }
            } catch {
                guard self.accepts(key, revision) else { return }
                self.busy = false; self.status = self.errorMessage(error)
            }
        }
    }
    func show(_ passage: PagePassage) {
        guard let pane = workspace?.activePane, let view = workspace?.hosts.existingBrowser(pane) else { return }
        let document = resultDocument
        Task { [weak self, weak view] in
            guard let self, let view else { return }
            let passages = self.panel == .find && !self.matches.isEmpty ? self.matches : [passage]
            let found = await PageTextBridge.highlight(passages, current: passage.id, document: document, view: view)
            if !found, self.workspace?.activePane == pane, self.resultDocument == document {
                self.matches = []; self.findings = []; self.status = "The page changed. Run the search or check again."
            }
        }
    }

    func searchHistory(_ text: String, editing: Bool) {
        let key = "history", revision = token(key)
        historyResults = editing && text.count >= 2 ? history.exact(text) : []
        guard editing else { historySharing = false; historyStatus = ""; return }
        historyStatus = "Vault matches use saved text and metadata, not page images."
        guard historySharing, text.count >= 2, navigationURL(from: text) == nil else { return }
        let candidates = history.candidates(text)
        guard !candidates.isEmpty else { historyStatus = "Your Vault is empty. Save a page with the Vault button first."; return }
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try self.requireReady()
                try await Task.sleep(for: .milliseconds(500))
                let response = try await self.service.decide(BrowsingHistory.request(text, visits: candidates))
                guard self.accepts(key, revision), self.historySharing, self.workspace?.editing?.text == text else { return }
                let live = Set(self.history.visits.map(\.id))
                self.historyResults = BrowsingHistory.ranked(response, visits: candidates).filter { live.contains($0.id) }
                self.historyStatus = self.historyResults.isEmpty ? "No clear matches in the 24 saved candidates." : "Saved pages matching your description"
            } catch {
                guard self.accepts(key, revision) else { return }
                self.historyStatus = self.errorMessage(error)
            }
        }
    }
    func shareHistorySearch() {
        historySharing = true
        if let text = workspace?.editing?.text { searchHistory(text, editing: true) }
    }
    func related() {
        guard let workspace else { return }
        let pages = workspace.tabs.prefix(8).compactMap { tab -> ResearchPage? in
            guard let page = metadata[tab.active] else { return nil }
            return ResearchPage(id: String(tab.id.rawValue), title: page.title.isEmpty ? page.host : page.title, detail: page.summary, host: page.host)
        }
        groups = ResearchRelations.groups(pages)
        let allowed = pages.filter { page in workspace.tabs.first { String($0.id.rawValue) == page.id }.map { grants[$0.active] == metadata[$0.active]?.document && grants[$0.active] != nil } ?? false }
        guard enabled, hasKey, allowed.count >= 2 else { return }
        let key = "groups", revision = token(key)
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let response = try await self.service.decide(ResearchRelations.request(allowed))
                guard self.accepts(key, revision), workspace.overviewOpen else { return }
                self.groups = ResearchRelations.groups(allowed, response: response)
            } catch { /* Local groups remain stable. */ }
        }
    }
}
