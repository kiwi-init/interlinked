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
                Text(assistant.panel == .find ? "Find in page" : "Share this page")
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
            case .permission:
                Text(assistant.origin.isEmpty ? "Page unavailable" : assistant.origin).lineLimit(1).fontWeight(.medium)
                Text("Jev uses OpenRouter and TypeSafe to evaluate this page's title, description, labels, and readable page text for each search. Form fields, password pages, and cookies are excluded. A grant covers this site origin. Sharing this visit ends when you quit; remembering the site keeps the grant until you revoke it.")
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

/// The page-sharing request appears top right, under the page's header. History
/// and downloads open in the sidebar instead.
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
            if workspace.historyClearing {
                PanelHeader(title: "Clear History") { workspace.historyClearing = false }
                VStack(spacing: 4) {
                    ForEach(HistoryRange.allCases) { range in
                        clearRow(range)
                    }
                }
                Spacer(minLength: 0)
            } else {
                HStack {
                    Text("History").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !workspace.browserHistory.visits.isEmpty {
                        Button("Clear…", action: workspace.beginClearingHistory)
                            .font(.system(size: 10))
                            .accessibilityIdentifier("history-clear")
                    }
                    Button(action: close) {
                        Image(systemName: "xmark").frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Close History")
                }
                if workspace.browserHistory.visits.isEmpty {
                    Text(workspace.browserHistory.enabled ? "No history" : "History is off in Settings")
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
        }
        .buttonStyle(.pointing)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func clearRow(_ range: HistoryRange) -> some View {
        Button { workspace.clearHistory(range) } label: {
            Text(range.title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Clear \(range.title.lowercased())")
        .accessibilityIdentifier("history-clear-\(range.rawValue)")
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
            if !visit.host.isEmpty {
                Button("Remove All from \(visit.host)") { workspace.browserHistory.removeSite(visit.host) }
            }
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

private struct PanelHeader: View {
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
