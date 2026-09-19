import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.of(colorScheme, tint: workspace.tint)
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                detail(palette: palette)
                PageHandle(palette: palette, available: geometry.size)
                    .padding(18)
            }
            .overlay(alignment: .bottomTrailing) {
                PageTools(palette: palette).padding(18)
            }
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
        // in the window; opacity alone leaves WebKit's background pages visible.
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
