import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Temporary tools grow inside the existing page handle.
struct AssistanceView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openSettings) private var openSettings
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
                Text("Jev uses OpenRouter and TypeSafe to evaluate this page's title, description, labels, and readable page text for each search or reading check. Form fields, password pages, and cookies are excluded. A grant covers this site origin. Sharing this visit ends when you quit; remembering the site keeps the grant until you revoke it.")
                Text("Interlinked can't tell whether you're signed in. If you are, this page's text, including messages, account details, or balances shown on it, goes to Jev too.")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(red: 0.82, green: 0.38, blue: 0.08))
                Text("Only share content you are comfortable sending. OpenRouter's policy is that requests are anonymized and not used for training. You still accept the risk that a third party will see this page's text.").foregroundStyle(.primary)
                if !assistant.enabled || !assistant.hasJevAccess {
                    Button("Configure Jev in Settings…") {
                        workspace.settingsDestination = .intelligence
                        openSettings()
                    }
                    .buttonStyle(.link)
                    .pointingHandCursor()
                }
                if !assistant.canShare {
                    Text("Local, editable, and password pages cannot be shared.").foregroundStyle(.primary)
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
    private var menuWidth: CGFloat { assistant.panel == .find ? 400 : 250 }
    private var menuRows: CGFloat {
        CGFloat(assistant.criticalReadingMode == .onRequest ? 3 : 2)
    }
    private var collapsedWidth: CGFloat { workspace.sharingScreenMode ? 136 : 108 }
    private var width: CGFloat {
        if assistant.readingPanelOpen { return 340 }
        return expanded ? menuWidth : collapsedWidth
    }
    private var height: CGFloat {
        if assistant.readingPanelOpen { return 176 }
        return expanded ? 44 + menuRows * 40 : 44
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if assistant.readingPanelOpen {
                ToolboxReadingPanel(palette: palette)
                    .transition(.opacity)
            } else {
                if expanded {
                    PageTools(palette: palette)
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
                        if workspace.sharingScreenMode {
                            // Always visible while it is on, so it is never forgotten.
                            Image(systemName: "eye.slash.fill")
                                .foregroundStyle(palette.accent)
                                .frame(width: 28, height: 44)
                                .padding(.leading, 8)
                                .help("Sharing Screen Mode is on · ⇧⌘S")
                        }
                        Image(systemName: "wrench.and.screwdriver")
                            .frame(width: workspace.sharingScreenMode ? 28 : 44, height: 44)
                        Text("Toolbox")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.leading, workspace.sharingScreenMode ? 6 : 0)
                            .padding(.trailing, 16)
                    }
                    .frame(width: collapsedWidth, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(workspace.sharingScreenMode ? "Toolbox, Sharing Screen Mode on" : "Toolbox")
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

/// The page-sharing request appears top right. History and downloads open
/// from the page handle and morph it instead.
struct PageActions: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    var available: CGSize
    private var assistant: BrowserAssistance { workspace.assistance }
    private var sharing: Bool { assistant.panel == .permission }

    var body: some View {
        ZStack {
            if sharing {
                AssistanceView(palette: palette)
                    .frame(width: min(370, available.width - 36), height: min(335, available.height - 36))
                    .foregroundStyle(palette.text)
                    .modifier(PageGlass(radius: 14))
                    .onExitCommand(perform: assistant.closePanel)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Metrics.morph, value: sharing)
    }
}

struct PageHistoryPanel: View {
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

struct DownloadsPanel: View {
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
            Text("Sends this page's readable text to Jev, including anything shown while you're signed in.")
                .font(.system(size: 10))
                .foregroundStyle(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
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

            if assistant.criticalReadingMode == .onRequest {
                toolboxButton("Critical Reading", symbol: "text.magnifyingglass", shortcut: .reading) {
                    workspace.downloads.closePanel()
                    assistant.panel == .reading ? assistant.closePanel() : assistant.openReading()
                }
                .accessibilityLabel("Critical reading")
                .accessibilityIdentifier("page-reading-button")
                .help(assistant.panel == .reading ? assistant.status : "Review wording in this page")
            }

            toolboxButton(workspace.sharingScreenMode ? "Sharing Screen Mode On" : "Sharing Screen Mode",
                          symbol: workspace.sharingScreenMode ? "eye.slash.fill" : "eye.slash",
                          shortcut: .sharingScreen) {
                workspace.sharingScreenMode.toggle()
            }
            .foregroundStyle(workspace.sharingScreenMode ? palette.accent : palette.text)
            .accessibilityLabel(workspace.sharingScreenMode ? "Turn off Sharing Screen Mode" : "Turn on Sharing Screen Mode")
            .accessibilityIdentifier("toolbox-sharing-screen-button")
            .help("Blur emails, phone numbers, card and document numbers, keys, and passwords on every page")
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

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .frame(width: 24)
            Text(title)
                .padding(.leading, 10)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            ToolboxShortcutLabel(shortcut)
                .frame(width: 28, alignment: .trailing)
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
