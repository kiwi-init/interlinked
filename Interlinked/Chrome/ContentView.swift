import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let palette = Palette.of(colorScheme, tint: workspace.tint)
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                detail(palette: palette)
                PageHandle(palette: palette, available: geometry.size)
                    .padding(18)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    UsefulInfoStack(palette: palette)
                    Toolbox(palette: palette)
                }
                .padding(18)
            }
            .overlay(alignment: .topTrailing) {
                PageActions(palette: palette, available: geometry.size)
                    .padding(18)
            }
            .overlay {
                // Where the eye is after ⌘T, just below the new tab page's quote.
                OnboardingCoach(palette: palette)
                    .offset(y: 120)
            }
        }
        .background(palette.pane)
        .background(WindowChrome())
        .frame(minWidth: 640, minHeight: 400)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear {
            workspace.openSettings = { openSettings() }
            workspace.start()
        }
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
                SplitLayout(tab: tab, palette: palette)
                    .id(tab.id.rawValue)
            } else {
                palette.pane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
