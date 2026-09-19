import SwiftUI

/// One continuous shape holds the icon, address, open work, and voice feedback.
struct PageHandle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    var available: CGSize
    private var hovering: Bool { workspace.quickSwitchOpen }

    private var pane: PaneID? { workspace.activePane }
    private var expanded: Bool { workspace.assistance.panel == .permission || workspace.overviewOpen || hovering || workspace.editing != nil }
    private var showsTabs: Bool { workspace.assistance.panel != .permission && !workspace.overviewOpen && (hovering || workspace.editing != nil) && voiceCaption == nil }
    private var identity: String {
        guard let pane else { return "All tabs" }
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
    private var tabRows: [Range<Int>] { OpenWork.rows(count: workspace.tabs.count) }
    private var resultsHeight: CGFloat {
        min(CGFloat((workspace.searchResults.count + workspace.assistance.historyResults.count) * 42 + (workspace.searchResults.isEmpty ? 0 : 22) + (showsHistory ? 62 : 0)), max(84, available.height - 170))
    }
    private var showsHistory: Bool {
        guard let edit = workspace.editing, edit.pane != nil else { return false }
        return edit.text.count >= 2 && navigationURL(from: edit.text) == nil
    }
    private var tabsHeight: CGFloat {
        min(CGFloat(tabRows.count * 42), max(42, available.height - 112 - resultsHeight))
    }
    private var controlsHeight: CGFloat { 76 + tabsHeight }
    private var size: CGSize {
        if workspace.assistance.panel == .permission {
            return CGSize(width: min(370, available.width - 36), height: min(335, available.height - 36))
        }
        if workspace.overviewOpen { return overviewSize }
        if voiceCaption != nil { return CGSize(width: min(340, available.width - 36), height: 44) }
        if showsTabs {
            let address = workspace.editing?.text ?? pane.map { workspace.assistance.label($0, url: workspace.surfaces.line($0)) } ?? ""
            let text = address.isEmpty ? "Search or address" : address
            let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            let tabsWidth = CGFloat((tabRows.first?.count ?? 0) * 40 + 16)
            return CGSize(width: min(max(showsHistory || !workspace.searchResults.isEmpty ? 320 : 180, tabsWidth, textWidth + 76), available.width - 36),
                          height: controlsHeight + resultsHeight)
        }
        let labelWidth = (identity as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return CGSize(width: min(labelWidth + 62, 240, available.width - 36), height: 44)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if workspace.assistance.panel == .permission { AssistanceView(palette: palette) }
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
                        browserControl("New page", symbol: "plus", id: "new-page", action: workspace.newPage)
                        browserControl("Close page", symbol: "xmark", id: "browser-close") {
                            workspace.discardLine()
                            workspace.closeActive()
                        }
                        .disabled(pane == nil)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 32)
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                ForEach(tabRows, id: \.lowerBound) { row in
                                    HStack(spacing: 0) {
                                        ForEach(Array(workspace.tabs[row])) { tab in
                                            Button { workspace.selectWork(tab.id) } label: {
                                                SiteIcon(pane: tab.active, palette: palette, framed: false)
                                                    .frame(width: 40, height: 38)
                                                    .background(workspace.activeTab?.id == tab.id ? palette.text.opacity(0.12) : .clear,
                                                                in: RoundedRectangle(cornerRadius: 10))
                                                  .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .id(tab.id)
                                            .accessibilityLabel("Switch to \(workspace.title(tab))")
                                            .accessibilityIdentifier("quick-tab-\(tab.id.rawValue)")
                                            .accessibilityAddTraits(workspace.activeTab?.id == tab.id ? .isSelected : [])
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: 42)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .scrollIndicators(.hidden)
                        .onAppear { if let tab = workspace.activeTab { proxy.scrollTo(tab.id) } }
                        .onChange(of: workspace.activeTab?.id) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                    .frame(height: tabsHeight)
                }
                .padding(.bottom, 44)
                .transition(.opacity)
            }
            if workspace.editing != nil && (!workspace.searchResults.isEmpty || showsHistory) {
                ScrollView { VStack(alignment: .leading, spacing: 0) {
                    if showsHistory { historyResults }
                    if !workspace.searchResults.isEmpty { Text("Bing results")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(palette.textDim)
                        .padding(.horizontal, 14)
                        .frame(height: 22) }
                    ForEach(Array(workspace.searchResults.enumerated()), id: \.element.id) { index, result in
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
                            .background(workspace.selectedSearchResult == index + workspace.assistance.historyResults.count ? palette.text.opacity(0.12) : .clear)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-result-\(index)")
                        .accessibilityAddTraits(workspace.selectedSearchResult == index + workspace.assistance.historyResults.count ? .isSelected : [])
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
            HStack(spacing: 2) {
                Button { workspace.toggleOverview() } label: {
                    SiteIcon(pane: pane, palette: palette, framed: false)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(workspace.overviewOpen ? "Return to page" : "Show all tabs, \(identity)")
                .accessibilityIdentifier("page-handle")
                if showsTabs || workspace.editing != nil {
                    LineEditor(palette: palette)
                        .padding(.trailing, 14)
                } else if let caption = voiceCaption, !workspace.overviewOpen {
                    Label(caption, systemImage: workspace.voice.state.isListening ? "waveform" : "mic")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.trailing, 14)
                } else {
                    Button { workspace.editActiveLine() } label: {
                        JevLabel(identity: identity, pane: pane, effect: workspace.assistance.labelEffect)
                            .lineLimit(1)
                            .padding(.trailing, 16)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit address, \(identity)")
                    .accessibilityIdentifier("page-address")
                    .help(pane.map { workspace.surfaces.line($0) } ?? "")
                }
            }
            .frame(height: 44)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: workspace.overviewOpen ? 20 : 14, style: .continuous))
        .modifier(PageGlass(radius: workspace.overviewOpen ? 20 : 14))
        .modifier(JevLabelGlow(effect: workspace.assistance.labelEffect, pane: pane,
                               radius: workspace.overviewOpen ? 20 : 14))
        .foregroundStyle(palette.text)
        .onHover { workspace.quickSwitchOpen = $0 }
        .onChange(of: workspace.addressResults.map(\.id)) { _, _ in workspace.selectedSearchResult = nil }
        .animation(reduceMotion ? nil : Metrics.morph, value: size)
        .animation(reduceMotion ? nil : Metrics.morph, value: expanded)
    }

    private var historyResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Vault").font(.system(size: 9, weight: .medium))
                Spacer()
                if !workspace.assistance.historySharing {
                    Button("Find by description…") { workspace.assistance.shareHistorySearch() }
                        .font(.system(size: 9))
                        .help("Send this query and relevant excerpts from up to 24 saved pages to OpenRouter / TypeSafe while editing. Full URLs are not sent.")
                        .accessibilityIdentifier("history-by-meaning")
                }
            }.padding(.horizontal, 14).frame(height: 22)
            Text(workspace.assistance.historySharing ? workspace.assistance.historyStatus : "Description search sends query + saved excerpts to Jev.")
                .font(.system(size: 9)).foregroundStyle(palette.textDim).lineLimit(2)
                .padding(.horizontal, 14).frame(height: 40)
            ForEach(Array(workspace.assistance.historyResults.enumerated()), id: \.element.id) { index, visit in
                Button { if let url = URL(string: visit.url) { workspace.openSearchResult(SearchResult(title: visit.title, url: url)) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(visit.title).font(.system(size: 12)).lineLimit(1)
                        Text(visit.host).font(.system(size: 10)).foregroundStyle(palette.textDim).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 42)
                }.buttonStyle(.plain)
                .background(workspace.selectedSearchResult == index ? palette.text.opacity(0.12) : .clear)
                .contextMenu { Button("Forget this page") { workspace.assistance.forgetVisit(visit.id) } }
            }
        }
    }

    private func browserControl(_ label: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

}

/// Jev's chosen label arrives with a brief spectrum sweep. The ordinary local
/// label and user-authored tab names retain the browser's normal text color.
private struct JevLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var identity: String
    var pane: PaneID?
    var effect: JevLabelEffect?
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

/// A restrained version of the Apple Intelligence spectrum glow. It hugs the
/// glass handle only while the Jev-authored label is being revealed.
private struct JevLabelGlow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var effect: JevLabelEffect?
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
        .onChange(of: effect) { _, update in
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
}

struct PageGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let backing = scheme == .dark ? Color.black : Color.white
        let opacity = reduceTransparency || contrast == .increased ? 1.0 : 0.76
        let readable = content.background(backing.opacity(opacity), in: shape)
        Group {
            if reduceTransparency {
                readable
            } else if #available(macOS 26.0, *) {
                readable.glassEffect(.regular.interactive(), in: shape)
            } else {
                readable.background(.ultraThinMaterial, in: shape)
            }
        }
        // Glass is visual only. Claim its empty space as well as its controls,
        // so the web view underneath cannot receive clicks through the panel.
        .contentShape(shape)
        .onTapGesture { }
        .background(PageControlRegion(radius: radius))
    }
}

/// AppKit's hit test can see WebKit below SwiftUI controls before SwiftUI routes
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
        regions.allObjects.contains { view in
            guard view.window != nil, view.window === event.window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            return NSBezierPath(roundedRect: view.bounds, xRadius: view.radius, yRadius: view.radius).contains(point)
        }
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
