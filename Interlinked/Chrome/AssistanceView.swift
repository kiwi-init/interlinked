import SwiftUI

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
                    .buttonStyle(.plain).accessibilityLabel("Close page tool")
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
                        .onChange(of: assistant.byMeaning) { _, _ in assistant.findChanged() }
                    Spacer()
                    Button { assistant.moveMatch(-1) } label: { Image(systemName: "chevron.up") }
                        .accessibilityLabel("Previous match")
                    Button { assistant.moveMatch(1) } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Next match")
                }
                if assistant.byMeaning {
                    Text("Jev searches page text. Matches are highlighted in yellow.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(assistant.status).foregroundStyle(.secondary).lineLimit(3)
            case .reading: EmptyView()
            case .permission:
                Text(assistant.origin.isEmpty ? "Page unavailable" : assistant.origin).lineLimit(1).fontWeight(.medium)
                Text("Jev uses OpenRouter and TypeSafe to evaluate this page's title, description, labels, and readable page text for each search or reading check. Forms and passwords are excluded. Sharing ends on navigation or reload.")
                Text("Only share content you are comfortable sending. This does not enable sharing for other tabs.").foregroundStyle(.secondary)
                if !assistant.enabled || !assistant.hasJevAccess {
                    SettingsLink { Text("Configure Jev in Settings…") }
                }
                if !assistant.canShare {
                    Text("Local, editable, and password pages cannot be shared.").foregroundStyle(.secondary)
                }
                Text(assistant.status).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", action: assistant.closePanel)
                    Spacer()
                    Button("Share this page", action: assistant.allowPage)
                        .disabled(!assistant.canShare || !assistant.enabled || !assistant.hasJevAccess)
                        .accessibilityIdentifier("allow-page-sharing")
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

struct AssistanceSettings: View {
    @Environment(Workspace.self) private var workspace
    @State private var key = ""
    @State private var message = ""

    var body: some View {
        @Bindable var assistant = workspace.assistance
        TabView {
            generalSettings(assistant)
                .tabItem { Label("General", systemImage: "gearshape") }
            accessSettings(assistant)
                .tabItem { Label("Jev Access", systemImage: "key") }
            dataSettings(assistant)
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .padding(.top, 8)
        .frame(width: 620, height: 500)
    }

    private func generalSettings(_ assistant: BrowserAssistance) -> some View {
        @Bindable var assistant = assistant
        return Form {
            Section("Jev") {
                Toggle("Enable Jev", isOn: $assistant.enabled)
                    .onChange(of: assistant.enabled) { _, _ in assistant.configure() }
                SettingsNote("Jev powers meaning search and Critical Reading, and backs up Apple Intelligence where available.")
            }

            Section("Critical Reading") {
                Picker("Run", selection: $assistant.criticalReadingMode) {
                    ForEach(CriticalReadingMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.menu)
                .onChange(of: assistant.criticalReadingMode) { _, _ in assistant.configure() }
                SettingsNote(assistant.criticalReadingMode == .automatic
                    ? "Checks public pages after they load. Private and editable pages stay on this Mac."
                    : "Runs only when you choose Critical Reading from the Toolbox or Page menu.")
            }

            Section("Page labels") {
                Toggle("Refine public page labels with AI", isOn: $assistant.automaticLabels)
                    .onChange(of: assistant.automaticLabels) { _, _ in assistant.configure() }
                SettingsNote("Uses Apple Intelligence when available, then Jev as a fallback. Full page text is not included.")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    private func accessSettings(_ assistant: BrowserAssistance) -> some View {
        Form {
            Section("OpenRouter") {
                if assistant.usesIncludedJev {
                    Label("Jev access is included with this build", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    LabeledContent("API key") {
                        SecureField("Paste key", text: $key)
                            .textContentType(.password)
                            .frame(width: 300)
                            .accessibilityIdentifier("openrouter-key")
                    }
                    HStack {
                        Spacer()
                        Button("Remove Key", role: .destructive) {
                            JevCredential.remove()
                            assistant.configure()
                            message = "Key removed."
                        }
                        .disabled(!assistant.hasKey)
                        Button("Save Key") { saveKey(assistant) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Label(keyStatus(assistant), systemImage: assistant.hasKey ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.callout)
                        .foregroundStyle(assistant.hasKey ? .green : .secondary)
                }
            }

            Section("Used for") {
                SettingsFeature(icon: "text.magnifyingglass", title: "Meaning search", detail: "Find passages by intent, not only exact words.")
                SettingsFeature(icon: "checkmark.shield", title: "Critical Reading", detail: "Review wording and surface passages worth a second look.")
                SettingsFeature(icon: "tag", title: "Page labels", detail: "Create clearer labels from public page metadata.")
            }

            SettingsNote("The key is stored in macOS Keychain and is never written to app preferences.")
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    private func dataSettings(_ assistant: BrowserAssistance) -> some View {
        Form {
            Section("AI cache") {
                LabeledContent("Recent decisions") {
                    Button("Clear Cache", action: assistant.clearDecisionCache)
                }
                SettingsNote("Interlinked keeps identical Jev decisions on this Mac for five days.")
                if !assistant.cacheStatus.isEmpty {
                    Text(assistant.cacheStatus).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Vault") {
                LabeledContent("Saved pages", value: "\(assistant.history.visits.count)")
                HStack {
                    SettingsNote("Pages enter the Vault only when you save them.")
                    Spacer()
                    Button("Clear Vault", role: .destructive, action: assistant.clearHistory)
                        .disabled(assistant.history.visits.isEmpty)
                }
                SettingsNote("Address searches try Apple Intelligence locally first. If it is unavailable, Jev may receive relevant saved excerpts.")
            }

            Section("Privacy") {
                SettingsFeature(icon: "lock", title: "Sensitive pages stay local", detail: "Passwords, forms, local files, and editable pages are not shared.")
                SettingsFeature(icon: "eye", title: "You stay in control", detail: "Meaning results and reading checks are suggestions. Review the source before relying on them.")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    private func saveKey(_ assistant: BrowserAssistance) {
        do {
            try JevCredential.save(key)
            key = ""
            assistant.configure()
            message = "Saved in macOS Keychain."
        } catch {
            message = "Couldn’t save the key."
        }
    }

    private func keyStatus(_ assistant: BrowserAssistance) -> String {
        if !message.isEmpty { return message }
        return assistant.hasKey ? "Saved in macOS Keychain" : "No key saved"
    }
}

private struct SettingsNote: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct Toolbox: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var palette: Palette
    private var assistant: BrowserAssistance { workspace.assistance }
    private var expanded: Bool {
        hovering || workspace.commandKeyHeld || assistant.filterPanelOpen || assistant.panel == .find || assistant.readingPanelOpen
    }
    private var menuWidth: CGFloat { assistant.panel == .find ? 400 : 190 }
    private var menuRows: CGFloat { assistant.criticalReadingMode == .onRequest ? 4 : 3 }
    private var width: CGFloat {
        if assistant.filterPanelOpen || assistant.readingPanelOpen { return 340 }
        return expanded ? menuWidth : 108
    }
    private var height: CGFloat {
        if assistant.filterPanelOpen { return 300 }
        if assistant.readingPanelOpen { return 150 }
        return expanded ? 44 + menuRows * 40 : 44
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if assistant.filterPanelOpen {
                PersonalFilterPanel(palette: palette)
                    .transition(.opacity)
            } else if assistant.readingPanelOpen {
                ToolboxReadingPanel(palette: palette)
                    .transition(.opacity)
            } else {
                if expanded {
                    VStack(spacing: 0) {
                        PersonalFilterButton(palette: palette)
                        PageTools(palette: palette)
                    }
                    .frame(width: menuWidth)
                    .padding(.bottom, 44)
                    .transition(.opacity)
                }

                if expanded {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(ToolboxLabelStyle())
                            .padding(.horizontal, 12)
                            .frame(width: menuWidth, height: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                    .accessibilityHint("Hover or hold Command to show page tools")
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
        .animation(reduceMotion ? nil : Metrics.morph, value: assistant.filterPanelOpen)
        .animation(reduceMotion ? nil : Metrics.morph, value: assistant.appliedFilterCount)
    }

    private func closeActivePanel() {
        if assistant.filterPanelOpen { assistant.closeFilters() }
        else if assistant.panel != nil { assistant.closePanel() }
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
        .buttonStyle(.plain)
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

private struct PersonalFilterButton: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette
    private var assistant: BrowserAssistance { workspace.assistance }

    var body: some View {
        Button {
            assistant.filterPanelOpen ? assistant.closeFilters() : assistant.openFilters()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease")
                    .frame(width: 24)
                    .overlay(alignment: .topTrailing) {
                        if assistant.appliedFilterCount > 0 {
                            Circle().fill(palette.accent).frame(width: 7, height: 7).offset(x: 3, y: -3)
                        }
                    }
                Text("Personal Filters")
                Spacer(minLength: 0)
                if assistant.appliedFilterCount > 0 {
                    Text("\(assistant.appliedFilterCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textDim)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.text)
        .accessibilityLabel("Personal Filters")
        .accessibilityValue(assistant.appliedFilterCount == 0 ? "No page items hidden" : "\(assistant.appliedFilterCount) page items hidden")
        .accessibilityIdentifier("personal-filter-button")
        .help(assistant.appliedFilterCount == 0 ? "Personal Filters" : "\(assistant.appliedFilterCount) page items hidden")
    }
}

private struct PersonalFilterPanel: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette
    private var assistant: BrowserAssistance { workspace.assistance }

    var body: some View {
        @Bindable var assistant = assistant
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Personal Filters").font(.system(size: 13, weight: .semibold))
                    Text(assistant.currentFilterHost.isEmpty ? "Open a website" : assistant.currentFilterHost)
                        .font(.system(size: 10)).foregroundStyle(palette.textDim)
                }
                Spacer()
                if assistant.filterBusy { ProgressView().controlSize(.mini) }
                Button(action: assistant.closeFilters) {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }.accessibilityLabel("Close Personal Filters")
            }

            if assistant.currentFilters.isEmpty {
                Text("No filters on this site.")
                    .font(.system(size: 11)).foregroundStyle(palette.textDim)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(assistant.currentFilters) { rule in
                            HStack(alignment: .top, spacing: 8) {
                                Button { assistant.togglePersonalFilter(rule.id) } label: {
                                    Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(rule.isEnabled ? palette.accent : palette.textDim)
                                        .frame(width: 20, height: 20)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.description).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                    let count = assistant.filterCount(rule.id)
                                    Text(count == 1 ? "1 page item hidden" : "\(count) page items hidden")
                                        .font(.system(size: 9)).foregroundStyle(palette.textDim)
                                }
                                Spacer(minLength: 4)
                                Button { assistant.removePersonalFilter(rule.id) } label: {
                                    Image(systemName: "trash").frame(width: 20, height: 20)
                                }.accessibilityLabel("Delete filter")
                            }
                            .padding(8)
                            .background(palette.hover, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }.frame(maxHeight: 150)
            }

            HStack(spacing: 6) {
                WorkInput(text: $assistant.filterDraft, placeholder: "Describe something to hide…",
                          identifier: "personal-filter-input", fontSize: 11, palette: palette,
                          submit: assistant.addPersonalFilter, cancel: assistant.closeFilters)
                    .frame(height: 25)
                Button(action: assistant.addPersonalFilter) {
                    Image(systemName: "arrow.up").frame(width: 28, height: 28)
                        .background(palette.hover, in: Circle())
                }
                .disabled(assistant.filterDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add Personal Filter")
            }
            Text(assistant.filterStatus.isEmpty ? "Saved on this Mac and applied only to this site." : assistant.filterStatus)
                .font(.system(size: 9)).foregroundStyle(palette.textDim).lineLimit(2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.text)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            HStack(spacing: 8) {
                Button { open ? assistant.closePanel() : assistant.openFind() } label: {
                    Label("Find for me", systemImage: "magnifyingglass")
                        .labelStyle(ToolboxLabelStyle())
                        .padding(.leading, 12)
                        .frame(width: 124, height: 40, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Find for me").help("Find in page · ⌘F").accessibilityIdentifier("page-search-button")
                .contextMenu {
                    Toggle("Match by meaning with Jev", isOn: $assistant.byMeaning)
                    Button("Exact text only") { assistant.byMeaning = false; assistant.findChanged() }
                }
                if open {
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
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 40)

            toolboxButton(assistant.savedInVault ? "Update Vault" : "Save to Vault",
                          symbol: assistant.savedInVault ? "archivebox.fill" : "archivebox",
                          action: assistant.saveToVault)
                .accessibilityLabel(assistant.savedInVault ? "Update saved page in Vault" : "Save page to Vault")
                .help(assistant.vaultStatus.isEmpty ? "Save page to Vault" : assistant.vaultStatus)
                .accessibilityIdentifier("page-vault-button")
            if assistant.criticalReadingMode == .onRequest {
                toolboxButton("Critical Reading", symbol: "text.magnifyingglass") {
                    assistant.panel == .reading ? assistant.closePanel() : assistant.openReading()
                }
                .accessibilityLabel("Critical reading")
                .accessibilityIdentifier("page-reading-button")
                .help(assistant.panel == .reading ? assistant.status : "Review wording in this page")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .frame(maxWidth: .infinity)
        .foregroundStyle(palette.text)
        .onChange(of: assistant.byMeaning) { _, _ in assistant.findChanged() }
        .animation(reduceMotion ? nil : Metrics.morph, value: open)
        .animation(reduceMotion ? nil : Metrics.morph, value: assistant.criticalReadingMode)
    }

    private func toolboxButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(ToolboxLabelStyle())
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
        }
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
