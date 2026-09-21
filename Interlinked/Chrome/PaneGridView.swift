import SwiftUI

/// One page, or two side by side. Every page renders from the same list so the
/// first keeps its identity, and its web view, when the second appears.
struct SplitLayout: View {
    @Environment(Workspace.self) private var workspace
    var tab: Tab
    var palette: Palette

    var body: some View {
        let panes = tab.panes
        HStack(spacing: 0) {
            ForEach(Array(panes.enumerated()), id: \.element) { index, pane in
                if index > 0 {
                    Rectangle()
                        .fill(palette.hairline)
                        .frame(width: 1)
                }
                BrowserPage(pane: pane, palette: palette)
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
    }
}

struct BrowserPage: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID
    var palette: Palette

    var body: some View {
        Group {
            if let recovery = workspace.hosts.recovery(for: pane) {
                BrowserRecoveryView(pane: pane, recovery: recovery, palette: palette)
            } else if workspace.surfaces.line(pane).isEmpty {
                // Chromium reports its own clicks; a new tab page is SwiftUI.
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
