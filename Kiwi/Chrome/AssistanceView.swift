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
                if !assistant.enabled || !assistant.hasKey {
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
                        .disabled(!assistant.canShare || !assistant.enabled || !assistant.hasKey)
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
        Form {
            Section("Jev") {
                Toggle("Enable Jev tools", isOn: $assistant.enabled)
                    .onChange(of: assistant.enabled) { _, _ in assistant.configure() }
                Text("Critical reading, meaning search, and Vault description searches send page or saved text through OpenRouter and TypeSafe. Normal browsing and exact find work locally.")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("OpenRouter API key", text: $key)
                    .textContentType(.password)
                    .accessibilityIdentifier("openrouter-key")
                HStack {
                    Button("Save key") {
                        do { try JevCredential.save(key); key = ""; assistant.configure(); message = "Key saved in macOS Keychain." }
                        catch { message = "Couldn't save the key to Keychain." }
                    }.disabled(key.isEmpty)
                    Button("Remove key") { JevCredential.remove(); assistant.configure(); message = "Key removed." }
                }
                Text(message.isEmpty ? (assistant.hasKey ? "A key is saved in Keychain." : "No API key saved.") : message)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Reading checks assess wording and can be wrong. Meaning matches and related pages are suggestions. Inspect the original text before relying on them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Critical reading") {
                Picker("Run", selection: $assistant.criticalReadingMode) {
                    ForEach(CriticalReadingMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .onChange(of: assistant.criticalReadingMode) { _, _ in assistant.configure() }
                Text(assistant.criticalReadingMode == .automatic
                    ? "Checks each public page after it loads and marks possible wording signals. Local, editable, and password pages stay on this Mac."
                    : "Checks a page only when you choose Critical reading from the page controls or Page menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Page labels") {
                Toggle("Refine public page labels with Jev", isOn: $assistant.automaticLabels)
                    .onChange(of: assistant.automaticLabels) { _, _ in assistant.configure() }
                Text("Sends public page titles, descriptions and locally generated label candidates automatically. Full page text and URL queries are excluded. Keep this off for local labels only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Vault") {
                Text("The Vault button saves a page's URL, title and selected text on this Mac. Pages are saved only when you ask. Description search sends relevant saved excerpts to Jev. Images and form contents are not recorded.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(assistant.history.visits.count) saved pages")
                    Spacer()
                    Button("Clear Vault", role: .destructive, action: assistant.clearHistory)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 490, height: 650)
    }
}


struct PageTools: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    var palette: Palette
    private var assistant: BrowserAssistance { workspace.assistance }
    private var open: Bool { assistant.panel == .find }
    var body: some View {
        @Bindable var assistant = assistant
        HStack(spacing: 4) {
            Button { open ? assistant.closePanel() : assistant.openFind() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                }.frame(width: 36, height: 32).contentShape(Rectangle())
            }.accessibilityLabel("Find for me").help("Find in page · ⌘F").accessibilityIdentifier("page-search-button")
                .contextMenu {
                    Toggle("Match by meaning with Jev", isOn: $assistant.byMeaning)
                    Button("Exact text only") { assistant.byMeaning = false; assistant.findChanged() }
                }
                .overlay(alignment: .bottomTrailing) { hint("Find for me", id: "find") }
                .onHover { hovered = $0 ? "find" : nil }
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
            }
            Button(action: assistant.saveToVault) {
                HStack(spacing: 7) {
                    Image(systemName: assistant.savedInVault ? "archivebox.fill" : "archivebox")
                }.frame(width: 36, height: 32).contentShape(Rectangle())
            }.accessibilityLabel(assistant.savedInVault ? "Update saved page in Vault" : "Save page to Vault")
                .help(assistant.vaultStatus.isEmpty ? "Save page to Vault" : assistant.vaultStatus)
                .accessibilityIdentifier("page-vault-button")
                .overlay(alignment: .bottomTrailing) { hint("Might need later", id: "vault") }
                .onHover { hovered = $0 ? "vault" : nil }
            Button {
                assistant.panel == .reading ? assistant.closePanel() : assistant.openReading()
            } label: {
                HStack(spacing: 7) {
                    if assistant.panel == .reading && assistant.busy {
                        ProgressView().controlSize(.mini)
                    } else { Image(systemName: "text.magnifyingglass") }
                }.frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Critical reading")
            .accessibilityIdentifier("page-reading-button")
            .help(assistant.panel == .reading ? assistant.status : "Review wording in this page")
            .overlay(alignment: .bottomTrailing) { hint("Critical reading", id: "reading") }
            .onHover { hovered = $0 ? "reading" : nil }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 4)
        .frame(width: open ? 400 : 124, height: 40)
        .foregroundStyle(palette.text)
        .modifier(PageGlass(radius: 14))
        .onChange(of: assistant.byMeaning) { _, _ in assistant.findChanged() }
        .animation(reduceMotion ? nil : Metrics.morph, value: open)
    }

    @ViewBuilder private func hint(_ title: String, id: String) -> some View {
        if hovered == id {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(palette.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.hairline))
                .fixedSize()
                .offset(y: -40)
                .allowsHitTesting(false)
        }
    }
}
