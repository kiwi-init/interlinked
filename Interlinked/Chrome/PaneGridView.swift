import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A tab dragged out of the open pages list. Private, so web pages never
    /// accept it and the drop reaches Interlinked.
    static let interlinkedTab = UTType(exportedAs: "computer.interlinked.tab")
}

extension NSItemProvider {
    static func tab(_ id: TabID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.interlinkedTab.identifier, visibility: .ownProcess) { completion in
            completion(Data(String(id.rawValue).utf8), nil)
            return nil
        }
        return provider
    }
}

/// One page, or two side by side. Every page renders from the same list so the
/// first keeps its identity, and its web view, when the second appears.
struct SplitLayout: View {
    @Environment(Workspace.self) private var workspace
    var tab: Tab
    var palette: Palette

    @State private var dropSide: DropSide?
    @State private var width: CGFloat = 0
    /// The ratio while the divider is being dragged; saved when it's let go.
    @State private var dragRatio: Double?

    enum DropSide { case leading, trailing }

    var body: some View {
        let panes = tab.panes
        HStack(spacing: 0) {
            ForEach(Array(panes.enumerated()), id: \.element) { index, pane in
                if index > 0 {
                    divider
                }
                BrowserPage(pane: pane, palette: palette)
                    // The first page takes its share; the second fills the rest.
                    .frame(width: index == 0 && panes.count == 2 ? firstWidth : nil)
                    .overlay {
                        // The page the chrome is not following steps back a little.
                        if panes.count > 1 && pane != tab.active {
                            Color.black.opacity(0.16)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: tab.active)
            }
        }
        .coordinateSpace(.named("split"))
        .overlay { dropPreview }
        .animation(dragRatio == nil ? Metrics.morph : nil, value: tab.splitRatio)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onDrop(of: [.interlinkedTab], delegate: TabDropDelegate(width: width, side: $dropSide, workspace: workspace))
    }

    private var firstWidth: CGFloat {
        max(0, (width - 1) * (dragRatio ?? tab.splitRatio))
    }

    /// A hairline with a wider grip that drags to resize the two pages.
    private var divider: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .cursorRegion(.resizeLeftRight)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                            .onChanged { value in
                                guard width > 0 else { return }
                                dragRatio = Double(value.location.x / width).clamped(to: Tab.ratioRange)
                            }
                            .onEnded { _ in
                                if let dragRatio { workspace.setSplitRatio(dragRatio) }
                                dragRatio = nil
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Split divider")
                    .accessibilityValue("\(Int((dragRatio ?? tab.splitRatio) * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        let step = direction == .increment ? 0.05 : -0.05
                        workspace.setSplitRatio(tab.splitRatio + step)
                    }
            }
            .zIndex(1)
    }

    /// Where the dragged page will land: the half it would take.
    @ViewBuilder
    private var dropPreview: some View {
        if let dropSide {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.accent.opacity(0.14))
                    .strokeBorder(palette.accent.opacity(0.7), lineWidth: 2)
                    .overlay {
                        Label(tab.isSplit ? "Replace this side" : "Open side by side", systemImage: "rectangle.split.2x1")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .modifier(PageGlass(radius: 12))
                    }
                    .frame(width: geometry.size.width / 2 - 16, height: geometry.size.height - 32)
                    .offset(x: dropSide == .leading ? 16 : geometry.size.width / 2, y: 16)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    var width: CGFloat
    @Binding var side: SplitLayout.DropSide?
    var workspace: Workspace

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.interlinkedTab]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        withAnimation(.easeOut(duration: 0.12)) { side = resolve(info) }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.12)) { side = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let landing = resolve(info)
        side = nil
        guard let provider = info.itemProviders(for: [.interlinkedTab]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.interlinkedTab.identifier) { data, _ in
            guard let data, let raw = UInt64(String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in workspace.dropTab(TabID(raw), leading: landing == .leading) }
        }
        return true
    }

    private func resolve(_ info: DropInfo) -> SplitLayout.DropSide {
        info.location.x < width / 2 ? .leading : .trailing
    }
}

struct BrowserPage: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID
    var palette: Palette

    var body: some View {
        Group {
            if workspace.onboarding.contains(pane) {
                OnboardingView(palette: palette)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { workspace.clickPane(pane) })
            } else if let recovery = workspace.hosts.recovery(for: pane) {
                BrowserRecoveryView(pane: pane, recovery: recovery, palette: palette)
            } else if !workspace.surfaces.holdsPage(pane) {
                // A web page reports its own clicks; a new tab page is SwiftUI.
                EmptyPaneView(palette: palette)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { workspace.clickPane(pane) })
            } else {
                BrowserPane(pane: pane)
            }
        }
        .background(palette.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowserRecoveryView: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID
    var recovery: BrowserRecovery
    var palette: Palette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: recovery.cause == .memoryPressure ? "memorychip" : "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(palette.textDim)
            VStack(spacing: 6) {
                Text(recovery.cause.title)
                    .font(.system(size: 16, weight: .semibold))
                Text(recovery.cause.message)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }
            Button(recovery.cause.action) { workspace.recoverPane(pane) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("browser-recovery-action")
                .pointingHandCursor()
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-recovery")
    }
}
