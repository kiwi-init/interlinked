import AppKit
import SwiftUI

private extension SettingsDestination {
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .pages: "shield.lefthalf.filled"
        case .intelligence: "sparkles"
        case .sites: "globe"
        case .privacy: "hand.raised.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .pages: .green
        case .intelligence: .purple
        case .sites: .blue
        case .privacy: .indigo
        }
    }

    var summary: String {
        switch self {
        case .general: "The site menu, search, useful page information, and downloads."
        case .pages: "Blocking and dark pages, applied to every site you visit."
        case .intelligence: "Which models Interlinked uses, and when they run."
        case .sites: "Everything you have allowed, denied, or changed for a single site."
        case .privacy: "What leaves this Mac, what stays, and a record of every AI request."
        }
    }

    /// Search matches what a pane contains, not only its name.
    var keywords: [String] {
        switch self {
        case .general: ["site menu", "header", "search", "search provider", "search engine", "google", "duckduckgo", "bing", "brave", "ecosia", "suggestions", "local suggestions", "useful information", "address", "contact", "phone", "email", "copy", "downloads", "notifications"]
        case .pages: ["ads", "trackers", "blocking", "filter lists", "easylist", "ublock", "dark", "appearance", "theme"]
        case .intelligence: ["jev", "apple intelligence", "openrouter", "api key", "critical reading", "always on", "labels", "meaning search"]
        case .sites: ["permissions", "camera", "microphone", "location", "grants", "exceptions", "revoke", "blocking off", "kept light", "navigation"]
        case .privacy: ["history", "browsing history", "sharing screen mode", "screen sharing", "presenting", "blur", "cache", "activity", "audit", "export", "clear", "data", "signed in", "passwords"]
        }
    }

    func matches(_ query: String) -> Bool {
        rawValue.localizedCaseInsensitiveContains(query) || keywords.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct InterlinkedSettings: View {
    @Environment(Workspace.self) private var workspace
    @State private var search = ""

    private var sections: [SettingsDestination] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? SettingsDestination.allCases : SettingsDestination.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView {
            List(sections, selection: $workspace.settingsDestination) { section in
                SettingsSidebarRow(section: section)
                    .tag(section)
                    .pointingHandCursor()
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                Text(Self.version)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane(workspace.settingsDestination)
                .navigationTitle(workspace.settingsDestination.rawValue)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 640)
        .onChange(of: search) { _, _ in
            if let first = sections.first, !sections.contains(workspace.settingsDestination) {
                workspace.settingsDestination = first
            }
        }
    }

    @ViewBuilder
    private func pane(_ section: SettingsDestination) -> some View {
        switch section {
        case .general: GeneralSettingsPane()
        case .pages: PagesSettingsPane()
        case .intelligence: IntelligenceSettingsPane()
        case .sites: SitesSettingsPane()
        case .privacy: PrivacySettingsPane()
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Interlinked \(release)" : "Interlinked \(release) (\(build))"
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let downloads = workspace.downloads
        @Bindable var usefulInfo = workspace.usefulInfo
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { workspace.usesSiteMenu },
                    set: { workspace.usesSiteMenu = $0 }
                )) {
                    Text("Replace site headers with the Interlinked menu")
                    Text("The same compact menu on every site, with its main destinations and search. Turn this off to put the site's own header back.")
                }
                .toggleStyle(PointingSwitch())
                .accessibilityIdentifier("settings-site-menu")
            } header: {
                SettingsHero(section: .general, firstSection: "Site menu")
            }

            SearchSection()

            Section {
                Toggle(isOn: $usefulInfo.showsAddress) {
                    Label {
                        Text("Address")
                        Text("A button above the toolbox copies the page's street address.")
                    } icon: {
                        Image(systemName: "map")
                    }
                }
                .toggleStyle(PointingSwitch())
                .accessibilityIdentifier("settings-useful-address")
                Toggle(isOn: $usefulInfo.showsContact) {
                    Label {
                        Text("Contact")
                        Text("Copies the page's phone number or email. With several, the button opens to let you choose.")
                    } icon: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                .toggleStyle(PointingSwitch())
                .accessibilityIdentifier("settings-useful-contact")
            } header: {
                Text("Useful information")
            } footer: {
                SettingsFooter("Found on this Mac from the page's own contact details. Nothing is sent to Jev or any model.")
            }

            Section("Downloads") {
                LabeledContent {
                    HStack(spacing: 10) {
                        if downloads.notificationStatus == "Off" {
                            Button("Allow…", action: downloads.requestNotificationPermission)
                                .pointingHandCursor()
                        }
                        StatusBadge(downloads.notificationStatus,
                                    tone: downloads.notificationStatus == "Off" ? .warning : .neutral)
                    }
                } label: {
                    Text("Notifications")
                    Text("Interlinked tells you when a download finishes or fails.")
                }
            }

            #if DEBUG
            DeveloperSection()
            #endif
        }
        .settingsPane()
    }
}

private struct SearchSection: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var search = workspace.search
        Section {
            LabeledContent {
                Picker("Search provider", selection: $search.provider) {
                    ForEach(SearchProvider.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .pointingHandCursor()
                .accessibilityIdentifier("settings-search-provider")
            } label: {
                Text("Search provider")
            }
            Toggle(isOn: $search.remoteSuggestions) {
                Text("Show suggestions from the search provider")
                Text(search.remoteSuggestions
                     ? "Typed text is sent to \(search.suggestionProvider.name) after a short pause."
                     : "Local suggestions only: typed text stays on this Mac until you press Return.")
            }
            .toggleStyle(PointingSwitch())
            .accessibilityIdentifier("settings-remote-suggestions")
            if search.remoteSuggestions {
                DisclosureGroup {
                    LabeledContent {
                        Picker("Suggestions from", selection: $search.suggestionOverride) {
                            Text("Same as search provider").tag(SearchProvider?.none)
                            Divider()
                            ForEach(SearchProvider.allCases) { Text($0.name).tag(SearchProvider?.some($0)) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .pointingHandCursor()
                        .accessibilityIdentifier("settings-suggestion-provider")
                    } label: {
                        Text("Suggestions from")
                    }
                } label: {
                    Text("Advanced").pointingHandCursor()
                }
            }
        } header: {
            Text("Search")
        }
    }
}

#if DEBUG
/// Debug builds only. Not compiled into TestFlight or release.
private struct DeveloperSection: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var onboarding = workspace.onboarding
        Section {
            Toggle(isOn: $onboarding.alwaysShow) {
                Text("Always show onboarding")
                Text("Opens the Onboarding tab at every launch, starting from the first scene.")
            }
            .toggleStyle(PointingSwitch())
            .accessibilityIdentifier("settings-debug-onboarding")
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Reset Progress") { workspace.onboarding.reset() }
                        .pointingHandCursor()
                    Button("Show Now", action: workspace.openOnboarding)
                        .pointingHandCursor()
                }
            } label: {
                Text("Onboarding")
                Text("Scene \(workspace.onboarding.progress.scene.id) of \(OnboardingScene.all.count)")
            }
        } header: {
            Text("Developer")
        } footer: {
            SettingsFooter("Shown in debug builds only.")
        }
    }
}
#endif

// MARK: - Pages

private struct PagesSettingsPane: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var builtIns = workspace.builtIns
        Form {
            Section {
                Toggle(isOn: $builtIns.blockingEnabled) {
                    Text("Block ads and trackers")
                    Text("Requests are blocked before they load, leftover ad slots are hidden, and video ads are removed.")
                }
                .toggleStyle(PointingSwitch())
                LabeledContent("Blocked so far") {
                    Text(builtIns.blockedTotal.formatted())
                        .monospacedDigit()
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        if builtIns.updating { ProgressView().controlSize(.small) }
                        Button("Update Now") { Task { await builtIns.updateLists() } }
                            .disabled(builtIns.updating)
                            .pointingHandCursor()
                    }
                } label: {
                    Text("Filter lists")
                    Text(listsSummary(builtIns))
                }
            } header: {
                SettingsHero(section: .pages, firstSection: "Ads and trackers")
            } footer: {
                SettingsFooter("Uses Brave's adblock engine with uBlock Origin's filters, EasyList, EasyPrivacy, and Peter Lowe's list, refreshed daily.")
            }

            Section {
                LabeledContent {
                    Picker("Darken pages", selection: $builtIns.darkMode) {
                        ForEach(PageDarkMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .pointingHandCursor()
                } label: {
                    Text("Darken pages")
                    Text("Sites with their own dark theme use it. Interlinked recolors the rest and leaves images alone.")
                }
            } header: {
                Text("Dark pages")
            } footer: {
                SettingsFooter("Sites where you turned blocking off or kept pages light are listed in Sites.")
            }
        }
        .settingsPane()
    }

    private func listsSummary(_ builtIns: PageBuiltIns) -> String {
        if !builtIns.status.isEmpty { return builtIns.status }
        guard builtIns.engineReady else { return "Preparing…" }
        let updated = builtIns.listsUpdatedAt.map { "updated " + $0.formatted(.relative(presentation: .named)) } ?? "never updated"
        return "\(BlockList.standard.count) lists active, \(updated)"
    }
}

// MARK: - Intelligence

private struct IntelligenceSettingsPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var confirmAutomaticReading = false

    var body: some View {
        @Bindable var assistant = workspace.assistance
        Form {
            Section {
                ModelStatusRow(
                    symbol: "sparkles", tint: .purple, title: "Jev",
                    detail: "Meaning search, Critical Reading, and related-tab grouping.",
                    status: jevStatus(assistant)
                )
                ModelStatusRow(
                    symbol: "apple.intelligence", tint: .blue, title: "Apple Intelligence",
                    detail: "On-device tab labels, page descriptions, and navigation warnings.",
                    status: LocalIntelligenceRuntime.isAvailable
                        ? ("Available", .good) : ("Not on this Mac", .neutral)
                )
            } header: {
                SettingsHero(section: .intelligence, firstSection: "Models")
            }

            Section {
                Toggle(isOn: $assistant.enabled) {
                    Text("Use Jev")
                    Text("Turn this off to keep every page on this Mac. Exact find keeps working.")
                }
                .toggleStyle(PointingSwitch())
                .onChange(of: assistant.enabled) { _, _ in assistant.configure() }

                if !assistant.usesIncludedJev {
                    LabeledContent {
                        SecureField("", text: $key, prompt: Text(assistant.hasKey ? "Saved in Keychain" : "Paste key"))
                            .textContentType(.password)
                            .frame(width: 240)
                            .onSubmit { saveKey(assistant) }
                            .accessibilityIdentifier("openrouter-key")
                    } label: {
                        Text("OpenRouter API key")
                        Text(keyMessage.isEmpty ? "Stored in macOS Keychain, never in preferences or logs." : keyMessage)
                    }
                    HStack {
                        Spacer()
                        Button("Remove Key", role: .destructive) {
                            JevCredential.remove()
                            assistant.configure()
                            keyMessage = "Key removed."
                        }
                        .disabled(!assistant.hasKey)
                        .pointingHandCursor()
                        Button("Save Key") { saveKey(assistant) }
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .pointingHandCursor()
                    }
                }
            } header: {
                Text("Jev")
            }

            Section {
                LabeledContent {
                    Picker("Run Critical Reading", selection: Binding(
                        get: { assistant.criticalReadingMode },
                        set: { mode in
                            if mode == .automatic && assistant.criticalReadingMode != .automatic {
                                confirmAutomaticReading = true
                            } else {
                                if mode != .automatic { assistant.automaticReadingConsented = false }
                                assistant.criticalReadingMode = mode
                                assistant.configure()
                            }
                        }
                    )) {
                        ForEach(CriticalReadingMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .pointingHandCursor()
                    .accessibilityIdentifier("critical-reading-mode")
                } label: {
                    Text("Run Critical Reading")
                    Text(assistant.automaticReadingEnabled
                         ? "Checks every page you open, without asking. Page → Stop Sharing This Page pauses a site."
                         : "Checks a page when you choose Critical Reading in the toolbox.")
                }

                LabeledContent {
                    Button("Show Definitions…") { openWindow(id: "about") }
                        .pointingHandCursor()
                } label: {
                    Text("How it decides")
                    Text("\(PassageDecisions.Signal.allCases.count - 2) fixed, dictionary-based signals. They cannot be edited.")
                }
            } header: {
                Text("Critical Reading")
            } footer: {
                SettingsFooter("An anti-bias aid, not a fact checker. Read the highlighted source and decide for yourself.")
            }

            Section("Apple Intelligence") {
                Toggle(isOn: workspace.binding(for: .appleIntelligence)) {
                    Text("Use Apple Intelligence")
                    Text(workspace.note(for: .appleIntelligence)
                         ?? "Tab names, link warnings, and the site menu check. Runs on this Mac; nothing it reads leaves it.")
                }
                .toggleStyle(PointingSwitch())
                .accessibilityIdentifier("settings-apple-intelligence")
                Toggle(isOn: $assistant.automaticLabels) {
                    Text("Refine page labels")
                    Text("Apple Intelligence writes a short tab label from the page's title, headings, and description.")
                }
                .toggleStyle(PointingSwitch())
                .disabled(!assistant.appleEnabled)
                .onChange(of: assistant.automaticLabels) { _, _ in assistant.configure() }
            }
        }
        .settingsPane()
        .confirmationDialog(
            "Turn on Always-on Critical Reading?",
            isPresented: $confirmAutomaticReading,
            titleVisibility: .visible
        ) {
            Button("Enable Always On") { workspace.assistance.acceptAutomaticReading() }
                .accessibilityIdentifier("confirm-automatic-reading")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AutomaticReadingConsent.warning)
        }
    }

    private func jevStatus(_ assistant: BrowserAssistance) -> (String, StatusBadge.Tone) {
        if !assistant.enabled { return ("Off", .neutral) }
        if !assistant.hasJevAccess { return ("Needs API key", .warning) }
        return (assistant.usesIncludedJev ? "Included" : "Ready", .good)
    }

    private func saveKey(_ assistant: BrowserAssistance) {
        do {
            try JevCredential.save(key)
            key = ""
            assistant.configure()
            keyMessage = "Saved in macOS Keychain."
        } catch {
            keyMessage = "Couldn't save the key."
        }
    }
}

// MARK: - Sites

private struct SitesSettingsPane: View {
    @Environment(Workspace.self) private var workspace
    @State private var filter = ""

    private struct Entry: Identifiable {
        var id: String
        var site: String
        var detail: String
        var revoke: () -> Void
    }

    var body: some View {
        let groups = groups()
        let visible = groups.map { ($0.0, $0.1, $0.2.filter(matches)) }.filter { !$0.2.isEmpty }
        Form {
            Section {
                if groups.allSatisfy({ $0.2.isEmpty }) {
                    Text("Nothing saved yet. When you share a page with Jev, answer a permission prompt, or turn blocking off for a site, it appears here.")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Filter sites", text: $filter, prompt: Text("Filter sites"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            } header: {
                SettingsHero(section: .sites, firstSection: nil)
            }

            ForEach(visible, id: \.0) { title, footer, entries in
                Section {
                    ForEach(entries) { entry in
                        LabeledContent {
                            Button("Remove", action: entry.revoke)
                                .buttonStyle(.borderless)
                                .pointingHandCursor()
                        } label: {
                            Text(entry.site)
                            Text(entry.detail)
                        }
                    }
                } header: {
                    HStack {
                        Text(title)
                        Spacer()
                        if entries.count > 1 {
                            Button("Remove All") { entries.forEach { $0.revoke() } }
                                .buttonStyle(.borderless)
                                .font(.callout)
                                .pointingHandCursor()
                        }
                    }
                } footer: {
                    SettingsFooter(footer)
                }
            }

            if !filter.isEmpty && visible.isEmpty {
                Section { Text("No sites match “\(filter)”.").foregroundStyle(.secondary) }
            }
        }
        .settingsPane()
    }

    private func matches(_ entry: Entry) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || entry.site.localizedCaseInsensitiveContains(query) || entry.detail.localizedCaseInsensitiveContains(query)
    }

    private func host(_ origin: String) -> String {
        URL(string: origin)?.host ?? origin
    }

    private func groups() -> [(String, String, [Entry])] {
        let grants = workspace.assistance.originGrants
        let permissions = workspace.permissions
        let exceptions = workspace.navigationExceptions
        let builtIns = workspace.builtIns
        return [
            ("Page text shared with Jev",
             "Visit grants end when you quit. Remembered grants last until you remove them.",
             grants.records.map { origin in
                 Entry(id: "grant-" + origin, site: host(origin),
                       detail: grants.isRemembered(origin) ? "Remembered" : "This visit only",
                       revoke: { workspace.assistance.revokeOrigin(origin) })
             }),
            ("Website permissions",
             "Location prompts need macOS 27 or later. Websites can't send notifications from an embedded browser.",
             permissions.records.map { record in
                 Entry(id: "permission-\(record.id)", site: host(record.key.origin),
                       detail: "\(record.key.kind.label): \(record.decision == .allow ? "Allowed" : "Denied")",
                       revoke: { permissions.revoke(record.key) })
             }),
            ("Ad blocking turned off", "Ads and trackers load normally on these sites.",
             builtIns.unblockedSites.sorted().map { site in
                 Entry(id: "unblocked-" + site, site: site, detail: "Blocking off",
                       revoke: { builtIns.removeUnblockedSite(site) })
             }),
            ("Kept light", "These sites are never darkened.",
             builtIns.lightSites.sorted().map { site in
                 Entry(id: "light-" + site, site: site, detail: "Dark pages off",
                       revoke: { builtIns.removeLightSite(site) })
             }),
            ("Navigation exceptions", "Links to these sites open without the safety warning you already dismissed.",
             exceptions.records.map { record in
                 Entry(id: "exception-\(record.id)", site: host(record.key.origin),
                       detail: record.key.reasons.joined(separator: " "),
                       revoke: { exceptions.revoke(record.key) })
             })
        ]
    }
}

// MARK: - Privacy

private struct PrivacySettingsPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @State private var message = ""
    @State private var confirmClear = false
    @State private var confirmHistoryOff = false

    var body: some View {
        let assistant = workspace.assistance
        let audit = workspace.intelligenceAudit
        Form {
            Section {
                PrivacyFact(symbol: "lock.fill", title: "Passwords and forms stay local",
                            detail: "Form fields, password pages, editable text, cookies, and local files are never sent.")
                PrivacyFact(symbol: "person.crop.circle.badge.exclamationmark", title: "Signed-in pages are not detected",
                            detail: "Sharing a page while you are signed in sends what it shows, including messages or balances.")
                PrivacyFact(symbol: "hand.tap.fill", title: "Nothing runs without you",
                            detail: "Jev reads a page only when you ask, or on every page once you turn on Always on and accept its warning.")
                LabeledContent {
                    Button("Read Full Details…") { openWindow(id: "about") }
                        .pointingHandCursor()
                } label: {
                    Text("How Interlinked handles your data")
                }
            } header: {
                SettingsHero(section: .privacy, firstSection: "What leaves this Mac")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { workspace.browserHistory.enabled },
                    set: { on in
                        if !on && !workspace.browserHistory.visits.isEmpty {
                            confirmHistoryOff = true
                        } else {
                            workspace.browserHistory.enabled = on
                        }
                    }
                )) {
                    Text("Keep browsing history")
                    Text("Pages you visit stay on this Mac for \(HistoryRetention.standard.days) days. Turning this off deletes your history.")
                }
                .toggleStyle(PointingSwitch())
                .accessibilityIdentifier("settings-browsing-history")
            } header: {
                Text("History")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { workspace.sharingScreenMode },
                    set: { workspace.sharingScreenMode = $0 }
                )) {
                    Text("Sharing Screen Mode")
                    Text("Blurs sensitive details on every page while you present or share your screen. ⇧⌘S turns it on or off.")
                }
                .toggleStyle(PointingSwitch())
                .accessibilityIdentifier("settings-sharing-screen-mode")
            } header: {
                Text("Sharing Screen Mode")
            } footer: {
                SettingsFooter("Covers email addresses, phone numbers, card numbers, bank accounts (IBAN), CPF, CNPJ, and Social Security numbers, API keys and tokens, labeled passwords and ID numbers, and form fields that hold them. It runs inside the page before it appears, and nothing it finds leaves the page. Text in images is not covered.")
            }

            Section {
                LabeledContent {
                    Button("Clear Cache", action: assistant.clearDecisionCache)
                        .pointingHandCursor()
                } label: {
                    Text("Recent AI decisions")
                    Text(assistant.cacheStatus.isEmpty
                         ? "Identical Jev answers and Apple labels are reused for five days."
                         : assistant.cacheStatus)
                }
            } header: {
                Text("Cache")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Export…", action: export)
                            .disabled(audit.isEmpty)
                            .pointingHandCursor()
                        Button("Clear…", role: .destructive) { confirmClear = true }
                            .disabled(audit.isEmpty)
                            .pointingHandCursor()
                    }
                } label: {
                    Text("\(audit.events.count.formatted()) recorded \(audit.events.count == 1 ? "action" : "actions")")
                    Text(message.isEmpty ? "Which model ran, for what, and whether it worked." : message)
                }
                if !audit.recent.isEmpty {
                    DisclosureGroup {
                        ForEach(audit.recent) { IntelligenceActivityRow(event: $0) }
                    } label: {
                        Text("Recent actions").pointingHandCursor()
                    }
                }
            } header: {
                Text("Activity log")
            } footer: {
                SettingsFooter("Metadata only. Page text, URLs, queries, prompts, responses, credentials, and errors are never recorded.")
            }
        }
        .settingsPane()
        .confirmationDialog("Turn off browsing history?", isPresented: $confirmHistoryOff, titleVisibility: .visible) {
            Button("Turn Off and Delete History", role: .destructive) {
                workspace.browserHistory.enabled = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every visit saved on this Mac and stops recording new ones.")
        }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Activity Log", role: .destructive) {
                workspace.intelligenceAudit.clear()
                message = "Activity log cleared."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every recorded intelligence action from this Mac.")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Interlinked Intelligence Activity.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try workspace.intelligenceAudit.export(to: destination)
            message = "Exported."
        } catch {
            message = "Couldn't export the activity log."
        }
    }
}

// MARK: - Components

private extension View {
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.visible)
    }
}

/// A Form switch whose pointing cursor covers the switch, not the row: the
/// row's title and subtitle are not clickable.
private struct PointingSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .pointingHandCursor()
        } label: {
            configuration.label
        }
    }
}

/// Opens each pane the way System Settings does: icon, name, and one line
/// on what lives here. It rides in the first section's header so it scrolls
/// with the content.
private struct SettingsHero: View {
    var section: SettingsDestination
    var firstSection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                SettingsIcon(symbol: section.symbol, tint: section.tint, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.rawValue)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(section.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textCase(nil)
            .padding(.top, 4)
            if let firstSection { Text(firstSection) }
        }
    }
}

private struct SettingsIcon: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

private struct SettingsSidebarRow: View {
    var section: SettingsDestination

    var body: some View {
        Label {
            Text(section.rawValue)
        } icon: {
            SettingsIcon(symbol: section.symbol, tint: section.tint)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsFooter: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct StatusBadge: View {
    enum Tone { case good, warning, neutral }

    var text: String
    var tone: Tone

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    private var color: Color {
        switch tone {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct ModelStatusRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var status: (String, StatusBadge.Tone)

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            StatusBadge(status.0, tone: status.1)
        }
        .padding(.vertical, 2)
    }
}

private struct PrivacyFact: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.indigo)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct IntelligenceActivityRow: View {
    var event: IntelligenceAuditEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.source == .appleIntelligence ? "apple.intelligence" : "sparkles")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.action)
                Text(event.source.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(event.outcome.label, systemImage: event.outcome.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
