import AppKit
import SwiftUI

/// Transparent native titlebar. The content must extend beyond its safe area
/// without an outer clip, or SwiftUI leaves a strip behind the traffic lights.
struct WindowChrome: NSViewRepresentable {
    @Environment(Workspace.self) private var workspace
    @Binding var fullScreen: Bool

    final class Coordinator {
        weak var configuredWindow: NSWindow?
        var buttons: WindowButtonPlacement?
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
        let fullScreen = $fullScreen
        DispatchQueue.main.async { [weak view, weak coordinator, weak workspace] in
            guard let window = view?.window, coordinator?.configuredWindow !== window else { return }
            Self.configure(window)
            coordinator?.configuredWindow = window
            coordinator?.buttons = WindowButtonPlacement(window: window) { fullScreen.wrappedValue = $0 }
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

/// Glass behind the traffic lights, which AppKit draws on top. Dragging it
/// moves the window, like the titlebar it stands in for.
struct WindowButtonsGlass: View {
    var body: some View {
        let glass = WindowButtonPlacement.glass
        Color.clear
            .frame(width: glass.width, height: glass.height)
            .modifier(PageGlass(radius: glass.height / 2))
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .padding(.leading, glass.minX)
            .padding(.top, glass.minY)
            .accessibilityHidden(true)
    }
}

/// Centers the traffic lights on `WindowButtonsGlass`. AppKit puts them back
/// in its own place whenever it lays out the titlebar, so this view sits in the
/// titlebar and moves them again from its own layout, which runs after its
/// superview's. In full screen they keep the system's place and the glass hides.
final class WindowButtonPlacement: NSView {
    /// The glass, from the window's top left.
    static let glass = CGRect(x: 8, y: 8, width: 78, height: 28)

    /// In full screen the titlebar moves to another window, so keep this one.
    private weak var browserWindow: NSWindow?
    private let buttons: [NSButton]
    /// Each button's distance from the first, as AppKit spaces them.
    private let offsets: [CGFloat]
    private let fullScreenChanged: (Bool) -> Void

    init?(window: NSWindow, fullScreenChanged: @escaping (Bool) -> Void) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap(window.standardWindowButton)
        window.layoutIfNeeded()
        guard buttons.count == 3, let bar = buttons[0].superview else { return nil }
        let offsets = buttons.map { $0.frame.minX - buttons[0].frame.minX }
        guard offsets[1] > 0, offsets[2] > offsets[1] else { return nil }
        browserWindow = window
        self.buttons = buttons
        self.offsets = offsets
        self.fullScreenChanged = fullScreenChanged
        super.init(frame: bar.bounds)
        // Resizing with the titlebar is what schedules this view's layout.
        autoresizingMask = [.width, .height]
        bar.addSubview(self)
        let center = NotificationCenter.default
        for button in buttons {
            button.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(buttonMoved),
                               name: NSView.frameDidChangeNotification, object: button)
        }
        center.addObserver(self, selector: #selector(willEnterFullScreen),
                           name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didExitFullScreen),
                           name: NSWindow.didExitFullScreenNotification, object: window)
        fullScreenChanged(window.styleMask.contains(.fullScreen))
        place()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        place()
    }

    /// Where each button belongs in the titlebar, or nil to leave them be.
    private var targets: [NSPoint]? {
        guard let window = browserWindow, !window.styleMask.contains(.fullScreen), let bar = superview else { return nil }
        let width = offsets[2] + buttons[2].frame.width
        let left = Self.glass.midX - width / 2
        let top = Self.glass.midY - buttons[0].frame.height / 2
        // Window coordinates count up from the bottom.
        let frames = zip(buttons, offsets).map { button, offset in
            bar.convert(NSRect(x: left + offset, y: window.frame.height - top - button.frame.height,
                               width: button.frame.width, height: button.frame.height), from: nil)
        }
        // A button outside the titlebar would not receive clicks.
        guard frames.allSatisfy(bar.bounds.contains) else { return nil }
        return frames.map(\.origin)
    }

    private func place() {
        guard let targets, let bar = superview,
              zip(buttons, targets).contains(where: { $0.frame.origin != $1 }) else { return }
        for (button, origin) in zip(buttons, targets) {
            button.setFrameOrigin(origin)
        }
        // The hover that shows the buttons' symbols is tracked from where they are.
        bar.updateTrackingAreas()
    }

    /// AppKit can also move them outside a titlebar layout.
    @objc private func buttonMoved() {
        guard let targets, zip(buttons, targets).contains(where: { $0.frame.origin != $1 }) else { return }
        needsLayout = true
    }

    @objc private func willEnterFullScreen() {
        fullScreenChanged(true)
    }

    @objc private func didExitFullScreen() {
        fullScreenChanged(false)
        needsLayout = true
    }
}
