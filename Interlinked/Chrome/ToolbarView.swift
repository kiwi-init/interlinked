import AppKit
import SwiftUI

/// One continuous shape holds the icon, address, open work, and voice feedback.
struct PageHandle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    var available: CGSize
    private var hovering: Bool { workspace.quickSwitchOpen || workspace.leftCommandKeyHeld }
    private var isNewTab: Bool { workspace.isEmptyActivePage }

    private var pane: PaneID? { workspace.activePane }
    private var downloads: DownloadCenter { workspace.downloads }
    private var historyOpen: Bool { workspace.pageHistoryOpen && workspace.editing == nil }
    private var downloadsOpen: Bool { downloads.panelOpen && workspace.editing == nil }
    /// States that replace the handle's contents with a panel above its bar.
    private var morphed: Bool { workspace.overviewOpen || workspace.identityOpen || historyOpen || downloadsOpen }
    private var expanded: Bool { morphed || hovering || workspace.editing != nil || isNewTab }
    private var showsTabs: Bool {
        PageHandleExpansion.showsOpenWork(
            overviewOpen: workspace.overviewOpen,
            panelOpen: workspace.identityOpen || historyOpen || downloadsOpen,
            hovering: hovering,
            editing: workspace.editing != nil,
            isNewTab: isNewTab,
            voiceActive: voiceCaption != nil
        )
    }
    private var trustedOrigin: TrustedOrigin? { workspace.currentPageURL.flatMap(TrustedOrigin.inspect) }
    private var identity: String {
        guard let pane else { return "All tabs" }
        if workspace.onboarding.contains(pane) { return Workspace.onboardingTitle }
        let label = workspace.assistance.label(pane, url: workspace.surfaces.line(pane))
        return label.isEmpty ? "Search or enter an address" : label
    }
    private var voiceCaption: String? {
        switch workspace.voice.state {
        case .idle: return nil
        case .starting: return "Starting microphone…"
        case .listening(let heard, _): return heard.isEmpty ? "Listening…" : heard
        case .finishing(let heard): return heard.isEmpty ? "Finishing…" : heard
        case .failed(let reason): return reason
        case .heard(let said, let outcome):
            switch outcome {
            case .refused(let reason): return reason
            case .notACommand: return "Command not recognized: \(said)"
            default: return said
            }
        }
    }
    private var overviewSize: CGSize {
        CGSize(width: min(560, available.width - 36), height: min(400, available.height - 72))
    }
    private var quickTabs: [Tab] { workspace.quickTabs }
    private var resultsHeight: CGFloat {
        let headings = Set(workspace.searchResults.map(\.source.label)).count
        return min(CGFloat(workspace.searchResults.count * 42 + headings * 22), max(84, available.height - 170))
    }
    private var tabsHeight: CGFloat {
        min(CGFloat(quickTabs.count * 42), max(0, available.height - 112 - resultsHeight - splitRowHeight))
    }
    private var splitRowHeight: CGFloat { workspace.isSplit ? 42 : 0 }
    private var controlsHeight: CGFloat { 32 + handleBarHeight + tabsHeight + splitRowHeight }
    private var historySize: CGSize {
        let count = workspace.historyClearing ? HistoryRange.allCases.count : workspace.browserHistory.visits.count
        let rows = CGFloat(count) * 44 + 58
        return CGSize(width: min(330, available.width - 36), height: min(max(140, rows) + 44, available.height - 72))
    }
    private var downloadsSize: CGSize {
        CGSize(width: min(390, available.width - 36), height: min(404, available.height - 72))
    }
    private var handleBarHeight: CGFloat {
        if morphed || workspace.editing != nil || voiceCaption != nil {
            return 44
        }
        return trustedOrigin == nil ? 44 : 52
    }
    private var identitySize: CGSize {
        CGSize(width: min(420, available.width - 36), height: min(248, available.height - 72))
    }
    private var size: CGSize {
        if workspace.overviewOpen { return overviewSize }
        if workspace.identityOpen { return identitySize }
        if historyOpen { return historySize }
        if downloadsOpen { return downloadsSize }
        if voiceCaption != nil { return CGSize(width: min(340, available.width - 36), height: 44) }
        if showsTabs {
            let address = workspace.editing?.text ?? pane.map { workspace.assistance.label($0, url: workspace.surfaces.line($0)) } ?? ""
            let text = address.isEmpty ? "Search or address" : address
            let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            let tabsWidth = quickTabs.map { tab in
                (workspace.title(tab) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 96
            }.max() ?? 0
            return CGSize(width: min(max(!workspace.searchResults.isEmpty ? 320 : 312, tabsWidth, textWidth + 76), available.width - 36),
                          height: controlsHeight + resultsHeight)
        }
        let labelWidth = (identity as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        if let origin = trustedOrigin {
            let originWidth = (origin.compactLabel as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width
            return CGSize(width: min(max(labelWidth, originWidth) + 78, 280, available.width - 36), height: 52)
        }
        return CGSize(width: min(labelWidth + 66, 240, available.width - 36), height: 44)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if showsTabs {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        browserControl("Back", symbol: "chevron.left", id: "browser-back") {
                            workspace.discardLine()
                            if let pane { workspace.hosts.existingBrowser(pane)?.goBack() }
                        }
                        .disabled(pane.map { !workspace.hosts.canGoBack[$0, default: false] } ?? true)
                        browserControl("Forward", symbol: "chevron.right", id: "browser-forward") {
                            workspace.discardLine()
                            if let pane { workspace.hosts.existingBrowser(pane)?.goForward() }
                        }
                        .disabled(pane.map { !workspace.hosts.canGoForward[$0, default: false] } ?? true)
                        Spacer(minLength: 0)
                        browserControl("Browser history", symbol: "clock.arrow.circlepath", id: "page-history-button",
                                       action: workspace.togglePageHistory)
                            .help("Browser history")
                        browserControl(downloads.activeCount == 0 ? "Downloads" : "Downloads, \(downloads.activeCount) active",
                                       symbol: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle",
                                       id: "downloads-button", action: workspace.toggleDownloads)
                            .overlay(alignment: .topTrailing) {
                                if downloads.unreadCount > 0 {
                                    Circle().fill(.red).frame(width: 6, height: 6).offset(x: -5, y: 5)
                                }
                            }
                            .help("Downloads · ⌘J")
                        shareControl
                        browserControl(workspace.isSplit ? "Move side page to its own tab" : "Split view",
                                       symbol: workspace.isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                                       id: "split-view-button", action: workspace.toggleSplitView)
                            .help(workspace.isSplit ? "Move the other page to its own tab · ⌘\\" : "Split view · ⌘\\")
                        browserControl("New page", symbol: "plus", id: "new-page", action: workspace.newPage)
                        browserControl("Close page", symbol: "xmark", id: "browser-close") {
                            workspace.discardLine()
                            workspace.closeActive()
                        }
                        .disabled(pane == nil)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 32)
                    if !quickTabs.isEmpty {
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                ForEach(Array(quickTabs.enumerated()), id: \.element.id) { index, tab in
                                    Button { workspace.selectWork(tab.id) } label: {
                                        HStack(spacing: 8) {
                                            if tab.isSplit && tab.name == nil {
                                                SplitTabLabel(tab: tab, palette: palette)
                                            } else {
                                                SiteIcon(pane: tab.active, palette: palette, framed: false)
                                                    .frame(width: 28, height: 28)
                                                Text(workspace.title(tab))
                                                    .font(.system(size: 12, weight: .medium))
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 8)
                                            if index < 9 {
                                                Text("⌘\(index + 1)")
                                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                                    .foregroundStyle(palette.textDim)
                                                    .monospacedDigit()
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .frame(height: 42)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.pointing)
                                    .id(tab.id)
                                    // Drop it on the page to open the two side by side.
                                    .onDrag { NSItemProvider.tab(tab.id) } preview: {
                                        Label(workspace.title(tab), systemImage: "rectangle.split.2x1")
                                            .font(.system(size: 12, weight: .medium))
                                            .padding(.horizontal, 12)
                                            .frame(height: 32)
                                            .background(.regularMaterial, in: Capsule())
                                    }
                                    .accessibilityLabel(index < 9 ? "Switch to \(workspace.title(tab)), Command \(index + 1)" : "Switch to \(workspace.title(tab))")
                                    .accessibilityHint("Drag onto the page to open it side by side")
                                    .accessibilityIdentifier("quick-tab-\(tab.id.rawValue)")
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: tabsHeight)
                    }
                    if let tab = workspace.activeTab, tab.isSplit {
                        SplitFocusRow(tab: tab, palette: palette)
                            .padding(.horizontal, 4)
                            .frame(height: splitRowHeight)
                    }
                }
                .padding(.bottom, handleBarHeight)
                .transition(.opacity)
            }
            if workspace.editing != nil && !workspace.searchResults.isEmpty {
                let results = workspace.searchResults
                ScrollView { VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        if index == 0 || results[index - 1].source.label != result.source.label {
                            Text(result.source.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(palette.textDim)
                                .padding(.horizontal, 14)
                                .frame(height: 22)
                        }
                        Button { workspace.openSearchResult(result) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(CompactLine.host(result.url.absoluteString))
                                    .font(.system(size: 10)).foregroundStyle(palette.textDim).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .contentShape(Rectangle())
                            .background(workspace.selectedSearchResult == index ? palette.text.opacity(0.12) : .clear)
                        }
                        .buttonStyle(.pointing)
                        .accessibilityIdentifier("search-result-\(index)")
                        .accessibilityAddTraits(workspace.selectedSearchResult == index ? .isSelected : [])
                    }
                }
                }.frame(height: resultsHeight)
                .padding(.bottom, controlsHeight)
                .transition(.opacity)
            }
            if workspace.overviewOpen && workspace.editing == nil {
                WorkspaceOverview(palette: palette)
                    .frame(width: overviewSize.width, height: overviewSize.height)
                    .transition(.opacity)
            }
            if workspace.identityOpen && workspace.editing == nil {
                IdentityInspector(origin: trustedOrigin, palette: palette)
                    .frame(width: identitySize.width, height: identitySize.height)
                    .transition(.opacity)
            }
            if historyOpen {
                PageHistoryPanel(palette: palette) { workspace.pageHistoryOpen = false }
                    .padding(.bottom, 44)
                    .frame(width: historySize.width, height: historySize.height)
                    .transition(.opacity)
            }
            if downloadsOpen {
                DownloadsPanel(palette: palette)
                    .padding(.bottom, 44)
                    .frame(width: downloadsSize.width, height: downloadsSize.height)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                Button { workspace.toggleOverview() } label: {
                    SiteIcon(pane: pane, palette: palette, framed: false)
                        .frame(width: 44, height: 44)
                        .padding(.leading, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pointing)
                .accessibilityLabel(workspace.overviewOpen ? "Return to page" : "Show all tabs, \(identity)")
                .accessibilityHint("Hover or hold left Command to show open pages")
                .accessibilityIdentifier("page-handle")
                if workspace.editing != nil {
                    LineEditor(palette: palette)
                        .padding(.trailing, 14)
                } else if let caption = voiceCaption, !workspace.overviewOpen {
                    Label(caption, systemImage: workspace.voice.state.isListening ? "waveform" : "mic")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.trailing, 14)
                } else if workspace.identityOpen || historyOpen || downloadsOpen {
                    Spacer(minLength: 0)
                } else {
                    identityRows
                }
            }
            .frame(height: handleBarHeight)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: morphed ? 20 : 14, style: .continuous))
        .modifier(PageGlass(radius: morphed ? 20 : 14))
        .modifier(AILabelGlow(effect: workspace.assistance.labelEffect, pane: pane,
                               radius: morphed ? 20 : 14))
        .foregroundStyle(palette.text)
        .onHover { workspace.quickSwitchOpen = $0 }
        .onAppear { workspace.beginEmptyPageEditingIfNeeded() }
        .onChange(of: workspace.activePane) { _, _ in workspace.beginEmptyPageEditingIfNeeded() }
        .onChange(of: workspace.isEmptyActivePage) { _, isEmpty in
            if isEmpty { workspace.beginEmptyPageEditingIfNeeded() }
        }
        .animation(reduceMotion ? nil : Metrics.morph, value: size)
        .animation(reduceMotion ? nil : Metrics.morph, value: expanded)
    }

    /// The address, then the origin. Pointing at the origin opens the handle,
    /// so the origin keeps its place and identity in both states to stay clickable.
    private var identityRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTabs {
                HStack(spacing: 0) {
                    LineEditor(palette: palette)
                        .padding(.trailing, workspace.currentPageURL == nil ? 14 : 8)
                    if workspace.currentPageURL != nil {
                        Text(workspace.showsCopiedPageURL ? "Copied" : "⇧⌘C")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                            .padding(.trailing, 14)
                            .help(workspace.showsCopiedPageURL ? "Page URL copied" : "Copy page URL")
                    }
                }
            } else {
                addressButton
                    .padding(.trailing, 16)
            }
            if let origin = trustedOrigin {
                originButton(origin)
                    .padding(.trailing, 16)
            }
        }
        .frame(height: trustedOrigin == nil ? 44 : 52)
    }

    private var addressButton: some View {
        Button { workspace.editActiveLine() } label: {
            Group {
                if workspace.showsCopiedPageURL {
                    Text("Copied")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    AILabel(identity: identity, pane: pane, effect: workspace.assistance.labelEffect)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel(trustedOrigin.map { "Edit address, \(identity), \($0.accessibilityLabel)" } ?? "Edit address, \(identity)")
        .accessibilityIdentifier("page-address")
        .help(pane.map { workspace.surfaces.line($0) } ?? "")
    }

    private func originButton(_ origin: TrustedOrigin) -> some View {
        Button { workspace.toggleIdentity() } label: {
            HStack(spacing: 4) {
                Image(systemName: origin.transport == .http ? "exclamationmark.triangle.fill" : "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(origin.transport == .http ? Color(red: 0.82, green: 0.38, blue: 0.08) : palette.textDim)
                Text(origin.compactLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(origin.transport == .http ? Color(red: 0.82, green: 0.38, blue: 0.08) : palette.textDim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel("Site identity, \(origin.accessibilityLabel)")
        .accessibilityIdentifier("page-origin")
        .help(origin.fullURL)
    }

    @ViewBuilder
    private var shareControl: some View {
        let url = pane.flatMap(workspace.hosts.existingBrowser)?.url
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pointing)
            .accessibilityLabel("Share page")
            .accessibilityIdentifier("share-page-button")
            .help("Share this page")
        } else {
            browserControl("Share page", symbol: "square.and.arrow.up", id: "share-page-button") { }
                .disabled(true)
                .help("This page cannot be shared")
        }
    }

    private func browserControl(_ label: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

}

/// The current tab when it is split: both pages on one line, as they sit on
/// screen. Clicking one gives it focus.
private struct SplitFocusRow: View {
    @Environment(Workspace.self) private var workspace
    var tab: Tab
    var palette: Palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tab.panes, id: \.self) { pane in
                Button {
                    workspace.clickPane(pane)
                } label: {
                    HStack(spacing: 8) {
                        SiteIcon(pane: pane, palette: palette, framed: false)
                            .frame(width: 28, height: 28)
                        Text(workspace.title(pane))
                            .font(.system(size: 12, weight: pane == tab.active ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 38)
                    .background(pane == tab.active ? palette.text.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pointing)
                .accessibilityLabel(pane == tab.active ? "\(workspace.title(pane)), focused" : "Focus \(workspace.title(pane))")
                .accessibilityIdentifier("split-focus-\(pane.rawValue)")
            }
        }
    }
}

/// A split tab in the open pages list: both pages on one line, in the order
/// they sit on screen.
private struct SplitTabLabel: View {
    @Environment(Workspace.self) private var workspace
    var tab: Tab
    var palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(tab.panes.enumerated()), id: \.element) { index, pane in
                if index > 0 {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textDim)
                        .accessibilityHidden(true)
                }
                SiteIcon(pane: pane, palette: palette, framed: false)
                    .frame(width: 28, height: 28)
                Text(workspace.title(pane))
                    .font(.system(size: 12, weight: pane == tab.active ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(pane == tab.active ? 1 : 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Connection details for the current origin. Page labels never appear here.
private struct IdentityInspector: View {
    @Environment(Workspace.self) private var workspace
    var origin: TrustedOrigin?
    var palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connection")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { workspace.closeIdentity() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.pointing)
                    .accessibilityLabel("Close connection details")
                    .accessibilityIdentifier("close-identity")
            }
            if let origin {
                HStack(spacing: 6) {
                    Image(systemName: origin.transport == .http ? "exclamationmark.triangle.fill" : "lock.fill")
                        .foregroundStyle(origin.transport == .http ? Color(red: 0.82, green: 0.38, blue: 0.08) : palette.text)
                    Text(origin.transport.compactLabel)
                        .fontWeight(.medium)
                        .foregroundStyle(origin.transport == .http ? Color(red: 0.82, green: 0.38, blue: 0.08) : palette.text)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(origin.accessibilityLabel)
                labeled("Site", origin.displayHost)
                if origin.usesPunycode {
                    labeled("Encoded host", origin.asciiHost)
                }
                labeled("Address", origin.fullURL)
                if origin.mixedScript {
                    Text("This hostname mixes writing systems and may imitate another site.")
                        .foregroundStyle(Color(red: 0.82, green: 0.38, blue: 0.08))
                }
                if origin.transport == .http {
                    Text("This connection is not encrypted. Anything you send can be read on the network.")
                        .foregroundStyle(Color(red: 0.82, green: 0.38, blue: 0.08))
                }
                HStack {
                    Button("Edit Address", action: workspace.editActiveLine)
                        .pointingHandCursor()
                        .accessibilityIdentifier("identity-edit-address")
                    Spacer()
                    Button("Copy URL") { _ = workspace.copyCurrentPageURL() }
                        .pointingHandCursor()
                        .accessibilityIdentifier("identity-copy-url")
                }
            } else {
                Text("No remote page is active.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .padding(.bottom, 44)
        .onExitCommand { workspace.closeIdentity() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("identity-inspector")
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(palette.textDim)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .accessibilityIdentifier("identity-\(title.lowercased())")
        }
    }
}

/// An AI-refined label arrives with a brief spectrum sweep. The ordinary local
/// label and user-authored tab names retain the browser's normal text color.
private struct AILabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var identity: String
    var pane: PaneID?
    var effect: AILabelEffect?
    @State private var sweep: CGFloat = -1
    @State private var rainbowOpacity = 0.0

    private let colors: [Color] = [
        Color(red: 0.20, green: 0.72, blue: 1.00),
        Color(red: 0.48, green: 0.36, blue: 1.00),
        Color(red: 0.94, green: 0.31, blue: 0.78),
        Color(red: 1.00, green: 0.47, blue: 0.28),
        Color(red: 0.27, green: 0.88, blue: 0.80)
    ]

    var body: some View {
        Text(identity)
            .font(.system(size: 12))
            .overlay {
                GeometryReader { geometry in
                    let width = max(52, geometry.size.width * 0.72)
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                        .offset(x: ((sweep + 1) / 2) * (geometry.size.width + width) - width)
                }
                .mask {
                    Text(identity)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .opacity(rainbowOpacity)
                .accessibilityHidden(true)
            }
            .onChange(of: effect) { _, update in
                guard update?.pane == pane else { return }
                sweep = reduceMotion ? 0 : -1
                rainbowOpacity = 1
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 1.15)) { sweep = 1 }
                }
                withAnimation(.easeOut(duration: 0.5).delay(reduceMotion ? 0.25 : 0.85)) {
                    rainbowOpacity = 0
                }
            }
    }
}

/// A restrained version of the Apple Intelligence spectrum glow. It hugs a
/// glass panel only while an AI-refined result is being revealed: the page
/// label on the handle, or a freshly read site menu.
struct AILabelGlow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var effect: AILabelEffect?
    var pane: PaneID?
    var radius: CGFloat
    @State private var glowOpacity = 0.0
    @State private var hue = 0.0

    private var gradient: AngularGradient {
        AngularGradient(colors: [
            Color(red: 0.20, green: 0.72, blue: 1.00),
            Color(red: 0.48, green: 0.36, blue: 1.00),
            Color(red: 0.94, green: 0.31, blue: 0.78),
            Color(red: 1.00, green: 0.47, blue: 0.28),
            Color(red: 0.27, green: 0.88, blue: 0.80),
            Color(red: 0.20, green: 0.72, blue: 1.00)
        ], center: .center)
    }

    func body(content: Content) -> some View {
        content.overlay {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.stroke(gradient, lineWidth: 3).blur(radius: 4).opacity(0.55)
                shape.stroke(gradient, lineWidth: 1.25)
            }
            .hueRotation(.degrees(hue))
            .opacity(glowOpacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // A panel can be created by the same result that lights it up — the
        // site menu appears only once its contents have been read — so the
        // effect has to be honored on arrival as well as on change.
        .onAppear { reveal(effect) }
        .onChange(of: effect) { _, update in reveal(update) }
    }

    private func reveal(_ update: AILabelEffect?) {
        guard update?.pane == pane else { return }
        hue = 0
        glowOpacity = 1
        if !reduceMotion {
            withAnimation(.linear(duration: 1.25)) { hue = 150 }
        }
        withAnimation(.easeOut(duration: 0.55).delay(reduceMotion ? 0.25 : 0.85)) {
            glowOpacity = 0
        }
    }
}

struct PageGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let backing = scheme == .dark ? Color.black : Color.white
        Group {
            if reduceTransparency || contrast == .increased {
                content.background(backing, in: shape)
            } else if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        }
        // Glass is visual only. Claim its empty space as well as its controls,
        // so the web view underneath cannot receive clicks through the panel.
        .contentShape(shape)
        .onTapGesture { }
        .background(PageControlRegion(radius: radius))
    }
}

struct PointingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pointingHandCursor()
    }
}

extension ButtonStyle where Self == PointingButtonStyle {
    static var pointing: PointingButtonStyle { PointingButtonStyle() }
}

extension View {
    func pointingHandCursor() -> some View {
        background(PointingCursorRegion())
    }

    /// A region that shows `cursor` instead of the pointing hand, like a divider's.
    func cursorRegion(_ cursor: NSCursor) -> some View {
        background(PointingCursorRegion(cursor: cursor))
    }
}

private struct PointingCursorRegion: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var cursor: NSCursor = .pointingHand
    fileprivate static let regions = NSHashTable<CursorView>.weakObjects()

    final class CursorView: NSView {
        var cursor = NSCursor.pointingHand

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: cursor)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> CursorView {
        let view = CursorView()
        Self.regions.add(view)
        return view
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = isEnabled ? cursor : .arrow
        view.window?.invalidateCursorRects(for: view)
    }
}

/// AppKit's hit test can see Chromium below SwiftUI controls before SwiftUI routes
/// the event. Track the actual panel bounds before deciding a click is outside.
struct PageControlRegion: NSViewRepresentable {
    var radius: CGFloat
    private static let regions = NSHashTable<RegionView>.weakObjects()

    final class RegionView: NSView {
        var radius: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.radius = radius
        Self.regions.add(view)
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) { view.radius = radius }

    static func contains(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return contains(event.locationInWindow, in: window)
    }

    static func contains(_ location: NSPoint, in window: NSWindow) -> Bool {
        regions.allObjects.contains { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let point = view.convert(location, from: nil)
            return NSBezierPath(roundedRect: view.bounds, xRadius: view.radius, yRadius: view.radius).contains(point)
        }
    }
}

/// The glass floats over Chromium, which repaints the cursor for whatever
/// page content sits underneath. Over Interlinked's own controls the page
/// gives the cursor up: clickable controls show the pointing hand, the rest
/// of the glass the arrow, and the page's cursor returns when the mouse
/// leaves.
@MainActor
enum ChromeCursor {
    private static var monitor: Any?
    private static var owning = false

    static func install() {
        guard monitor == nil else { return }
        ILChromiumView.setChromeOwnsCursor {
            MainActor.assumeIsolated { cursorUnderMouse() != nil }
        }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseUp, .leftMouseDragged, .scrollWheel]
        ) { event in
            // After the event is delivered, so Chromium's own handling
            // cannot repaint the cursor over ours.
            DispatchQueue.main.async { update() }
            return event
        }
    }

    static func update() {
        if let cursor = cursorUnderMouse() {
            cursor.set()
            owning = true
        } else if owning {
            owning = false
            ILChromiumView.restorePageCursor()
        }
    }

    private static func cursorUnderMouse() -> NSCursor? {
        let mouse = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number) else { return nil }
        let location = window.convertPoint(fromScreen: mouse)
        let controls = PointingCursorRegion.regions.allObjects.filter { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(location, from: nil))
        }
        if !controls.isEmpty {
            // A special cursor, like a divider's resize, wins over the hand.
            if let special = controls.first(where: { $0.cursor != .pointingHand && $0.cursor != .arrow }) {
                return special.cursor
            }
            return controls.contains { $0.cursor == .pointingHand } ? .pointingHand : .arrow
        }
        return PageControlRegion.contains(location, in: window) ? .arrow : nil
    }
}

struct SiteIcon: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID?
    var palette: Palette
    var framed = true

    var body: some View {
        ZStack {
            if framed {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.panel)
            }
            if let pane, let icon = workspace.hosts.favicons[pane] {
                Image(nsImage: icon).resizable().scaledToFit().padding(5)
            } else {
                Image(systemName: pane.map { workspace.surfaces.kind($0).symbol } ?? "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.text)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}
