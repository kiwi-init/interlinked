import SwiftUI

struct BrowserPage: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID
    var palette: Palette

    var body: some View {
        Group {
            if workspace.surfaces.line(pane).isEmpty {
                EmptyPaneView(palette: palette)
            } else {
                BrowserPane(pane: pane)
            }
        }
        .background(palette.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
