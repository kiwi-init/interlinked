import AppKit
import Observation

struct AILabelEffect: Equatable {
    var id = UUID()
    var pane: PaneID
}

@MainActor @Observable
final class BrowserAssistance {
    enum Panel { case find, permission }

    var panel: Panel?
    var query = ""
    var byMeaning = true
    var status = ""
    var busy = false
    var matches: [PagePassage] = []
    var matchIndex = 0
    var cacheStatus = ""
    var lastDecisionStatus = ""
    var findScores: [String: Double] = [:]
    var exactMatched = false
    private(set) var metadata: [PaneID: PageMetadata] = [:]
    private(set) var labels: [PaneID: String] = [:]
    private(set) var portraits: [PaneID: PagePortrait] = [:]
    private(set) var labelEffect: AILabelEffect?
    private(set) var grants: [PaneID: String] = [:]
    var enabled = JevPreferences.enabled()
    var automaticLabels = UserDefaults.standard.object(forKey: "jev.labels") as? Bool ?? true
    /// Every on-device model call: tab names and descriptions, and the site
    /// menu check. Off, the browser uses its own rules for each.
    var appleEnabled = UserDefaults.standard.object(forKey: "apple.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(appleEnabled, forKey: "apple.enabled") }
    }
    let originGrants = AIContentGrantStore()
    @ObservationIgnored private var declinedOrigins: Set<String> = []
    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private var intelligence: BrowserIntelligence
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [String: RequestRevision] = [:]
    @ObservationIgnored private var resultDocument = ""
    @ObservationIgnored private var nextPanel: Panel?

    init(intelligence: BrowserIntelligence? = nil) {
        self.intelligence = intelligence ?? BrowserIntelligence(audit: IntelligenceAuditStore.shared)
        refreshCredentialStatus()
    }
    var current: PageMetadata? { workspace?.activePane.flatMap { metadata[$0] } }
    var canShare: Bool { current?.publicWebPage == true }
    var escapeCloses: Bool { panel != nil }
    var shared: Bool { workspace?.activePane.map { grants[$0] == metadata[$0]?.document && grants[$0] != nil } ?? false }
    var origin: String { current?.origin ?? "" }
    private(set) var hasKey = false
    var usesIncludedJev: Bool { JevRuntime.includesJev }
    var hasJevAccess: Bool { usesIncludedJev || hasKey }

    private func refreshCredentialStatus() {
        if usesIncludedJev {
            hasKey = false
            return
        }
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
        if labelEffect?.pane == pane { labelEffect = nil }
        if wasActive {
            closePanel()
        }
    }
    func loaded(_ pane: PaneID, page view: WebKitPage) {
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
            } catch { /* The address and normal browsing remain available. */ }
        }
    }
    func prune() {
        guard let workspace else { return }
        for pane in metadata.keys where !workspace.paneAlive(pane) { committed(pane) }
    }
    func changedTab() { closePanel() }

    func activated(_ pane: PaneID) {
        PageTextBridge.clear(workspace?.hosts.existingBrowser(pane))
    }

    func shouldReplaceSiteMenu(host: String, labels: String) async -> Bool? {
        guard appleEnabled else { return nil }
        return await intelligence.shouldReplaceSiteMenu(host: host, labels: labels)
    }

    func configure() {
        UserDefaults.standard.set(enabled, forKey: JevPreferences.enabledKey)
        UserDefaults.standard.set(automaticLabels, forKey: "jev.labels")
        for key in Array(tasks.keys) { cancel(key) }
        if let pane = workspace?.activePane { PageTextBridge.clear(workspace?.hosts.existingBrowser(pane)) }
        refreshCredentialStatus()
        grants.removeAll(); busy = false
        matches = []
        labelEffect = nil
        labels = Dictionary(uniqueKeysWithValues: metadata.map { pane, page in
            (pane, (automaticLabels ? portraits[pane]?.label : nil) ?? PageLabels.fallback(page))
        })
        Task { await intelligence.reset() }
        status = enabled ? "Share this page to use Jev." : JevError.disabled.errorDescription!
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
                status = "This page is local, editable, or contains a password field. Page sharing is unavailable."; return
            }
            declinedOrigins.remove(page.origin)
            originGrants.grant(page.origin, remember: remember)
            grants[pane] = page.document
            describePage(pane, page: page)
            panel = nextPanel
            if panel == .find { findChanged() }
        } catch { status = errorMessage(error) }
    }
    func revokePage() {
        if let pane = workspace?.activePane {
            if let origin = metadata[pane]?.origin {
                originGrants.revoke(origin)
                declinedOrigins.insert(origin)
            }
            grants.removeValue(forKey: pane)
            cancel("label-\(pane.rawValue)")
        }
        cancel("find"); busy = false; matches = []
    }
    /// Removing a site from the shared list stops sharing it the way Stop
    /// Sharing This Page does, for every open page on that site.
    func revokeOrigin(_ origin: String) {
        guard !origin.isEmpty else { return }
        if current?.origin == origin { revokePage() }
        originGrants.revoke(origin)
        declinedOrigins.insert(origin)
        for (pane, page) in metadata where page.origin == origin {
            grants.removeValue(forKey: pane)
        }
    }
    private func describePage(_ pane: PaneID, page: PageMetadata) {
        guard appleEnabled else { return }
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

    func openFind() {
        workspace?.discardLine(); workspace?.setOverviewOpen(false)
        panel = .find
        findChanged()
    }
    func closePanel() {
        if panel == .permission, let origin = current?.origin, !origin.isEmpty {
            declinedOrigins.insert(origin)
        }
        let wasFinding = panel == .find
        cancel("find"); cancel("exact"); panel = nil; nextPanel = nil
        busy = false; matches = []; status = ""
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
            status = "Exact find only on local, editable, or password pages."; return
        }
        if !shared { grants[pane] = page.document }
        runFind()
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
    private func runFind() {
        let key = "find", revision = token("find")
        guard let pane = workspace?.activePane else {
            busy = false
            return
        }
        guard let page = metadata[pane], let view = workspace?.hosts.existingBrowser(pane) else {
            busy = false
            status = "The page changed. Run the search again."
            return
        }
        let query = query
        busy = true; status = "Finding related passages…"
        tasks[key] = Task { [weak self, weak view] in
            guard let self else { return }
            defer {
                if self.accepts(key, revision) { self.busy = false }
            }
            guard let view else {
                if self.accepts(key, revision) { self.status = "The page changed. Run the search again." }
                return
            }
            do {
                try self.requireReady()
                try await Task.sleep(for: .milliseconds(400))
                let extract = try await PageTextBridge.extract(view)
                guard self.accepts(key, revision) else { return }
                guard extract.document == page.document, extract.url == view.url?.absoluteString else {
                    self.status = "The page changed. Run the search again."
                    return
                }
                let candidates = extract.passages
                guard !candidates.isEmpty else {
                    self.status = "No readable passages found. Exact find still works."
                    return
                }
                self.status = "Searching \(candidates.count) page elements…"
                let decision = try await self.intelligence.meaningFind(query: query, passages: candidates).value
                guard self.accepts(key, revision) else { return }
                guard self.workspace?.activePane == pane, self.grants[pane] == page.document,
                      view.url?.absoluteString == extract.url else {
                    self.status = "The page changed. Run the search again."
                    return
                }
                self.resultDocument = extract.document
                self.lastDecisionStatus = "Jev decision received for find"
                let coverage = "Checked \(candidates.count) passages."
                self.findScores = decision.scores
                self.matches = decision.matches
                self.status = self.matches.isEmpty ? "No clear meaning matches. \(coverage)" : "\(self.matches.count) possible matches. \(coverage)"
                if let first = self.matches.first {
                    self.show(first)
                    self.workspace?.noteOnboardingFound()
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
                self.matches = []; self.status = "The page changed. Run the search again."
            }
        }
    }
}
