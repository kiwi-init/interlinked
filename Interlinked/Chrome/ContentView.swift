import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    #if DEBUG
    @State private var intelligenceDebug = DebugIntelligenceMonitor.shared
    #endif

    var body: some View {
        let palette = Palette.of(colorScheme, tint: workspace.tint)
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                detail(palette: palette)
                PageHandle(palette: palette, available: geometry.size)
                    .padding(18)
            }
            .overlay(alignment: .bottomTrailing) {
                Toolbox(palette: palette)
                    .padding(18)
            }
            .overlay(alignment: .top) {
                if workspace.siteMenu != nil {
                    SiteMenuBar(palette: palette, available: geometry.size)
                        .padding(.top, 18)
                        .padding(.horizontal, 160)
                }
            }
            .overlay(alignment: .topTrailing) {
                PageActions(palette: palette, available: geometry.size)
                    .padding(18)
            }
            #if DEBUG
            .overlay(alignment: .top) {
                DebugIntelligenceBadge(monitor: intelligenceDebug, palette: palette)
                    .padding(.top, 18)
            }
            #endif
        }
        .background(palette.pane)
        .background(WindowChrome())
        .frame(minWidth: 640, minHeight: 400)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { workspace.start() }
        .onExitCommand {
            workspace.escape()
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private func detail(palette: Palette) -> some View {
        // PaneHosts retains native views and their state. Only visible pages belong
        // in the window; opacity alone leaves Chromium's child view visible.
        Group {
            if let tab = workspace.activeTab {
                BrowserPage(pane: tab.active, palette: palette)
                    .id(tab.id.rawValue)
            } else {
                palette.pane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
private struct DebugIntelligenceBadge: View {
    @Bindable var monitor: DebugIntelligenceMonitor
    var palette: Palette

    var body: some View {
        if let activity = monitor.current {
            HStack(spacing: 7) {
                switch activity.phase {
                case .running:
                    ProgressView().controlSize(.mini)
                case .completed:
                    Image(systemName: "checkmark")
                case .failed:
                    Image(systemName: "xmark")
                }
                Text(activity.source.rawValue)
                    .fontWeight(.semibold)
                Text("·")
                Text(activity.action)
            }
            .font(.system(size: 10))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .modifier(PageGlass(radius: 12))
            .accessibilityLabel("\(activity.source.rawValue), \(activity.action), \(phaseLabel(activity.phase))")
            .transition(.opacity)
        }
    }

    private func phaseLabel(_ phase: DebugIntelligencePhase) -> String {
        switch phase {
        case .running: "running"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}
#endif
