import SwiftUI

struct BrowserPane: NSViewRepresentable {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID

    func makeNSView(context: Context) -> NSView {
        workspace.hosts.browser(for: pane, workspace: workspace).nativeView
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Navigation is driven by committing the line, not by every body pass.
    }
}
