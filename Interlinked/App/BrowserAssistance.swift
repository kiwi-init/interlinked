import AppKit
import Observation
import WebKit

struct AILabelEffect: Equatable {
    var id = UUID()
    var pane: PaneID
}

@MainActor @Observable
final class BrowserAssistance {
    enum Panel { case find, reading, permission }
    private struct ReadingResult {
        var document: String
        var findings: [PassageDecisions.Finding]
        var status: String
    }

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
    var cacheStatus = ""
    var lastDecisionStatus = ""
    var filterPanelOpen = false
    var filterDraft = ""
    var filterStatus = ""
    var filterBusy = false
    var findScores: [String: Double] = [:]
    var exactMatched = false
    var groups: [ResearchGroup] = []
    private(set) var metadata: [PaneID: PageMetadata] = [:]
    private(set) var labels: [PaneID: String] = [:]
    private(set) var labelEffect: AILabelEffect?
    private(set) var grants: [PaneID: String] = [:]
    let history = BrowsingHistory()
    let personalFilters = PersonalFilters()
    var enabled = JevPreferences.enabled()
    var automaticLabels = UserDefaults.standard.bool(forKey: "jev.labels")
    var criticalReadingMode = CriticalReadingMode()
    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private var intelligence: BrowserIntelligence
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [String: RequestRevision] = [:]
    @ObservationIgnored private var resultDocument = ""
    @ObservationIgnored private var nextPanel: Panel?
    @ObservationIgnored private var readingResults: [PaneID: ReadingResult] = [:]
    @ObservationIgnored private var readingInFlight: [PaneID: String] = [:]
    @ObservationIgnored private var filterResults: [PaneID: [UUID: Int]] = [:]

    init(intelligence: BrowserIntelligence = BrowserIntelligence()) {
        self.intelligence = intelligence
        refreshCredentialStatus()
    }
    var current: PageMetadata? { workspace?.activePane.flatMap { metadata[$0] } }
    var canShare: Bool { current?.publicWebPage == true }
    var shared: Bool { workspace?.activePane.map { grants[$0] == metadata[$0]?.document && grants[$0] != nil } ?? false }
    var origin: String { current?.origin ?? "" }
    var currentFilterHost: String { PersonalFilters.site(current?.host ?? "") }
    var currentFilters: [PersonalFilterRule] { personalFilters.rules(for: currentFilterHost) }
    var appliedFilterCount: Int {
        guard let pane = workspace?.activePane else { return 0 }
        return filterResults[pane]?.values.reduce(0, +) ?? 0
    }
    func filterCount(_ id: UUID) -> Int {
        guard let pane = workspace?.activePane else { return 0 }
        return filterResults[pane]?[id] ?? 0
    }
    private(set) var hasKey = false
    var usesIncludedJev: Bool { JevRuntime.includesJev }
    var hasJevAccess: Bool { usesIncludedJev || hasKey }

    private func refreshCredentialStatus() {
        if usesIncludedJev {
            hasKey = false
            automaticReadingForCurrentPage()
            return
        }
        let key = "credentials", revision = token("credentials")
        tasks[key] = Task { [weak self] in
            // Even a noninteractive Keychain query can wait on another query's
            // authorization lock. Never let that block the browser's main thread.
            let exists = await Task.detached { JevCredential.exists() }.value
            guard let self, self.accepts(key, revision) else { return }
            self.hasKey = exists
            if exists { self.automaticReadingForCurrentPage() }
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
        guard hasJevAccess else { throw JevError.noKey }
    }

    func committed(_ pane: PaneID) {
        for key in ["metadata-\(pane.rawValue)", "label-\(pane.rawValue)", "filters-\(pane.rawValue)"] { cancel(key) }
        metadata.removeValue(forKey: pane); labels.removeValue(forKey: pane); grants.removeValue(forKey: pane)
        readingResults.removeValue(forKey: pane); readingInFlight.removeValue(forKey: pane)
        filterResults.removeValue(forKey: pane)
        if labelEffect?.pane == pane { labelEffect = nil }
        cancel("groups"); groups = []
        if workspace?.activePane == pane { closePanel(); closeFilters() }
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
                if self.automaticLabels && page.publicWebPage {
                    self.selectLabel(pane, page: page)
                }
                self.applyPersonalFilters(pane: pane, page: page, view: view)
                self.startAutomaticReading(pane: pane, page: page, view: view)
            } catch { /* The address and normal browsing remain available. */ }
        }
    }
    func prune() {
        guard let workspace else { return }
        for pane in metadata.keys where !workspace.paneAlive(pane) { committed(pane) }
    }
    func changedTab() {
        filterPanelOpen = false; filterBusy = false; filterStatus = ""
        for key in Array(tasks.keys) where key.hasPrefix("filters-") { cancel(key) }
        if criticalReadingMode == .automatic, panel == .reading {
            cancel("reading")
            if let pane = workspace?.activePane { readingInFlight.removeValue(forKey: pane) }
            panel = nil; nextPanel = nil; busy = false; findings = []; status = ""
        } else {
            closePanel()
        }
        vaultStatus = ""
    }

    func activated(_ pane: PaneID) {
        guard let view = workspace?.hosts.existingBrowser(pane) else { return }
        if let page = metadata[pane] { applyPersonalFilters(pane: pane, page: page, view: view) }
        guard criticalReadingMode == .automatic else {
            PageTextBridge.clear(view)
            readingResults.removeValue(forKey: pane)
            return
        }
        guard let page = metadata[pane] else { return }
        startAutomaticReading(pane: pane, page: page, view: view)
    }

    func configure() {
        UserDefaults.standard.set(enabled, forKey: JevPreferences.enabledKey)
        UserDefaults.standard.set(automaticLabels, forKey: "jev.labels")
        criticalReadingMode.save()
        for key in Array(tasks.keys) { cancel(key) }
        readingInFlight.removeAll()
        if !enabled || criticalReadingMode == .onRequest {
            readingResults.removeAll()
            if panel == .reading { closePanel() }
            else if let pane = workspace?.activePane { PageTextBridge.clear(workspace?.hosts.existingBrowser(pane)) }
        }
        refreshCredentialStatus()
        grants.removeAll(); busy = false
        matches = []; findings = []; groups = []
        labelEffect = nil
        labels = metadata.mapValues { ContextLabels.candidates($0).first?.text ?? $0.host }
        Task { await intelligence.reset() }
        status = enabled ? "Share this page to use Jev." : JevError.disabled.errorDescription!
        if let pane = workspace?.activePane, let page = metadata[pane], let view = workspace?.hosts.existingBrowser(pane) {
            applyPersonalFilters(pane: pane, page: page, view: view)
        }
    }
    func clearHistory() {
        cancel("history"); history.clear(); historyResults = []; historyStatus = "Vault cleared."
        Task { await intelligence.reset() }
    }
    func forgetVisit(_ id: UUID) {
        cancel("history"); history.remove(id); historyResults.removeAll { $0.id == id }
        Task { await intelligence.reset() }
    }
    func clearDecisionCache() {
        cacheStatus = "Clearing…"
        Task { [weak self] in
            guard let self else { return }
            await self.intelligence.clearCache()
            self.cacheStatus = "AI cache cleared."
        }
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
        Task { await intelligence.reset() }
    }
    private func selectLabel(_ pane: PaneID, page: PageMetadata) {
        let candidates = ContextLabels.candidates(page)
        guard !candidates.isEmpty else { return }
        let allowJev = enabled && hasJevAccess && (automaticLabels || grants[pane] == page.document)
        let key = "label-\(pane.rawValue)", revision = token("label-\(pane.rawValue)")
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let decision = try await self.intelligence.refinePageLabel(
                    page: page, candidates: candidates, allowJev: allowJev)
                guard self.accepts(key, revision), self.metadata[pane]?.document == page.document,
                      let decision else { return }
                if decision.source == .jev { self.grants[pane] = page.document }
                if decision.value != self.labels[pane] {
                    self.labels[pane] = decision.value
                    self.labelEffect = AILabelEffect(pane: pane)
                }
                self.lastDecisionStatus = "\(decision.source.rawValue) label decision received"
            } catch { if self.accepts(key, revision) { self.lastDecisionStatus = self.errorMessage(error) } }
        }
    }

    func navigationAdvice(_ review: NavigationReview) async -> String? {
        await intelligence.navigationAdvice(review)
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
        closeFilters()
        workspace?.discardLine(); workspace?.setOverviewOpen(false)
        panel = .find
        findChanged()
    }
    func closePanel() {
        cancel("find"); cancel("exact"); cancel("reading"); panel = nil; nextPanel = nil
        if let pane = workspace?.activePane { readingInFlight.removeValue(forKey: pane) }
        busy = false; matches = []; findings = []; status = ""
        if let pane = workspace?.activePane { PageTextBridge.clear(workspace?.hosts.existingBrowser(pane)) }
    }

    func openFilters() {
        workspace?.discardLine(); workspace?.setOverviewOpen(false)
        if panel != nil { closePanel() }
        filterPanelOpen = true
        filterStatus = appliedFilterCount > 0 ? hiddenFilterSummary : "Filters run only on \(currentFilterHost)."
    }

    func closeFilters() {
        filterPanelOpen = false; filterDraft = ""; filterStatus = ""
    }

    func addPersonalFilter() {
        guard let pane = workspace?.activePane, let page = metadata[pane], page.publicWebPage,
              let view = workspace?.hosts.existingBrowser(pane),
              personalFilters.add(filterDraft, host: page.host) != nil else {
            filterStatus = currentFilterHost.isEmpty ? "Open a public website first." : "Describe what you want to hide."
            return
        }
        filterDraft = ""
        applyPersonalFilters(pane: pane, page: page, view: view)
    }

    func togglePersonalFilter(_ id: UUID) {
        personalFilters.toggle(id); reapplyPersonalFilters()
    }

    func removePersonalFilter(_ id: UUID) {
        personalFilters.remove(id); reapplyPersonalFilters()
    }

    private var hiddenFilterSummary: String {
        let count = appliedFilterCount
        return count == 1 ? "1 page item hidden on \(currentFilterHost)." : "\(count) page items hidden on \(currentFilterHost)."
    }

    private func reapplyPersonalFilters() {
        guard let pane = workspace?.activePane, let page = metadata[pane],
              let view = workspace?.hosts.existingBrowser(pane) else { return }
        applyPersonalFilters(pane: pane, page: page, view: view)
    }

    private func applyPersonalFilters(pane: PaneID, page: PageMetadata, view: WKWebView) {
        let rules = personalFilters.rules(for: page.host).filter(\.isEnabled)
        let key = "filters-\(pane.rawValue)", revision = token(key)
        if workspace?.activePane == pane { filterBusy = !rules.isEmpty }
        tasks[key] = Task { [weak self, weak view] in
            guard let self, let view else { return }
            await PageTextBridge.clearFilters(view)
            guard self.accepts(key, revision), self.metadata[pane]?.document == page.document else { return }
            guard page.publicWebPage, !rules.isEmpty else {
                self.filterResults[pane] = [:]
                if self.workspace?.activePane == pane {
                    self.filterBusy = false
                    self.filterStatus = rules.isEmpty ? "No filters on this site." : "Filters are unavailable on this page."
                }
                return
            }
            do {
                let extract = try await PageTextBridge.extractFilterCandidates(view)
                guard self.accepts(key, revision), extract.document == page.document,
                      extract.url == view.url?.absoluteString else { return }
                var selected: [UUID: [PageFilterCandidate]] = [:]
                var usedJev = false
                for rule in rules {
                    var matches = PersonalFilterDecisions.localMatches(description: rule.description,
                                                                       candidates: extract.candidates)
                    if matches.isEmpty, self.enabled, self.hasJevAccess {
                        for candidates in PersonalFilterDecisions.batches(extract.candidates) {
                            let decision = try await self.intelligence.personalFilterMatches(
                                description: rule.description, candidates: candidates)
                            try Task.checkCancellation()
                            matches.append(contentsOf: decision.value)
                            usedJev = true
                        }
                    }
                    selected[rule.id] = matches
                }
                guard self.accepts(key, revision), self.metadata[pane]?.document == page.document,
                      view.url?.absoluteString == extract.url else { return }
                let counts = await PageTextBridge.applyFilterCandidates(selected, document: extract.document, view: view)
                guard self.accepts(key, revision), let counts else { return }
                self.filterResults[pane] = counts
                if usedJev { self.grants[pane] = page.document; self.lastDecisionStatus = "Jev decision received for Personal Filters" }
                if self.workspace?.activePane == pane {
                    self.filterBusy = false
                    let result = self.appliedFilterCount > 0 ? self.hiddenFilterSummary : "No matching page content found."
                    self.filterStatus = extract.truncated ? result + " This page exceeded the safe scan limit." : result
                }
            } catch {
                guard self.accepts(key, revision) else { return }
                self.filterResults[pane] = [:]
                if self.workspace?.activePane == pane {
                    self.filterBusy = false; self.filterStatus = self.errorMessage(error)
                }
            }
        }
    }
    func findChanged() {
        cancel("find"); cancel("exact"); matches = []; findScores = [:]; matchIndex = 0; busy = false; exactMatched = false
        if let pane = workspace?.activePane { PageTextBridge.clear(workspace?.hosts.existingBrowser(pane)) }
        guard panel == .find else { return }
        if query.isEmpty { status = "Find in this page"; return }
        exactFind(backwards: false)
        guard byMeaning else { return }
        guard enabled, hasJevAccess else { status = "Exact find is available. Enable Jev in Settings for meaning search."; return }
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
    private func automaticReadingForCurrentPage() {
        guard let pane = workspace?.activePane, let page = metadata[pane],
              let view = workspace?.hosts.existingBrowser(pane) else { return }
        startAutomaticReading(pane: pane, page: page, view: view)
    }
    private func startAutomaticReading(pane: PaneID, page: PageMetadata, view: WKWebView) {
        guard enabled, hasJevAccess, criticalReadingMode == .automatic, page.publicWebPage,
              workspace?.activePane == pane, workspace?.hosts.existingBrowser(pane) === view,
              panel == nil || panel == .reading else { return }
        if let result = readingResults[pane], result.document == page.document {
            panel = .reading; busy = false; findings = result.findings; status = result.status
            grants[pane] = page.document
            Task { [weak self, weak view] in
                guard let self, let view else { return }
                let shown = await PageTextBridge.annotate(result.findings, document: result.document, view: view)
                if !shown, self.workspace?.activePane == pane { self.readingResults.removeValue(forKey: pane) }
            }
            return
        }
        guard readingInFlight[pane] != page.document else { return }
        panel = .reading; findings = []; status = "Checking wording in this page."
        grants[pane] = page.document
        runPassages(reading: true)
    }
    private func runPassages(reading: Bool) {
        let key = reading ? "reading" : "find", revision = token(reading ? "reading" : "find")
        guard let pane = workspace?.activePane, let page = metadata[pane], let view = workspace?.hosts.existingBrowser(pane) else { return }
        let query = query
        if reading { readingInFlight[pane] = page.document }
        busy = true; status = reading ? "Checking selected passages…" : "Finding related passages…"
        tasks[key] = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                try self.requireReady()
                try await Task.sleep(for: .milliseconds(400))
                let extract = try await PageTextBridge.extract(view)
                guard self.accepts(key, revision), extract.document == page.document, extract.url == view.url?.absoluteString else { return }
                let candidates = reading ? PassageDecisions.readingCandidates(extract.passages) : extract.passages
                guard !candidates.isEmpty else {
                    self.busy = false; self.status = "No readable passages found. Exact find still works."
                    if reading {
                        self.readingInFlight.removeValue(forKey: pane)
                        self.readingResults[pane] = ReadingResult(document: page.document, findings: [], status: self.status)
                    }
                    return
                }
                var readingFindings: [PassageDecisions.Finding] = []
                var meaningDecision: MeaningDecision?
                if reading {
                    let batches = PassageDecisions.readingBatches(candidates)
                    for (index, batch) in batches.enumerated() {
                        self.status = batches.count == 1
                            ? "Checking selected passages…"
                            : "Checking passage batch \(index + 1) of \(batches.count)…"
                        let partial = try await self.intelligence.criticalReading(batch)
                        try Task.checkCancellation()
                        guard self.accepts(key, revision), self.workspace?.activePane == pane,
                              self.grants[pane] == page.document, view.url?.absoluteString == extract.url else { return }
                        readingFindings.append(contentsOf: partial.value)
                    }
                } else {
                    meaningDecision = try await self.intelligence.meaningFind(query: query, passages: candidates).value
                }
                guard self.accepts(key, revision), self.workspace?.activePane == pane, self.grants[pane] == page.document,
                      view.url?.absoluteString == extract.url else { return }
                self.resultDocument = extract.document; self.busy = false
                self.lastDecisionStatus = "Jev decision received for " + (reading ? "reading" : "find")
                let coverage = "Checked \(candidates.count) passages" + (extract.truncated ? "; page coverage is limited." : ".")
                if reading {
                    self.findings = readingFindings
                    self.status = (self.findings.isEmpty ? "No clear signals selected. " : "Possible wording signals. ") + coverage
                    let shown = await PageTextBridge.annotate(self.findings, document: extract.document, view: view)
                    self.readingInFlight.removeValue(forKey: pane)
                    if !self.accepts(key, revision) || self.panel != .reading { return }
                    if shown {
                        self.readingResults[pane] = ReadingResult(document: extract.document, findings: self.findings, status: self.status)
                    } else {
                        self.findings = []; self.status = "The page changed. Run the check again."
                        self.readingResults.removeValue(forKey: pane)
                    }
                } else {
                    self.findScores = meaningDecision?.scores ?? [:]
                    self.matches = meaningDecision?.matches ?? []
                    self.status = self.matches.isEmpty ? "No clear meaning matches. \(coverage)" : "\(self.matches.count) possible matches. \(coverage)"
                    if let first = self.matches.first { self.show(first) }
                }
            } catch {
                guard self.accepts(key, revision) else { return }
                if reading { self.readingInFlight.removeValue(forKey: pane) }
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
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let eligible = editing && query.count >= 2 && navigationURL(from: query) == nil
        historyResults = eligible ? history.exact(query) : []
        guard eligible else { historyStatus = ""; return }
        historyStatus = "Vault matches use saved text and metadata, not page images."
        let candidates = history.candidates(query)
        guard !candidates.isEmpty else { historyStatus = "Your Vault is empty. Save a page with the Vault button first."; return }
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
                let decision = try await self.intelligence.vaultMatches(
                    query: query, visits: candidates, allowJev: self.enabled && self.hasJevAccess)
                guard self.accepts(key, revision), self.workspace?.editing?.text == text else { return }
                let live = Set(self.history.visits.map(\.id))
                if let decision {
                    self.historyResults = decision.value.filter { live.contains($0.id) }
                    self.lastDecisionStatus = "\(decision.source.rawValue) decision received for Vault"
                }
                self.historyStatus = self.historyResults.isEmpty ? "No clear matches in saved pages." : "Saved pages matching your description"
            } catch {
                guard self.accepts(key, revision) else { return }
                self.historyStatus = self.errorMessage(error)
            }
        }
    }
    func related() {
        guard let workspace else { return }
        let pages = workspace.tabs.prefix(8).compactMap { tab -> ResearchPage? in
            guard let page = metadata[tab.active] else { return nil }
            return ResearchPage(id: String(tab.id.rawValue), title: page.title.isEmpty ? page.host : page.title, detail: page.summary, host: page.host)
        }
        groups = ResearchRelations.groups(pages)
        guard pages.count >= 2 else { return }
        let allowed = pages.filter { page in workspace.tabs.first { String($0.id.rawValue) == page.id }.map { grants[$0.active] == metadata[$0.active]?.document && grants[$0.active] != nil } ?? false }
        let key = "groups", revision = token(key)
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let decision = try await self.intelligence.relatedPageGroups(
                    pages: pages,
                    jevPages: allowed,
                    allowJev: self.enabled && self.hasJevAccess && allowed.count >= 2)
                guard self.accepts(key, revision), workspace.overviewOpen else { return }
                if let decision {
                    self.groups = decision.value
                    self.lastDecisionStatus = "\(decision.source.rawValue) decision received for related pages"
                }
            } catch { /* Local groups remain stable. */ }
        }
    }
}
