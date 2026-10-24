import SwiftUI
import UniformTypeIdentifiers

/// Laid out like a terminal multiplexer: open pages down a glass sidebar, and
/// each page a card of its own, lifted off the frosted window, with its own
/// header in place of a toolbar across the window. Each group morphs in
/// place: the sidebar into History or Downloads, the address field into
/// results or the site's connection, and a header's tools into Find.
struct SidebarLayout<Page: View>: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    @ViewBuilder var page: () -> Page
    /// The width while the divider is dragged, before it settles.
    @State private var dragging: CGFloat?
    @State private var dragStart: CGFloat = 0
    /// Where the pointer is: the edge strip and the peeked sidebar each report
    /// their own hover, in no set order.
    @State private var overEdge = false
    @State private var overPeek = false
    /// Puts the peeked sidebar away shortly after the pointer leaves both.
    @State private var unpeek: Task<Void, Never>?

    private var width: CGFloat {
        guard let dragging else { return workspace.sidebar }
        return max(Metrics.sidebarMin, min(dragging, Metrics.sidebarMax))
    }

    var body: some View {
        HStack(spacing: 0) {
            if !workspace.sidebarCollapsed {
                TabSidebar(palette: palette)
                    .frame(width: width)
                    .padding([.top, .leading, .bottom], SidebarMetrics.inset)
                    .overlay(alignment: .trailing) { resizer }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            // The pages, each its own card (`SplitLayout`), with a gap that
            // shows the sidebar's edge and the window around them.
            page()
                .padding(SidebarMetrics.inset)
        }
        .overlay(alignment: .topLeading) {
            if workspace.sidebarCollapsed { peek }
        }
        .animation(reduceMotion ? nil : Metrics.morph, value: workspace.sidebarCollapsed)
        .onAppear { workspace.beginEmptyPageEditingIfNeeded() }
        .onChange(of: workspace.activePane) { _, _ in workspace.beginEmptyPageEditingIfNeeded() }
        .onChange(of: workspace.isEmptyActivePage) { _, isEmpty in
            if isEmpty { workspace.beginEmptyPageEditingIfNeeded() }
        }
    }

    /// Hidden, the sidebar slides back over the page while the pointer rests
    /// on the window's left edge, and tucks away again once it leaves.
    private var peek: some View {
        ZStack(alignment: .topLeading) {
            // The page's leading inset, on the chrome, so resting here never
            // fights the page for the pointer.
            Color.clear
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { overEdge = $0; pointerMoved() }
                .onDisappear { overEdge = false }
                .accessibilityHidden(true)
            if workspace.sidebarPeeking {
                TabSidebar(palette: palette)
                    .frame(width: workspace.sidebarLast)
                    .modifier(PeekSurface(palette: palette))
                    .padding(8)
                    .onHover { overPeek = $0; pointerMoved() }
                    .onDisappear { overPeek = false }
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.78),
                   value: workspace.sidebarPeeking)
    }

    /// Over either the edge or the peek, it shows; off both, it tucks away
    /// after a short pause, so a quick pass over the edge doesn't flicker it.
    /// A tab dragged out onto the page keeps it open until the button comes up.
    private func pointerMoved() {
        unpeek?.cancel()
        if overEdge || overPeek {
            if !workspace.sidebarPeeking { workspace.sidebarPeeking = true }
            return
        }
        unpeek = Task { @MainActor in
            repeat {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            } while NSEvent.pressedMouseButtons & 1 != 0
            workspace.closePeek()
        }
    }

    private var resizer: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .cursorRegion(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        if dragging == nil { dragStart = workspace.sidebar }
                        dragging = dragStart + drag.translation.width
                    }
                    .onEnded { _ in
                        // Dragged far enough left, the sidebar tucks away.
                        workspace.setSidebar(Metrics.settleSidebar(dragging ?? workspace.sidebar))
                        dragging = nil
                    }
            )
            .accessibilityHidden(true)
    }
}

extension View {
    /// Dragging here moves the window, like the titlebar it stands in for.
    func windowDragArea() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .accessibilityHidden(true)
    }
}

enum SidebarMetrics {
    /// The one spacing step: the window's margin around the sidebar and the
    /// pages, a header's padding, and the gap between its groups.
    static let inset: CGFloat = 8
    /// The sidebar's top row and each page's header, centered on the window
    /// buttons, which sit in one or the other.
    static let header: CGFloat = 30
    /// A header's buttons and address field, all on the header's centre line.
    static let headerControl: CGFloat = 26
    /// The origin inside the address field, the same distance from its top,
    /// bottom and leading edge.
    static let originChip: CGFloat = 18
    /// The room a header row keeps for the window buttons: up to the end of
    /// their slot, less the card's margin and the row's padding.
    static var windowButtonsRoom: CGFloat { WindowButtonPlacement.slot.maxX - 2 * inset }
    static let row: CGFloat = 30
    static let icon: CGFloat = 20
    static let control: CGFloat = 32
    /// The sidebar's, the peeked sidebar's, and the page's corners.
    static let radius: CGFloat = 16
}

// MARK: - Sidebar

/// Drops a dragged tab between the sidebar's rows: over a row's upper half it
/// goes before that row, over its lower half after it. The New Page row
/// (`row` nil) takes it to the end.
private struct TabReorderDrop: DropDelegate {
    var row: Int?
    @Binding var gap: Int?
    var workspace: Workspace

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.interlinkedTab]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = resolve(info)
        if gap != next { withAnimation(.easeOut(duration: 0.12)) { gap = next } }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // The next row may already have claimed its gap.
        if gap == resolve(info) { withAnimation(.easeOut(duration: 0.12)) { gap = nil } }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = resolve(info)
        gap = nil
        guard let provider = info.itemProviders(for: [.interlinkedTab]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.interlinkedTab.identifier) { data, _ in
            guard let data, let raw = UInt64(String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in workspace.moveTab(TabID(raw), toGap: target) }
        }
        return true
    }

    private func resolve(_ info: DropInfo) -> Int {
        guard let row else { return workspace.tabs.count }
        return info.location.y < SidebarMetrics.control / 2 ? row : row + 1
    }
}

private struct TabSidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    /// Where a tab dragged over the list would land: the gap before this row.
    @State private var dropGap: Int?

    private var historyOpen: Bool { workspace.pageHistoryOpen && workspace.editing == nil }
    private var downloadsOpen: Bool { workspace.downloads.panelOpen && workspace.editing == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The window buttons sit here, drawn by AppKit.
                Color.clear
                    .frame(width: SidebarMetrics.windowButtonsRoom)
                    .allowsHitTesting(false)
                SidebarToggle(palette: palette)
                Spacer(minLength: 0)
                Button(action: workspace.newPage) {
                    ToolbarIcon(symbol: "plus", palette: palette)
                }
                .help("New page · ⌘T")
                .accessibilityLabel("New page")
                .accessibilityIdentifier("sidebar-new-page")
            }
            .buttonStyle(.pointing)
            .padding(.horizontal, SidebarMetrics.inset)
            .frame(height: SidebarMetrics.header)
            .background { Color.clear.windowDragArea() }

            Group {
                if historyOpen {
                    PageHistoryPanel(palette: palette) { workspace.pageHistoryOpen = false }
                } else if downloadsOpen {
                    DownloadsPanel(palette: palette)
                } else {
                    VStack(spacing: 0) {
                        tabs
                        tools
                    }
                }
            }
            .transition(.opacity)
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.text)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(PageGlass(radius: SidebarMetrics.radius))
        .animation(reduceMotion ? nil : Metrics.morph, value: historyOpen)
        .animation(reduceMotion ? nil : Metrics.morph, value: downloadsOpen)
    }

    private var tabs: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                Text("Tabs")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                    SidebarTabRow(tab: tab, palette: palette)
                        .overlay(alignment: .top) { dropLine(before: index) }
                        .onDrop(of: [.interlinkedTab], delegate: TabReorderDrop(row: index, gap: $dropGap, workspace: workspace))
                }
                Button(action: workspace.newPage) {
                    SidebarRowLabel(title: "New Page", symbol: "plus", palette: palette)
                        .foregroundStyle(palette.textDim)
                }
                .buttonStyle(.pointing)
                .overlay(alignment: .top) { dropLine(before: workspace.tabs.count) }
                // Dropped here, a tab goes to the end.
                .onDrop(of: [.interlinkedTab], delegate: TabReorderDrop(row: nil, gap: $dropGap, workspace: workspace))
                .accessibilityIdentifier("sidebar-new-page-row")
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
        .scrollIndicators(.never)
    }

    /// The line a dragged tab would drop on, centred in the spacing above a row.
    @ViewBuilder
    private func dropLine(before index: Int) -> some View {
        if dropGap == index {
            Capsule()
                .fill(palette.accent)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: -2)
                .allowsHitTesting(false)
        }
    }

    /// The page's copy buttons, then one row of icons along the bottom.
    private var tools: some View {
        VStack(spacing: 2) {
            if let found = workspace.usefulInfo.active {
                SidebarUsefulInfo(found: found, palette: palette)
            }
            HStack(spacing: 2) {
                Button(action: workspace.togglePageHistory) {
                    ToolbarIcon(symbol: "clock.arrow.circlepath", palette: palette)
                }
                .help("History")
                .accessibilityLabel("History")
                .accessibilityIdentifier("sidebar-history")
                Button(action: workspace.toggleDownloads) {
                    ToolbarIcon(symbol: workspace.downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle",
                                palette: palette)
                        .overlay(alignment: .topTrailing) {
                            if workspace.downloads.activeCount > 0 {
                                Text("\(workspace.downloads.activeCount)")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .padding(.horizontal, 3)
                                    .background(palette.accent, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .help("Downloads")
                .accessibilityLabel(workspace.downloads.activeCount > 0 ? "Downloads, \(workspace.downloads.activeCount) active" : "Downloads")
                .accessibilityIdentifier("sidebar-downloads")
                Button { workspace.sharingScreenMode.toggle() } label: {
                    ToolbarIcon(symbol: workspace.sharingScreenMode ? "eye.slash.fill" : "eye.slash", palette: palette)
                }
                .foregroundStyle(workspace.sharingScreenMode ? palette.accent : palette.text)
                .help("Sharing Screen Mode\(workspace.sharingScreenMode ? ", on" : ""): blur emails, phone numbers, card and document numbers, keys, and passwords on every page · \(ToolboxShortcut.sharingScreen.label)")
                .accessibilityLabel(workspace.sharingScreenMode ? "Sharing Screen Mode, on" : "Sharing Screen Mode")
                .accessibilityIdentifier("sidebar-sharing-screen")
                Spacer(minLength: 0)
                Button {
                    workspace.settingsDestination = .general
                    workspace.openSettings?()
                } label: {
                    ToolbarIcon(symbol: "gearshape", palette: palette)
                }
                .help("Settings · \(ToolboxShortcut.settings.label)")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("sidebar-settings")
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)
        }
        .buttonStyle(.pointing)
        .padding(.horizontal, 6)
        .padding(.bottom, SidebarMetrics.inset)
    }
}

/// Hides the sidebar from its top row, or brings it back from the first
/// page's header.
private struct SidebarToggle: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette

    var body: some View {
        Button(action: workspace.toggleSidebar) {
            ToolbarIcon(symbol: "sidebar.left", palette: palette)
        }
        .help("\(workspace.sidebarCollapsed ? "Show" : "Hide") sidebar · ⌃⌘S")
        .accessibilityLabel(workspace.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")
        .accessibilityIdentifier("toolbar-sidebar")
    }
}

/// One row of the sidebar: the icon and label columns line up with the tabs.
private struct SidebarRowLabel: View {
    var title: String
    var symbol: String
    var detail: String? = nil
    var palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: SidebarMetrics.icon)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.textDim)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SidebarMetrics.row)
        .contentShape(Rectangle())
    }
}

private struct SidebarTabRow: View {
    @Environment(Workspace.self) private var workspace
    @State private var hovering = false
    var tab: Tab
    var palette: Palette

    private var active: Bool { workspace.activeTab?.id == tab.id }

    var body: some View {
        Button { workspace.selectWork(tab.id) } label: {
            HStack(spacing: 8) {
                if tab.isSplit && tab.name == nil {
                    ForEach(Array(tab.panes.enumerated()), id: \.element) { index, pane in
                        if index > 0 {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(palette.textDim)
                        }
                        SiteIcon(pane: pane, palette: palette, framed: false, size: SidebarMetrics.icon)
                        Text(workspace.title(pane)).lineLimit(1)
                    }
                } else {
                    SiteIcon(pane: tab.active, palette: palette, framed: false, size: SidebarMetrics.icon)
                    AILabel(identity: workspace.title(tab), pane: tab.active, effect: workspace.assistance.labelEffect)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .fontWeight(active ? .semibold : .regular)
            .padding(.leading, 8)
            .padding(.trailing, 28)
            .frame(height: SidebarMetrics.control)
            .background(active ? palette.text.opacity(0.12) : hovering ? palette.text.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .modifier(AILabelGlow(effect: workspace.assistance.labelEffect, pane: tab.active, radius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointing)
        // Drop it on the page to open the two side by side.
        .onDrag { NSItemProvider.tab(tab.id) } preview: {
            Label(workspace.title(tab), systemImage: "rectangle.split.2x1")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.regularMaterial, in: Capsule())
        }
        .overlay(alignment: .trailing) {
            if hovering || active {
                Menu {
                    Button("Rename") { _ = workspace.editTab(tab.id) }
                    Button("Close Tab") { workspace.closeTab(tab.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.pointing)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 5)
                .help("Rename or close")
                .accessibilityLabel("More for \(workspace.title(tab))")
                .accessibilityIdentifier("sidebar-tab-more-\(tab.id.rawValue)")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { _ = workspace.editTab(tab.id) }
            Button("Close Tab") { workspace.closeTab(tab.id) }
        }
        .accessibilityLabel(active ? "\(workspace.title(tab)), current tab" : "Switch to \(workspace.title(tab))")
        .accessibilityHint("Drag up or down to reorder, or onto the page to open it side by side")
        .accessibilityIdentifier("sidebar-tab-\(tab.id.rawValue)")
    }
}

/// The page's address and contact details, copied with one click.
private struct SidebarUsefulInfo: View {
    @Environment(Workspace.self) private var workspace
    var found: PageContacts
    var palette: Palette

    private var info: UsefulInfo { workspace.usefulInfo }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("On this page")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.textDim)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            if let address = found.address {
                copyRow(address, symbol: "map", id: "useful-address")
            }
            ForEach(found.options, id: \.value) { option in
                copyRow(option.value, symbol: option.kind == .phone ? "phone" : "envelope", id: "useful-contact-\(option.value)")
            }
        }
    }

    private func copyRow(_ value: String, symbol: String, id: String) -> some View {
        Button { info.copy(value) } label: {
            SidebarRowLabel(title: info.copied == value ? "Copied" : value,
                            symbol: info.copied == value ? "checkmark" : symbol, palette: palette)
        }
        .help("Copy \(value)")
        .accessibilityLabel("Copy \(value)")
        .accessibilityIdentifier(id)
    }
}

// MARK: - Page header

/// A page's own header inside its card, as each pane has in a terminal
/// multiplexer. The page with focus carries navigation, the address and its
/// tools. The other side of a split shows its title, and a click there brings
/// it in. With the sidebar tucked away, the first page's header makes room for
/// the window buttons and the button that brings the sidebar back.
struct PageHeader: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pane: PaneID
    var palette: Palette
    var holdsWindowButtons: Bool

    private var focused: Bool { workspace.activePane == pane }
    private var finding: Bool { workspace.assistance.panel == .find }

    /// Every group sits one `inset` from the next and from the card's edges,
    /// on one centre line, and the close button always holds the last spot,
    /// so nothing moves when a page splits or Find opens.
    var body: some View {
        HStack(spacing: SidebarMetrics.inset) {
            if holdsWindowButtons {
                HStack(spacing: 0) {
                    // The window buttons sit here, drawn by AppKit.
                    Color.clear
                        .frame(width: SidebarMetrics.windowButtonsRoom, height: SidebarMetrics.headerControl)
                        .allowsHitTesting(false)
                    SidebarToggle(palette: palette)
                }
            }
            if focused {
                navigation
                // Reports one row's height, so results and the site's
                // connection open downward over the page without moving the row.
                AddressField(palette: palette)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: SidebarMetrics.headerControl, alignment: .top)
                tools
            } else {
                Button { workspace.clickPane(pane) } label: {
                    HStack(spacing: 6) {
                        SiteIcon(pane: pane, palette: palette, framed: false, size: 16)
                        Text(workspace.title(pane))
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textDim)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, (SidebarMetrics.headerControl - 16) / 2)
                    .frame(height: SidebarMetrics.headerControl)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Switch to \(workspace.title(pane))")
            }
            control(workspace.isSplit ? "Close this side" : "Close page", symbol: "xmark",
                    id: "page-close-\(pane.rawValue)") {
                workspace.closePane(pane)
            }
            .help("\(workspace.isSplit ? "Close this side" : "Close page") · ⌘W")
        }
        .buttonStyle(.pointing)
        .foregroundStyle(palette.text)
        .padding(.horizontal, SidebarMetrics.inset)
        .frame(height: SidebarMetrics.header)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Color.clear.windowDragArea() }
        .animation(reduceMotion ? nil : Metrics.morph, value: finding)
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            control("Back", symbol: "chevron.left", id: "browser-back") {
                workspace.discardLine()
                workspace.hosts.existingBrowser(pane)?.goBack()
            }
            .disabled(!workspace.hosts.canGoBack[pane, default: false])
            control("Forward", symbol: "chevron.right", id: "browser-forward") {
                workspace.discardLine()
                workspace.hosts.existingBrowser(pane)?.goForward()
            }
            .disabled(!workspace.hosts.canGoForward[pane, default: false])
            control("Reload", symbol: "arrow.clockwise", id: "browser-reload") {
                workspace.hosts.existingBrowser(pane)?.reload()
            }
            .disabled(workspace.currentPageURL == nil)
        }
    }

    @ViewBuilder
    private var tools: some View {
        if finding {
            ToolbarFindField(palette: palette)
                .frame(maxWidth: 300)
                .modifier(PageGlass(radius: SidebarMetrics.headerControl / 2))
        } else {
            HStack(spacing: 0) {
                control("Find for me", symbol: "magnifyingglass", id: "page-search-button",
                        action: workspace.assistance.openFind)
                    .help("Find in page · \(ToolboxShortcut.find.label)")
                shareControl
                control(workspace.isSplit ? "Move side page to its own tab" : "Split view",
                        symbol: workspace.isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                        id: "split-view-button", action: workspace.toggleSplitView)
                    .help(workspace.isSplit ? "Move the other page to its own tab · ⌘\\" : "Split view · ⌘\\")
            }
        }
    }

    @ViewBuilder
    private var shareControl: some View {
        let url = workspace.hosts.existingBrowser(pane)?.url
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            ShareLink(item: url) {
                ToolbarIcon(symbol: "square.and.arrow.up", palette: palette)
            }
            .buttonStyle(.pointing)
            .accessibilityLabel("Share page")
            .accessibilityIdentifier("share-page-button")
            .help("Share this page")
        } else {
            control("Share page", symbol: "square.and.arrow.up", id: "share-page-button") { }
                .disabled(true)
                .help("This page cannot be shared")
        }
    }

    private func control(_ label: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolbarIcon(symbol: symbol, palette: palette)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A header or sidebar button's icon, lit under the pointer to show what a
/// click will hit.
private struct ToolbarIcon: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var symbol: String
    var palette: Palette

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: SidebarMetrics.headerControl, height: SidebarMetrics.headerControl)
            .background(hovering && isEnabled ? palette.hover : .clear, in: Circle())
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The peeked sidebar, whose own glass card is raised over the page on a
/// shadow, with the page dimmed underneath so its rows stay readable over
/// anything.
private struct PeekSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var palette: Palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous)
        content
            .overlay {
                shape.strokeBorder(contrast == .increased ? palette.text.opacity(0.5) : palette.hairline)
                    .allowsHitTesting(false)
            }
            .background(shape.fill(palette.pane.opacity(0.6)).shadow(color: .black.opacity(0.35), radius: 18, x: 4))
    }
}

/// The address, which grows downward into search results while you type
/// and into the site's connection details from its lock.
private struct AddressField: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette

    private var origin: TrustedOrigin? { workspace.currentPageURL.flatMap(TrustedOrigin.inspect) }
    private var results: [SearchResult] { workspace.editing == nil ? [] : workspace.searchResults }
    private var identityOpen: Bool { workspace.identityOpen && workspace.editing == nil }
    private var open: Bool { identityOpen || !results.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let origin, workspace.editing == nil {
                    Button(action: workspace.toggleIdentity) {
                        HStack(spacing: 4) {
                            Image(systemName: origin.transport == .http ? "exclamationmark.triangle.fill" : "lock.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(origin.compactLabel)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(origin.transport == .http ? Color(red: 0.82, green: 0.38, blue: 0.08) : palette.textDim)
                        .padding(.horizontal, 6)
                        .frame(height: SidebarMetrics.originChip)
                        .background(palette.text.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.pointing)
                    .help(origin.fullURL)
                    .accessibilityLabel("Site identity, \(origin.accessibilityLabel)")
                    .accessibilityIdentifier("page-origin")
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textDim)
                        .frame(width: SidebarMetrics.originChip, height: SidebarMetrics.originChip)
                }
                LineEditor(palette: palette)
                if workspace.currentPageURL != nil, workspace.editing == nil {
                    Text(workspace.showsCopiedPageURL ? "Copied" : "⇧⌘C")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.textDim)
                        // Mirrors the origin's own padding on the other side.
                        .padding(.trailing, 6)
                        .help(workspace.showsCopiedPageURL ? "Page URL copied" : "Copy page URL")
                }
            }
            // The origin sits as far from the leading edge as from the top
            // and bottom, and the trailing side mirrors it.
            .padding(.horizontal, (SidebarMetrics.headerControl - SidebarMetrics.originChip) / 2)
            .frame(height: SidebarMetrics.headerControl)

            if identityOpen {
                IdentityInspector(origin: origin, palette: palette)
                    .frame(height: 220)
                    .transition(.opacity)
            } else if !results.isEmpty {
                resultsList(results)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(PageGlass(radius: open ? SidebarMetrics.radius : SidebarMetrics.headerControl / 2))
        .animation(reduceMotion ? nil : Metrics.morph, value: open)
    }

    /// Takes the results it lays out: rows built later must not read a newer,
    /// shorter list.
    private func resultsList(_ results: [SearchResult]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
            .padding(.bottom, 6)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Find for me, in the place of the header tools that opened it.
private struct ToolbarFindField: View {
    @Environment(Workspace.self) private var workspace
    var palette: Palette

    var body: some View {
        @Bindable var assistant = workspace.assistance
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24)
                .help("Right-click to choose exact text or meaning")
                .contextMenu {
                    Toggle("Match by meaning with Jev", isOn: $assistant.byMeaning)
                    Button("Exact text only") { assistant.byMeaning = false; assistant.findChanged() }
                }
            WorkInput(text: $assistant.query, placeholder: "Find…", identifier: "page-find", fontSize: 12,
                      palette: palette, submit: { assistant.moveMatch(1) }, cancel: assistant.closePanel,
                      moveSelection: assistant.moveMatch)
                .frame(minWidth: 70, maxWidth: .infinity).frame(height: 22)
                .onChange(of: assistant.query) { _, _ in assistant.findChanged() }
            Group {
                if assistant.busy { ProgressView().controlSize(.mini) }
                else if !assistant.matches.isEmpty { Text("\(assistant.matchIndex + 1)/\(assistant.matches.count)").monospacedDigit() }
                else { Text(assistant.exactMatched ? "✓" : "0") }
            }
            .font(.system(size: 10)).foregroundStyle(palette.textDim).frame(minWidth: 26)
            .help(assistant.status).accessibilityLabel(assistant.status)
            Button { assistant.moveMatch(-1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: SidebarMetrics.headerControl) }
                .accessibilityLabel("Previous match")
            Button { assistant.moveMatch(1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: SidebarMetrics.headerControl) }
                .accessibilityLabel("Next match")
            Button(action: assistant.closePanel) { Image(systemName: "xmark").frame(width: 22, height: SidebarMetrics.headerControl) }
                .accessibilityLabel("Close find")
        }
        .padding(.horizontal, 6)
        .onChange(of: assistant.byMeaning) { _, _ in assistant.findChanged() }
        .onExitCommand(perform: assistant.closePanel)
    }
}
