import AppKit
import SwiftUI

/// Transparent native titlebar. The content must extend beyond its safe area
/// without an outer clip, or SwiftUI leaves a strip behind the traffic lights.
struct WindowChrome: NSViewRepresentable {
    @Environment(Workspace.self) private var workspace

    final class Coordinator {
        weak var configuredWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.configuredWindow !== view.window else { return }
        configureWhenAttached(view, coordinator: context.coordinator)
    }

    private func configureWhenAttached(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async { [weak view, weak coordinator, weak workspace] in
            guard let window = view?.window, coordinator?.configuredWindow !== window else { return }
            Self.configure(window)
            coordinator?.configuredWindow = window
            workspace?.browserWindow = window
        }
    }

    private static func configure(_ window: NSWindow) {
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
