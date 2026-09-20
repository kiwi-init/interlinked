import AppKit
import SwiftUI

/// One continuous shape holds the icon, address, open work, and voice feedback.
struct PageHandle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var palette: Palette
    var available: CGSize
    private var hovering: Bool { workspace.quickSwitchOpen || workspace.leftCommandKeyHeld }

    private var pane: PaneID? { workspace.activePane }
    private var expanded: Bool { workspace.overviewOpen || hovering || workspace.editing != nil }
    private var showsTabs: Bool { !workspace.overviewOpen && (hovering || workspace.editing != nil) && voiceCaption == nil }
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
    private var quickTabs: [Tab] { workspace.quickTabs }
    private var resultsHeight: CGFloat {
        min(CGFloat((workspace.searchResults.count + workspace.assistance.historyResults.count) * 42 + (workspace.searchResults.isEmpty ? 0 : 22) + (showsHistory ? 22 : 0)), max(84, available.height - 170))
    }
    private var showsHistory: Bool {
        workspace.editing?.pane != nil && !workspace.assistance.historyResults.isEmpty
    }
    private var tabsHeight: CGFloat {
        min(CGFloat(quickTabs.count * 42), max(0, available.height - 112 - resultsHeight))
    }
    private var controlsHeight: CGFloat { 76 + tabsHeight }
    private var size: CGSize {
        if workspace.overviewOpen { return overviewSize }
        if voiceCaption != nil { return CGSize(width: min(340, available.width - 36), height: 44) }
        if showsTabs {
            let address = workspace.editing?.text ?? pane.map { workspace.assistance.label($0, url: workspace.surfaces.line($0)) } ?? ""
            let text = address.isEmpty ? "Search or address" : address
            let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            let tabsWidth = quickTabs.map { tab in
                (workspace.title(tab) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 96
            }.max() ?? 0
            return CGSize(width: min(max(showsHistory || !workspace.searchResults.isEmpty ? 320 : 220, tabsWidth, textWidth + 76), available.width - 36),
                          height: controlsHeight + resultsHeight)
        }
        let labelWidth = (identity as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
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
                                            SiteIcon(pane: tab.active, palette: palette, framed: false)
                                                .frame(width: 28, height: 28)
                                            Text(workspace.title(tab))
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
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
                                    .accessibilityLabel(index < 9 ? "Switch to \(workspace.title(tab)), Command \(index + 1)" : "Switch to \(workspace.title(tab))")
                                    .accessibilityIdentifier("quick-tab-\(tab.id.rawValue)")
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: tabsHeight)
                    }
                }
                .padding(.bottom, 44)
                .transition(.opacity)
            }
            if workspace.editing != nil && (!workspace.searchResults.isEmpty || showsHistory) {
                ScrollView { VStack(alignment: .leading, spacing: 0) {
                    if showsHistory { historyResults }
                    if !workspace.searchResults.isEmpty { Text("Google suggestions")
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
                        .buttonStyle(.pointing)
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
                if showsTabs && workspace.editing == nil {
                    LineEditor(palette: palette)
                        .padding(.trailing, 8)
                    Text(workspace.showsCopiedPageURL ? "Copied" : "⇧⌘C")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                        .padding(.trailing, 14)
                        .help(workspace.showsCopiedPageURL ? "Page URL copied" : "Copy page URL")
                } else if workspace.editing != nil {
                    LineEditor(palette: palette)
                        .padding(.trailing, 14)
                } else if let caption = voiceCaption, !workspace.overviewOpen {
                    Label(caption, systemImage: workspace.voice.state.isListening ? "waveform" : "mic")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.trailing, 14)
                } else {
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
                            .padding(.trailing, 16)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointing)
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
        .modifier(AILabelGlow(effect: workspace.assistance.labelEffect, pane: pane,
                               radius: workspace.overviewOpen ? 20 : 14))
        .foregroundStyle(palette.text)
        .onHover { workspace.quickSwitchOpen = $0 }
        .onChange(of: workspace.addressResults.map(\.id)) { _, _ in workspace.selectedSearchResult = nil }
        .animation(reduceMotion ? nil : Metrics.morph, value: size)
        .animation(reduceMotion ? nil : Metrics.morph, value: expanded)
    }

    private var historyResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vault")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(palette.textDim)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            ForEach(Array(workspace.assistance.historyResults.enumerated()), id: \.element.id) { index, visit in
                Button { if let url = URL(string: visit.url) { workspace.openSearchResult(SearchResult(title: visit.title, url: url)) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(visit.title).font(.system(size: 12)).lineLimit(1)
                        Text(visit.host).font(.system(size: 10)).foregroundStyle(palette.textDim).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 42)
                }.buttonStyle(.pointing)
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
        .buttonStyle(.pointing)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
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

/// A restrained version of the Apple Intelligence spectrum glow. It hugs the
/// glass handle only while the AI-refined label is being revealed.
private struct AILabelGlow: ViewModifier {
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
}

private struct PointingCursorRegion: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    final class CursorView: NSView {
        var cursor = NSCursor.pointingHand

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: cursor)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> CursorView {
        CursorView()
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = isEnabled ? .pointingHand : .arrow
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
