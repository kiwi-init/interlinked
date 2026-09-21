import AppKit
import Observation

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
    var readingPanelOpen = false
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
    var findScores: [String: Double] = [:]
    var exactMatched = false
    var groups: [ResearchGroup] = []
    private(set) var metadata: [PaneID: PageMetadata] = [:]
    private(set) var labels: [PaneID: String] = [:]
    private(set) var portraits: [PaneID: PagePortrait] = [:]
    private(set) var labelEffect: AILabelEffect?
    private(set) var grants: [PaneID: String] = [:]
    let history = BrowsingHistory()
    var enabled = JevPreferences.enabled()
    var automaticLabels = UserDefaults.standard.object(forKey: "jev.labels") as? Bool ?? true
    var criticalReadingMode = CriticalReadingMode()
    var automaticReadingConsented = AutomaticReadingConsent.accepted()
    let originGrants = AIContentGrantStore()
    @ObservationIgnored private var declinedOrigins: Set<String> = []
    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private var intelligence: BrowserIntelligence
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [String: RequestRevision] = [:]
    @ObservationIgnored private var resultDocument = ""
    @ObservationIgnored private var nextPanel: Panel?
    @ObservationIgnored private var readingResults: [PaneID: ReadingResult] = [:]
    @ObservationIgnored private var readingInFlight: [PaneID: String] = [:]

    init(intelligence: BrowserIntelligence? = nil) {
        self.intelligence = intelligence ?? BrowserIntelligence(audit: IntelligenceAuditStore.shared)
        refreshCredentialStatus()
    }
    var current: PageMetadata? { workspace?.activePane.flatMap { metadata[$0] } }
    var canShare: Bool { current?.publicWebPage == true }
    var automaticReadingEnabled: Bool {
        criticalReadingMode == .automatic && automaticReadingConsented
    }
    var shared: Bool { workspace?.activePane.map { grants[$0] == metadata[$0]?.document && grants[$0] != nil } ?? false }
    var origin: String { current?.origin ?? "" }
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
        return PageLabels.fallback(page)
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
        let wasActive = workspace?.activePane == pane
        for key in ["metadata-\(pane.rawValue)", "label-\(pane.rawValue)"] { cancel(key) }
        metadata.removeValue(forKey: pane); labels.removeValue(forKey: pane); portraits.removeValue(forKey: pane); grants.removeValue(forKey: pane)
        readingResults.removeValue(forKey: pane); readingInFlight.removeValue(forKey: pane)
        if labelEffect?.pane == pane { labelEffect = nil }
        cancel("groups"); groups = []
        if wasActive {
            closePanel()
        }
    }
    func loaded(_ pane: PaneID, page view: ChromiumPage) {
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
                self.labels[pane] = PageLabels.fallback(page)
                if page.publicWebPage {
                    self.describePage(pane, page: page)
                }
                self.startAutomaticReading(pane: pane, page: page, view: view)
            } catch { /* The address and normal browsing remain available. */ }
        }
    }
    func prune() {
        guard let workspace else { return }
        for pane in metadata.keys where !workspace.paneAlive(pane) { committed(pane) }
    }
    func changedTab() {
        if automaticReadingEnabled, panel == .reading {
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
        guard automaticReadingEnabled else {
            PageTextBridge.clear(view)
            readingResults.removeValue(forKey: pane)
            return
        }
        guard let page = metadata[pane] else { return }
        startAutomaticReading(pane: pane, page: page, view: view)
    }

    func shouldReplaceSiteMenu(host: String, labels: String) async -> Bool? {
        await intelligence.shouldReplaceSiteMenu(host: host, labels: labels)
    }

    func configure() {
        UserDefaults.standard.set(enabled, forKey: JevPreferences.enabledKey)
        UserDefaults.standard.set(automaticLabels, forKey: "jev.labels")
        if automaticReadingConsented { AutomaticReadingConsent.accept() }
        else { AutomaticReadingConsent.reset() }
        if criticalReadingMode == .automatic && !automaticReadingConsented {
            criticalReadingMode = .onRequest
        }
        criticalReadingMode.save()
        for key in Array(tasks.keys) { cancel(key) }
        readingInFlight.removeAll()
        if !enabled || !automaticReadingEnabled {
            readingResults.removeAll()
            if panel == .reading { closePanel() }
            else if let pane = workspace?.activePane { PageTextBridge.clear(workspace?.hosts.existingBrowser(pane)) }
        }
        refreshCredentialStatus()
        grants.removeAll(); busy = false
        matches = []; findings = []; groups = []
        labelEffect = nil
        labels = Dictionary(uniqueKeysWithValues: metadata.map { pane, page in
            (pane, (automaticLabels ? portraits[pane]?.label : nil) ?? PageLabels.fallback(page))
        })
        Task { await intelligence.reset() }
        status = enabled ? "Share this page to use Jev." : JevError.disabled.errorDescription!
    }
    func clearHistory() {
        cancel("history"); history.clear(); historyResults = []; historyStatus = "Vault cleared."
    }
    func forgetVisit(_ id: UUID) {
        cancel("history"); history.remove(id); historyResults.removeAll { $0.id == id }
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
    func allowPage(remember: Bool = false) {
        do {
            try requireReady()
            guard let pane = workspace?.activePane, let page = metadata[pane], page.publicWebPage else {
                status = "This page is local, signed-in, editable, or contains a password field. Page sharing is unavailable."; return
            }
            declinedOrigins.remove(page.origin)
            originGrants.grant(page.origin, remember: remember)
            grants[pane] = page.document
            describePage(pane, page: page)
            panel = nextPanel
            if panel == .find { findChanged() }
            if panel == .reading { review() }
            if panel == nil, automaticReadingEnabled {
                if let view = workspace?.hosts.existingBrowser(pane) {
                    startAutomaticReading(pane: pane, page: page, view: view)
                }
            }
        } catch { status = errorMessage(error) }
    }
    func acceptAutomaticReading() {
        automaticReadingConsented = true
        criticalReadingMode = .automatic
        configure()
    }
    func revokePage() {
        if let pane = workspace?.activePane {
            if let origin = metadata[pane]?.origin {
                originGrants.revoke(origin)
                declinedOrigins.insert(origin)
            }
            grants.removeValue(forKey: pane)
            readingInFlight.removeValue(forKey: pane)
            cancel("label-\(pane.rawValue)")
        }
        cancel("find"); cancel("reading"); cancel("groups"); busy = false; matches = []; findings = []; groups = []
    }
    private func describePage(_ pane: PaneID, page: PageMetadata) {
        let key = "label-\(pane.rawValue)", revision = token("label-\(pane.rawValue)")
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let decision = try await self.intelligence.describePage(page: page)
                guard self.accepts(key, revision), self.metadata[pane]?.document == page.document,
                      let decision else { return }
                self.portraits[pane] = decision.value
                if self.automaticLabels, decision.value.label != self.labels[pane] {
                    self.labels[pane] = decision.value.label
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
            guard let self else { return }
            defer {
                if self.accepts(key, revision), self.vaultStatus == "Saving page…" {
                    self.vaultStatus = "The page changed before it could be saved."
                }
            }
            guard let view else { return }
            do {
                let page = try await PageTextBridge.metadata(view)
                guard self.accepts(key, revision), view.url == url else { return }
                guard page.publicWebPage else { self.vaultStatus = "Local, signed-in, editable, and password pages are not saved."; return }
                let extract = try await PageTextBridge.extract(view)
                guard self.accepts(key, revision), view.url == url, page.document == extract.document else { return }
                self.history.record(page, passages: extract.passages)
                self.history.save()
                self.vaultStatus = "Saved to Vault on this Mac"
            } catch { if self.accepts(key, revision) { self.vaultStatus = "Couldn't read this page. Try again after it loads." } }
        }
    }

    func openFind() {
        readingPanelOpen = false
        workspace?.discardLine(); workspace?.setOverviewOpen(false)
        panel = .find
        findChanged()
    }
    func closePanel() {
        if panel == .permission, let origin = current?.origin, !origin.isEmpty {
            declinedOrigins.insert(origin)
        }
        let wasFinding = panel == .find
        cancel("find"); cancel("exact"); cancel("reading"); panel = nil; nextPanel = nil
        readingPanelOpen = false
        if let pane = workspace?.activePane { readingInFlight.removeValue(forKey: pane) }
        busy = false; matches = []; findings = []; status = ""
        if let pane = workspace?.activePane, let view = workspace?.hosts.existingBrowser(pane) {
            if wasFinding { view.stopFinding() }
            PageTextBridge.clear(view)
        }
    }

    func findChanged() {
        cancel("find"); cancel("exact"); matches = []; findScores = [:]; matchIndex = 0; busy = false; exactMatched = false
        if let pane = workspace?.activePane, let view = workspace?.hosts.existingBrowser(pane) {
            view.stopFinding()
            PageTextBridge.clear(view)
        }
        guard panel == .find else { return }
        if query.isEmpty { status = "Find in this page"; return }
        exactFind(backwards: false)
        guard byMeaning else { return }
        guard enabled, hasJevAccess else { status = "Exact find is available. Enable Jev in Settings for meaning search."; return }
        guard let pane = workspace?.activePane, let page = metadata[pane], page.publicWebPage else {
            status = "Exact find only on local, signed-in, editable, or password pages."; return
        }
        if !shared { grants[pane] = page.document }
        runPassages(reading: false)
    }
    func exactFind(backwards: Bool) {
        guard !query.isEmpty, let pane = workspace?.activePane, let view = workspace?.hosts.existingBrowser(pane) else { return }
        let key = "exact", revision = token(key), query = query
        view.find(query, backwards: backwards) { [weak self, weak view] found in
            guard let self, self.accepts(key, revision), self.workspace?.activePane == pane, view != nil else { return }
            self.exactMatched = found
            if !self.busy && self.matches.isEmpty { self.status = found ? "Exact match" : "No exact match" }
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
        panel = .reading; readingPanelOpen = true; findings = []; status = "Check wording in the current page."
        review()
    }
    func review() {
        do { try requireReady() } catch { status = errorMessage(error); return }
        guard let pane = workspace?.activePane, let page = metadata[pane], page.publicWebPage else {
            status = "Reading checks are unavailable on local, signed-in, editable, or password pages."; return
        }
        grants[pane] = page.document
        runPassages(reading: true)
    }
    private func automaticReadingForCurrentPage() {
        guard let pane = workspace?.activePane, let page = metadata[pane],
              let view = workspace?.hosts.existingBrowser(pane) else { return }
        startAutomaticReading(pane: pane, page: page, view: view)
    }
    private func startAutomaticReading(pane: PaneID, page: PageMetadata, view: ChromiumPage) {
        guard enabled, hasJevAccess, automaticReadingEnabled, page.publicWebPage,
              workspace?.activePane == pane, workspace?.hosts.existingBrowser(pane) === view,
              panel == nil || panel == .reading || panel == .permission else { return }
        guard originGrants.allows(page.origin) else {
            if panel == nil, !declinedOrigins.contains(page.origin) {
                requestSharing(for: .reading)
            }
            return
        }
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
        guard let pane = workspace?.activePane else {
            busy = false
            if reading { readingInFlight.removeAll() }
            return
        }
        guard let page = metadata[pane], let view = workspace?.hosts.existingBrowser(pane) else {
            busy = false
            if reading { readingInFlight.removeValue(forKey: pane) }
            status = "The page changed. Run the search or check again."
            return
        }
        let query = query
        if reading { readingInFlight[pane] = page.document }
        busy = true; status = reading ? "Checking selected passages…" : "Finding related passages…"
        tasks[key] = Task { [weak self, weak view] in
            guard let self else { return }
            defer {
                if self.accepts(key, revision) {
                    self.busy = false
                    if reading { self.readingInFlight.removeValue(forKey: pane) }
                }
            }
            guard let view else {
                if self.accepts(key, revision) { self.status = "The page changed. Run the search or check again." }
                return
            }
            do {
                try self.requireReady()
                try await Task.sleep(for: .milliseconds(400))
                let extract = try await PageTextBridge.extract(view)
                guard self.accepts(key, revision) else { return }
                guard extract.document == page.document, extract.url == view.url?.absoluteString else {
                    self.status = "The page changed. Run the search or check again."
                    return
                }
                let candidates = reading
                    ? PassageDecisions.readingCandidates(extract.passages)
                    : PassageDecisions.candidates(query: query, passages: extract.passages)
                guard !candidates.isEmpty else {
                    self.status = "No readable passages found. Exact find still works."
                    if reading {
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
                        guard self.accepts(key, revision) else { return }
                        guard self.workspace?.activePane == pane, self.grants[pane] == page.document,
                              view.url?.absoluteString == extract.url else {
                            self.status = "The page changed. Run the search or check again."
                            return
                        }
                        readingFindings.append(contentsOf: partial.value)
                    }
                } else {
                    meaningDecision = try await self.intelligence.meaningFind(query: query, passages: candidates).value
                }
                guard self.accepts(key, revision) else { return }
                guard self.workspace?.activePane == pane, self.grants[pane] == page.document,
                      view.url?.absoluteString == extract.url else {
                    self.status = "The page changed. Run the search or check again."
                    return
                }
                self.resultDocument = extract.document
                self.lastDecisionStatus = "Jev decision received for " + (reading ? "reading" : "find")
                let limited = extract.truncated || candidates.count < extract.passages.count
                let coverage = "Checked \(candidates.count) passages" + (limited ? "; page coverage is limited." : ".")
                if reading {
                    self.findings = readingFindings
                    self.status = (self.findings.isEmpty ? "No clear signals selected. " : "Possible wording signals. ") + coverage
                    let shown = await PageTextBridge.annotate(self.findings, document: extract.document, view: view)
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
                self.status = self.errorMessage(error)
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
                var decision: IntelligenceDecision<[HistoryVisit]>?
                if self.enabled, self.hasJevAccess {
                    decision = try await self.intelligence.vaultMatches(query: query, visits: candidates)
                }
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
            return ResearchPage(
                id: String(tab.id.rawValue),
                title: page.title.isEmpty ? page.host : page.title,
                detail: page.summary,
                host: page.host,
                about: portraits[tab.active]?.about ?? ""
            )
        }
        groups = ResearchRelations.groups(pages)
        guard pages.count >= 2, enabled, hasJevAccess else { return }
        let key = "groups", revision = token(key)
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let decision = try await self.intelligence.relatedPageGroups(pages: pages)
                guard self.accepts(key, revision), workspace.overviewOpen else { return }
                if let decision {
                    self.groups = ResearchRelations.merge(
                        remote: decision.value,
                        fallback: ResearchRelations.groups(pages),
                        pages: pages
                    )
                    self.lastDecisionStatus = "\(decision.source.rawValue) decision received for related pages"
                }
            } catch { /* Local groups remain stable. */ }
        }
    }
}
