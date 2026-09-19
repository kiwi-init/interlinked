import SwiftUI
import WebKit

struct BrowserPane: NSViewRepresentable {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID

    func makeNSView(context: Context) -> WKWebView {
        let view = workspace.hosts.browser(for: pane, workspace: workspace)
        let line = workspace.surfaces.line(pane)
        if view.url == nil {
            view.load(URLRequest(url: address(from: line)))
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Navigation is driven by committing the line, not by every body pass.
    }
}
