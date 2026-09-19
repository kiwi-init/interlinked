import AppKit
import SwiftUI

/// Transparent native titlebar. The content must extend beyond its safe area
/// without an outer clip, or SwiftUI leaves a strip behind the traffic lights.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.configure(view.window) }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.unifiedTitleAndToolbar)
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.title = "Interlinked"
        window.isMovableByWindowBackground = true
    }
}
