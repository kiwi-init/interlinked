import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Temporary tools grow inside the existing page handle.
struct AssistanceView: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette
    var hasFooter = true
    private var assistant: BrowserAssistance { workspace.assistance }

    var body: some View {
        @Bindable var assistant = assistant
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(assistant.panel == .find ? "Find in page" : assistant.panel == .reading ? "Critical reading" : "Share this page")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { assistant.closePanel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.pointing).accessibilityLabel("Close page tool")
            }
            switch assistant.panel {
            case .find:
                WorkInput(text: $assistant.query, placeholder: "Find words or describe a passage",
                          identifier: "page-find", fontSize: 13, palette: palette,
                          submit: { assistant.moveMatch(1) }, cancel: assistant.closePanel,
                          moveSelection: assistant.moveMatch)
                    .frame(height: 22)
                    .onChange(of: assistant.query) { _, _ in assistant.findChanged() }
                HStack {
                    Toggle("By meaning", isOn: $assistant.byMeaning).toggleStyle(.checkbox)
                        .pointingHandCursor()
                        .onChange(of: assistant.byMeaning) { _, _ in assistant.findChanged() }
                    Spacer()
                    Button { assistant.moveMatch(-1) } label: { Image(systemName: "chevron.up") }
                        .accessibilityLabel("Previous match")
                        .pointingHandCursor()
                    Button { assistant.moveMatch(1) } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Next match")
                        .pointingHandCursor()
                }
                if assistant.byMeaning {
                    Text("Jev searches page text. Matches are highlighted in yellow.")
                        .font(.system(size: 10)).foregroundStyle(.primary)
                }
                Text(assistant.status).foregroundStyle(.primary).lineLimit(3)
            case .reading: EmptyView()
            case .permission:
                Text(assistant.origin.isEmpty ? "Page unavailable" : assistant.origin).lineLimit(1).fontWeight(.medium)
                Text("Jev uses OpenRouter and TypeSafe to evaluate this page's title, description, labels, and readable page text for each search or reading check. Forms, passwords, cookies, and signed-in pages are excluded. A grant covers this site origin. Sharing this visit ends when you quit; remembering the site keeps the grant until you revoke it.")
                Text("Only share content you are comfortable sending. OpenRouter's policy is that requests are anonymized and not used for training. You still accept the risk that a third party will see this page's text.").foregroundStyle(.primary)
                if !assistant.enabled || !assistant.hasJevAccess {
                    SettingsLink { Text("Configure Jev in Settings…") }
                        .pointingHandCursor()
                }
                if !assistant.canShare {
                    Text("Local, signed-in, editable, and password pages cannot be shared.").foregroundStyle(.primary)
                }
                Text(assistant.status).foregroundStyle(.primary)
                HStack {
                    Button("Cancel", action: assistant.closePanel)
                        .pointingHandCursor()
                    Spacer()
                    Button("Share this visit") { assistant.allowPage(remember: false) }
                        .disabled(!assistant.canShare || !assistant.enabled || !assistant.hasJevAccess)
                        .accessibilityIdentifier("allow-page-sharing")
                        .pointingHandCursor()
                    Button("Remember this site") { assistant.allowPage(remember: true) }
                        .disabled(!assistant.canShare || !assistant.enabled || !assistant.hasJevAccess)
                        .accessibilityIdentifier("remember-page-sharing")
                        .pointingHandCursor()
                }
            case nil: EmptyView()
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .padding(.bottom, hasFooter ? 44 : 0)
        .onExitCommand { assistant.closePanel() }
    }
}

private extension SettingsDestination {
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .intelligence: "sparkles"
        case .builtIns: "shield.lefthalf.filled"
        case .data: "externaldrive"
        case .sites: "globe"
        case .about: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .intelligence: .purple
        case .builtIns: .green
        case .data: .orange
        case .sites: .blue
        case .about: .gray
        }
    }
}

struct AssistanceSettings: View {
    @Environment(Workspace.self) private var workspace
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var exportMessage = ""
    @State private var confirmClearActivity = false
    @State private var confirmAutomaticReading = false
    @State private var settingsSearch = ""

    private var visibleSections: [SettingsDestination] {
        let query = settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsDestination.allCases }
        return SettingsDestination.allCases.filter {
            $0.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        @Bindable var workspace = workspace
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField(
                    "",
                    text: $settingsSearch,
                    prompt: Text("Search Settings").foregroundStyle(.primary)
                )
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.top, 48)
                    .padding(.bottom, 10)

                List(visibleSections, selection: $workspace.settingsDestination) { section in
                    SettingsSidebarRow(section: section)
                        .tag(section)
                        .pointingHandCursor()
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 218)
            .background(.regularMaterial)

            Divider()

            settingsDetail(workspace.settingsDestination)
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 560, idealHeight: 620)
        .confirmationDialog(
            "Clear intelligence activity?",
            isPresented: $confirmClearActivity,
            titleVisibility: .visible
        ) {
            Button("Clear All Activity", role: .destructive) {
                workspace.intelligenceAudit.clear()
                exportMessage = "Activity cleared."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the complete local intelligence audit log.")
        }
        .confirmationDialog(
            "Turn on Always-on Critical Reading?",
            isPresented: $confirmAutomaticReading,
            titleVisibility: .visible
        ) {
            Button("Enable Always on") {
                workspace.assistance.acceptAutomaticReading()
            }
            .accessibilityIdentifier("confirm-automatic-reading")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AutomaticReadingConsent.warning)
        }
    }

    @ViewBuilder
    private func settingsDetail(_ section: SettingsDestination) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.rawValue)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(height: 52)

            Divider()

            switch section {
            case .general: generalSettings
            case .intelligence: intelligenceSettings
            case .builtIns: builtInSettings
            case .data: dataSettings
            case .sites: siteSettings
            case .about: aboutSettings
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generalSettings: some View {
        @Bindable var sites = workspace.savedSites
        return Form {
            Section("New Tab") {
                Toggle("Show favorites and bookmarks", isOn: $sites.showsOnNewTab)
                    .pointingHandCursor()
                    .accessibilityIdentifier("settings-new-tab-saved-sites")
            }

            Section("Site menu") {
                Toggle("Use Interlinked site menu", isOn: Binding(
                    get: { workspace.usesSiteMenu },
                    set: { workspace.usesSiteMenu = $0 }
                ))
                    .pointingHandCursor()
                    .accessibilityIdentifier("settings-site-menu")
                SettingsNote("The same compact menu, centered, on every site: its main destinations, and search when the site has one. The site name stays on the page handle. Turn this off to put the site's header back.")
            }

            Section("Downloads") {
                LabeledContent("System notifications") {
                    Text(workspace.downloads.notificationStatus)
                        .foregroundStyle(.primary)
                }
                if workspace.downloads.notificationStatus == "Off" {
                    Button("Allow Notifications", action: workspace.downloads.requestNotificationPermission)
                        .pointingHandCursor()
                }
            }

            Section("Browser support") {
                SettingsNote("Location permission prompts require macOS 27 or later.")
                SettingsNote("Website notification permission is not available to embedded macOS browsers. Download alerts use app notifications.")
            }
        }
        .settingsForm()
    }

    private var intelligenceSettings: some View {
        @Bindable var assistant = workspace.assistance
        let audit = workspace.intelligenceAudit
        return Form {
            Section("Apple Intelligence") {
                Label(
                    LocalIntelligenceRuntime.isAvailable ? "Available on this Mac" : "Unavailable on this Mac",
                    systemImage: LocalIntelligenceRuntime.isAvailable ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(.primary)
                SettingsNote("On-device. Writes a tab label and a short page description from metadata. Paraphrases a few navigation warnings. Does not rank Vault or group tabs.")
            }

            Section("Jev") {
                Toggle("Enable Jev", isOn: $assistant.enabled)
                    .pointingHandCursor()
                    .onChange(of: assistant.enabled) { _, _ in assistant.configure() }

                if assistant.usesIncludedJev {
                    Label("Access included", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                } else {
                    LabeledContent("OpenRouter API key") {
                        SecureField(
                            "",
                            text: $key,
                            prompt: Text("Paste key").foregroundStyle(.primary)
                        )
                            .textContentType(.password)
                            .foregroundStyle(.primary)
                            .frame(width: 280)
                            .accessibilityIdentifier("openrouter-key")
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
                            .keyboardShortcut(.defaultAction)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .pointingHandCursor()
                    }
                    Label(keyStatus(assistant), systemImage: assistant.hasKey ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(.primary)
                }
                SettingsNote("Jev handles meaning search, Critical Reading, Vault ranking, and related-tab grouping.")
            }

            Section("Behavior") {
                Picker("Critical Reading", selection: Binding(
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
                .pointingHandCursor()
                .accessibilityIdentifier("critical-reading-mode")
                SettingsNote(assistant.automaticReadingEnabled
                    ? "Always-on sends readable text from sites you have granted. Revoke a site below to stop."
                    : "Fresh installs leave Always-on off. Enabling it asks you to accept the privacy risk first.")

                Toggle("Refine public page labels", isOn: $assistant.automaticLabels)
                    .pointingHandCursor()
                    .onChange(of: assistant.automaticLabels) { _, _ in assistant.configure() }
            }

            Section("Sites allowed to send page text") {
                if assistant.originGrants.records.isEmpty {
                    Text("No sites granted.").foregroundStyle(.primary)
                } else {
                    ForEach(assistant.originGrants.records, id: \.self) { origin in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(origin)
                                Text(assistant.originGrants.isRemembered(origin) ? "Remembered on this Mac" : "This visit")
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Button("Revoke") { assistant.originGrants.revoke(origin) }
                                .pointingHandCursor()
                                .accessibilityIdentifier("revoke-origin-grant")
                        }
                    }
                    Button("Revoke All", role: .destructive, action: assistant.originGrants.revokeAll)
                        .pointingHandCursor()
                }
                SettingsNote("Grants are per origin. Remembered grants persist only if you choose Remember this site.")
            }

            criticalReadingDefinitions

            Section {
                SettingsNote("Metadata only. Page text, URLs, queries, prompts, responses, credentials, and error messages are never recorded.")
                LabeledContent("Recorded actions") {
                    Text("\(audit.events.count)")
                        .foregroundStyle(.primary)
                }

                if audit.recent.isEmpty {
                    Text("No intelligence activity yet.")
                        .foregroundStyle(.primary)
                } else {
                    ForEach(audit.recent) { event in
                        IntelligenceActivityRow(event: event)
                    }
                }

                HStack {
                    Button("Export All as JSON…", action: exportActivity)
                        .disabled(audit.isEmpty)
                        .pointingHandCursor()
                    Spacer()
                    Button("Clear Activity…", role: .destructive) {
                        confirmClearActivity = true
                    }
                    .disabled(audit.isEmpty)
                    .pointingHandCursor()
                }
                if !exportMessage.isEmpty {
                    Text(exportMessage)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
            } header: {
                Text("Last 20 Intelligence Actions")
            }
        }
        .settingsForm()
    }

    private var criticalReadingDefinitions: some View {
        Section("Critical Reading Definitions") {
            DisclosureGroup("View Definitions") {
                ForEach(PassageDecisions.Signal.allCases, id: \.rawValue) { signal in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(signal.label)
                            .fontWeight(.semibold)
                        Text(signal.explanation)
                            .font(.callout)
                    }
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.vertical, 3)
                }
            }
            SettingsNote("These dictionary-based definitions cannot be edited. They are the same for every check.")
        }
    }

    private var dataSettings: some View {
        let assistant = workspace.assistance
        return Form {
            Section("Intelligence cache") {
                LabeledContent("Recent Jev decisions") {
                    Button("Clear Cache", action: assistant.clearDecisionCache)
                        .pointingHandCursor()
                }
                SettingsNote("Identical Jev decisions and Apple page labels stay on this Mac for five days.")
                if !assistant.cacheStatus.isEmpty {
                    Text(assistant.cacheStatus).foregroundStyle(.primary)
                }
            }

            Section("Vault") {
                LabeledContent("Saved pages") {
                    Text("\(assistant.history.visits.count)")
                        .foregroundStyle(.primary)
                }
                Button("Clear Vault", role: .destructive, action: assistant.clearHistory)
                    .disabled(assistant.history.visits.isEmpty)
                    .pointingHandCursor()
            }

            Section("Privacy") {
                SettingsFeature(icon: "lock", title: "Sensitive pages stay local", detail: "Passwords, forms, cookies, local files, signed-in pages, and editable pages are not shared.")
                SettingsFeature(icon: "eye", title: "You stay in control", detail: "Always-on reading needs informed consent and a per-site grant. Intelligence results are suggestions. Review the source before relying on them.")
            }
        }
        .settingsForm()
    }

    private var builtInSettings: some View {
        @Bindable var builtIns = workspace.builtIns
        return Form {
            Section("Ad and tracker blocking") {
                Toggle("Block ads and trackers", isOn: $builtIns.blockingEnabled)
                LabeledContent("Blocked so far") { Text("\(builtIns.blockedTotal)").monospacedDigit() }
                LabeledContent("Engine") {
                    Text(builtIns.engineReady ? "\(BlockList.standard.count) lists active" : "Preparing…")
                }
                LabeledContent("Lists updated") {
                    Text(builtIns.listsUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                }
                HStack {
                    Button("Update Now") { Task { await builtIns.updateLists() } }
                        .disabled(builtIns.updating)
                        .pointingHandCursor()
                    if builtIns.updating { ProgressView().controlSize(.small) }
                    if !builtIns.status.isEmpty { Text(builtIns.status).foregroundStyle(.primary) }
                }
                Text("Interlinked blocks ad and tracker requests, answers the scripts pages depend on with harmless stand-ins, hides leftover ad slots, and removes video ads. It uses Brave’s adblock engine with uBlock Origin’s filters, EasyList, EasyPrivacy, and Peter Lowe’s list, refreshed daily.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !builtIns.unblockedSites.isEmpty {
                Section("Sites where blocking is off") {
                    ForEach(builtIns.unblockedSites.sorted(), id: \.self) { site in
                        HStack {
                            Text(site)
                            Spacer()
                            Button("Remove") { builtIns.removeUnblockedSite(site) }.pointingHandCursor()
                        }
                    }
                }
            }
            Section("Dark pages") {
                Picker("Darken pages", selection: $builtIns.darkMode) {
                    ForEach(PageDarkMode.allCases) { Text($0.label).tag($0) }
                }
                Text("Sites with their own dark theme use it. Interlinked recolors the rest and leaves images alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !builtIns.lightSites.isEmpty {
                Section("Sites kept light") {
                    ForEach(builtIns.lightSites.sorted(), id: \.self) { site in
                        HStack {
                            Text(site)
                            Spacer()
                            Button("Remove") { builtIns.removeLightSite(site) }.pointingHandCursor()
                        }
                    }
                }
            }
        }
        .settingsForm()
    }

    private var siteSettings: some View {
        Form {
            Section("Navigation exceptions") {
                if workspace.navigationExceptions.records.isEmpty {
                    Text("No saved navigation exceptions.").foregroundStyle(.primary)
                } else {
                    ForEach(workspace.navigationExceptions.records) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.key.origin)
                                Text(record.key.reasons.joined(separator: " "))
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Revoke") { workspace.navigationExceptions.revoke(record.key) }
                                .pointingHandCursor()
                        }
                    }
                    Button("Revoke All", role: .destructive, action: workspace.navigationExceptions.revokeAll)
                        .pointingHandCursor()
                }
            }

            Section("Website permissions") {
                if workspace.permissions.records.isEmpty {
                    Text("No saved website permissions.").foregroundStyle(.primary)
                } else {
                    ForEach(workspace.permissions.records) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.key.origin)
                                Text("\(record.key.kind.label): \(record.decision == .allow ? "Allowed" : "Denied")")
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Button("Revoke") { workspace.permissions.revoke(record.key) }
                                .pointingHandCursor()
                        }
                    }
                    Button("Revoke All", role: .destructive, action: workspace.permissions.revokeAll)
                        .pointingHandCursor()
                }
            }
        }
        .settingsForm()
    }

    private var aboutSettings: some View {
        Form {
            Section("Interlinked") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")
                        .foregroundStyle(.primary)
                }
                SettingsNote("A focused browser with transparent, user-controlled intelligence.")
            }
        }
        .settingsForm()
    }

    private func saveKey(_ assistant: BrowserAssistance) {
        do {
            try JevCredential.save(key)
            key = ""
            assistant.configure()
            keyMessage = "Saved in macOS Keychain."
        } catch {
            keyMessage = "Couldn’t save the key."
        }
    }

    private func keyStatus(_ assistant: BrowserAssistance) -> String {
        if !keyMessage.isEmpty { return keyMessage }
        return assistant.hasKey ? "Saved in macOS Keychain" : "No key saved"
    }

    private func exportActivity() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Interlinked Intelligence Activity.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try workspace.intelligenceAudit.export(to: destination)
            exportMessage = "Exported."
        } catch {
            exportMessage = "Couldn’t export the activity file."
        }
    }
}

private struct SettingsSidebarRow: View {
    var section: SettingsDestination

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(section.rawValue)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }
}

private struct IntelligenceActivityRow: View {
    var event: IntelligenceAuditEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.source == .appleIntelligence ? "apple.logo" : "sparkles")
                .frame(width: 20)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.action)
                    .fontWeight(.medium)
                Text(event.source.rawValue)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.primary)
                Label(event.outcome.label, systemImage: event.outcome.symbol)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension View {
    func settingsForm() -> some View {
        formStyle(.grouped)
            .padding(.horizontal, 8)
    }
}

private struct SettingsNote: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsFeature: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct Toolbox: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var palette: Palette
    private var assistant: BrowserAssistance { workspace.assistance }
    private var expanded: Bool {
        hovering || workspace.rightCommandKeyHeld || assistant.panel == .find || assistant.readingPanelOpen
    }
    private var menuWidth: CGFloat { assistant.panel == .find ? 400 : 190 }
    private var menuRows: CGFloat {
        CGFloat(assistant.criticalReadingMode == .onRequest ? 5 : 4)
    }
    private var width: CGFloat {
        if assistant.readingPanelOpen { return 340 }
        return expanded ? menuWidth : 108
    }
    private var height: CGFloat {
        if assistant.readingPanelOpen { return 150 }
        return expanded ? 44 + menuRows * 40 : 44
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if assistant.readingPanelOpen {
                ToolboxReadingPanel(palette: palette)
                    .transition(.opacity)
            } else {
                if expanded {
                    VStack(spacing: 0) {
                        PageTools(palette: palette)
                        BuiltInRows(palette: palette)
                    }
                    .frame(width: menuWidth)
                    .padding(.bottom, 44)
                    .transition(.opacity)
                }

                if expanded {
                    Button {
                        workspace.settingsDestination = .general
                        openSettings()
                    } label: {
                        ToolboxRowLabel(
                            title: "Settings",
                            symbol: "gearshape",
                            shortcut: workspace.toolboxShortcutLabel(.settings)
                        )
                        .frame(width: menuWidth, height: 44, alignment: .leading)
                    }
                    .buttonStyle(.pointing)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("toolbox-settings-button")
                } else {
                    HStack(spacing: 0) {
                        Image(systemName: "wrench.and.screwdriver")
                            .frame(width: 44, height: 44)
                        Text("Toolbox")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.trailing, 16)
                    }
                    .frame(width: 108, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Toolbox")
                    .accessibilityHint("Hover or hold right Command to show page tools")
                }
            }
        }
        .frame(width: width, height: height, alignment: .bottomTrailing)
        .foregroundStyle(palette.text)
        .modifier(PageGlass(radius: 14))
        .onHover { hovering = $0 }
        .onExitCommand(perform: closeActivePanel)
        .animation(reduceMotion ? nil : Metrics.morph, value: expanded)
        .animation(reduceMotion ? nil : Metrics.morph, value: width)
        .animation(reduceMotion ? nil : Metrics.morph, value: height)
    }

    private func closeActivePanel() {
        if assistant.panel != nil { assistant.closePanel() }
    }
}

struct PageActions: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    var available: CGSize
    private var assistant: BrowserAssistance { workspace.assistance }
    private var downloads: DownloadCenter { workspace.downloads }
    private var sharing: Bool { assistant.panel == .permission }
    private var historyOpen: Bool { workspace.pageHistoryOpen }
    private var browser: ChromiumPage? { workspace.activePane.flatMap(workspace.hosts.existingBrowser) }
    private var historyCount: Int { workspace.browserHistory.visits.count }
    private var width: CGFloat {
        if historyOpen { return min(330, available.width - 36) }
        if downloads.panelOpen { return min(390, available.width - 36) }
        if sharing { return min(370, available.width - 36) }
        return 132
    }
    private var height: CGFloat {
        if historyOpen { return min(max(140, CGFloat(historyCount) * 44 + 58), available.height - 36) }
        if downloads.panelOpen { return min(360, available.height - 36) }
        if sharing { return min(335, available.height - 36) }
        return 44
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if historyOpen {
                PageHistoryPanel(palette: palette) { workspace.pageHistoryOpen = false }
                    .transition(.opacity)
            } else if downloads.panelOpen {
                DownloadsPanel(palette: palette)
                    .transition(.opacity)
            } else if sharing {
                AssistanceView(palette: palette)
                    .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    pageAction("Browser history", symbol: "clock.arrow.circlepath") {
                        downloads.closePanel()
                        if assistant.panel != nil { assistant.closePanel() }
                        workspace.pageHistoryOpen.toggle()
                    }
                    .accessibilityIdentifier("page-history-button")
                    .help("Browser history")

                    pageAction("Downloads", symbol: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle") {
                        workspace.pageHistoryOpen = false
                        if assistant.panel != nil { assistant.closePanel() }
                        downloads.togglePanel()
                    }
                    .overlay(alignment: .topTrailing) {
                        if downloads.unreadCount > 0 {
                            Circle().fill(.red).frame(width: 7, height: 7).offset(x: -7, y: 7)
                        }
                    }
                    .accessibilityLabel(downloads.activeCount == 0 ? "Downloads" : "Downloads, \(downloads.activeCount) active")
                    .accessibilityIdentifier("downloads-button")
                    .help("Downloads · ⌘J")

                    nativeShareAction
                }
                .padding(.horizontal, 0)
                .transition(.opacity)
            }
        }
        .frame(width: width, height: height, alignment: .topTrailing)
        .foregroundStyle(palette.text)
        .modifier(PageGlass(radius: 14))
        .onExitCommand(perform: closePanel)
        .animation(reduceMotion ? nil : Metrics.morph, value: width)
        .animation(reduceMotion ? nil : Metrics.morph, value: height)
        .animation(reduceMotion ? nil : Metrics.morph, value: downloads.panelOpen)
        .animation(reduceMotion ? nil : Metrics.morph, value: sharing)
        .animation(reduceMotion ? nil : Metrics.morph, value: historyOpen)
    }

    private func pageAction(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var nativeShareAction: some View {
        if let url = browser?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pointing)
            .accessibilityLabel("Share page")
            .accessibilityIdentifier("share-page-button")
            .help("Share this page")
        } else {
            pageAction("Share page", symbol: "square.and.arrow.up") { }
                .disabled(true)
                .accessibilityIdentifier("share-page-button")
                .help("This page cannot be shared")
        }
    }

    private func closePanel() {
        if historyOpen { workspace.pageHistoryOpen = false }
        else if downloads.panelOpen { downloads.closePanel() }
        else if sharing { assistant.closePanel() }
    }
}

private struct PageHistoryPanel: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolboxPanelHeader(title: "History", close: close)
            if workspace.browserHistory.visits.isEmpty {
                Text("No history")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textDim)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(workspace.browserHistory.visits) { visit in
                            historyRow(visit)
                        }
                    }
                }
            }
        }
        .buttonStyle(.pointing)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func historyRow(_ visit: BrowserHistoryVisit) -> some View {
        Button { workspace.openHistoryVisit(visit) } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textDim)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(visit.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(visit.host)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Open \(visit.title), \(visit.host)")
        .contextMenu {
            Button("Remove from History") { workspace.browserHistory.remove(visit.id) }
        }
    }
}

private struct DownloadsPanel: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette
    private var downloads: DownloadCenter { workspace.downloads }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                if downloads.records.contains(where: { !$0.state.isActive }) {
                    Button("Clear", action: downloads.clearFinished)
                        .font(.system(size: 10))
                }
                Button(action: downloads.closePanel) {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .accessibilityLabel("Close Downloads")
            }

            if downloads.records.isEmpty {
                Text("No downloads")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textDim)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(downloads.records) { record in
                            DownloadRow(record: record, palette: palette)
                        }
                    }
                }
            }
        }
        .buttonStyle(.pointing)
        .foregroundStyle(palette.text)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DownloadRow: View {
    @Environment(Workspace.self) private var workspace
    var record: DownloadRecord
    var palette: Palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.filename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(record.origin)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(1)
                if record.state == .downloading {
                    if let fraction = record.fractionCompleted {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(progressLabel)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(palette.textDim)
                } else if let message = record.message {
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                }
                if let destination = record.destination {
                    Text(destination.deletingLastPathComponent().path)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.textDim)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if record.state.isActive {
                Button { workspace.downloads.cancel(record.id) } label: {
                    Image(systemName: "xmark.circle").frame(width: 24, height: 24)
                }
                .accessibilityLabel("Cancel \(record.filename)")
            } else if record.canReveal {
                Button { workspace.downloads.reveal(record.id) } label: {
                    Image(systemName: "folder").frame(width: 24, height: 24)
                }
                .accessibilityLabel("Reveal \(record.filename) in Finder")
            }
        }
        .padding(8)
        .background(palette.hover, in: RoundedRectangle(cornerRadius: 9))
    }

    private var icon: String {
        switch record.state {
        case .choosingDestination, .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled, .interrupted: return "pause.circle"
        }
    }

    private var iconColor: Color {
        switch record.state {
        case .completed: return .green
        case .failed: return .red
        default: return palette.textDim
        }
    }

    private var progressLabel: String {
        let received = ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file)
        guard let expected = record.expectedBytes else { return received }
        return "\(received) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
    }
}

private struct ToolboxReadingPanel: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette
    private var assistant: BrowserAssistance { workspace.assistance }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolboxPanelHeader(title: "Critical Reading", close: assistant.closePanel)
            HStack(spacing: 8) {
                if assistant.busy { ProgressView().controlSize(.small) }
                Text(assistant.status)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(3)
            }
        }
        .buttonStyle(.pointing)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ToolboxPanelHeader: View {
    var title: String
    var close: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }
            .accessibilityLabel("Close \(title)")
        }
    }
}

/// Per-site switches for the built-in blocker and dark pages.
struct BuiltInRows: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette

    var body: some View {
        let builtIns = workspace.builtIns
        let url = workspace.currentPageURL
        let blocking = builtIns.blocks(url)
        let dark = builtIns.darkens(url)
        VStack(spacing: 0) {
            Button { builtIns.setBlocking(!blocking, for: url) } label: {
                ToolboxRowLabel(title: "Ad blocking",
                                symbol: blocking ? "shield.lefthalf.filled" : "shield.slash", shortcut: "",
                                detail: builtIns.blockingEnabled && blocking ? "On" : "Off",
                                count: workspace.activePane.flatMap { builtIns.blockedCounts[$0] } ?? 0,
                                accent: palette.accent)
            }
            .disabled(url == nil || !builtIns.blockingEnabled)
            .accessibilityIdentifier("toolbox-blocking-button")
            Button { builtIns.setDarkening(!dark, for: url) } label: {
                ToolboxRowLabel(title: "Dark Page",
                                symbol: dark ? "moon.fill" : "moon", shortcut: "",
                                detail: dark ? "On" : "Off")
            }
            .disabled(url == nil || builtIns.darkMode == .off)
            .accessibilityIdentifier("toolbox-dark-button")
        }
        .buttonStyle(.pointing)
        .font(.system(size: 12, weight: .medium))
    }
}

struct PageTools: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    private var assistant: BrowserAssistance { workspace.assistance }
    private var open: Bool { assistant.panel == .find }
    var body: some View {
        @Bindable var assistant = assistant
        VStack(spacing: 0) {
            if open {
                HStack(spacing: 8) {
                    findButton
                    WorkInput(text: $assistant.query, placeholder: "Find…", identifier: "page-find", fontSize: 12,
                              palette: palette, submit: { assistant.moveMatch(1) }, cancel: assistant.closePanel,
                              moveSelection: assistant.moveMatch)
                        .frame(minWidth: 70, maxWidth: .infinity).frame(height: 24)
                        .onChange(of: assistant.query) { _, _ in assistant.findChanged() }
                    Group {
                        if assistant.busy { ProgressView().controlSize(.mini) }
                        else if !assistant.matches.isEmpty { Text("\(assistant.matchIndex + 1)/\(assistant.matches.count)").monospacedDigit() }
                        else { Text(assistant.exactMatched ? "✓" : "0") }
                    }.font(.system(size: 10)).foregroundStyle(palette.textDim).frame(minWidth: 26)
                        .help(assistant.status).accessibilityLabel(assistant.status)
                    Button { assistant.moveMatch(-1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 30) }
                        .accessibilityLabel("Previous match")
                    Button { assistant.moveMatch(1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 30) }
                        .accessibilityLabel("Next match")
                    Button(action: assistant.closePanel) { Image(systemName: "xmark").frame(width: 22, height: 30) }
                        .accessibilityLabel("Close find")
                }
                .frame(height: 40)
            } else {
                findButton
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }

            toolboxButton(assistant.savedInVault ? "Update Vault" : "Save to Vault",
                          symbol: assistant.savedInVault ? "archivebox.fill" : "archivebox", shortcut: .vault,
                          action: assistant.saveToVault)
                .accessibilityLabel(assistant.savedInVault ? "Update saved page in Vault" : "Save page to Vault")
                .help(assistant.vaultStatus.isEmpty ? "Save page to Vault" : assistant.vaultStatus)
                .accessibilityIdentifier("page-vault-button")
            if assistant.criticalReadingMode == .onRequest {
                toolboxButton("Critical Reading", symbol: "text.magnifyingglass", shortcut: .reading) {
                    workspace.downloads.closePanel()
                    assistant.panel == .reading ? assistant.closePanel() : assistant.openReading()
                }
                .accessibilityLabel("Critical reading")
                .accessibilityIdentifier("page-reading-button")
                .help(assistant.panel == .reading ? assistant.status : "Review wording in this page")
            }
        }
        .buttonStyle(.pointing)
        .font(.system(size: 12, weight: .medium))
        .frame(maxWidth: .infinity)
        .foregroundStyle(palette.text)
        .onChange(of: assistant.byMeaning) { _, _ in assistant.findChanged() }
        .animation(reduceMotion ? nil : Metrics.morph, value: open)
        .animation(reduceMotion ? nil : Metrics.morph, value: assistant.criticalReadingMode)
    }

    private var findButton: some View {
        Button {
            workspace.downloads.closePanel()
            open ? assistant.closePanel() : assistant.openFind()
        } label: {
            if open {
                Label("Find for me", systemImage: "magnifyingglass")
                    .labelStyle(ToolboxLabelStyle())
                    .padding(.leading, 12)
                    .frame(width: 124, alignment: .leading)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            } else {
                ToolboxRowLabel(
                    title: "Find for me",
                    symbol: "magnifyingglass",
                    shortcut: workspace.toolboxShortcutLabel(.find)
                )
            }
        }
        .accessibilityLabel("Find for me")
        .help("Find in page · ⌘F")
        .accessibilityIdentifier("page-search-button")
        .contextMenu {
            Toggle("Match by meaning with Jev", isOn: Binding(
                get: { assistant.byMeaning },
                set: { assistant.byMeaning = $0 }
            ))
            Button("Exact text only") { assistant.byMeaning = false; assistant.findChanged() }
        }
    }

    private func toolboxButton(_ title: String, symbol: String, shortcut: ToolboxShortcut,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolboxRowLabel(
                title: title,
                symbol: symbol,
                shortcut: workspace.toolboxShortcutLabel(shortcut)
            )
        }
    }
}

private struct ToolboxRowLabel: View {
    var title: String
    var symbol: String
    var shortcut: String
    var detail: String? = nil
    var count = 0
    var accent: Color = .clear

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .frame(width: 24)
            Text(title)
                .padding(.leading, 10)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(minWidth: 24, alignment: .trailing)
                }
                ToolboxShortcutLabel(shortcut)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ToolboxShortcutLabel: View {
    var shortcut: String

    init(_ shortcut: String) {
        self.shortcut = shortcut
    }

    var body: some View {
        Text(shortcut)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
    }
}

private struct ToolboxLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 24)
            configuration.title
        }
    }
}
