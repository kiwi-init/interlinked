import AppKit
import SwiftUI

/// Connection details for the current origin. Page labels never appear here.
struct IdentityInspector: View {
    @Environment(Workspace.self) private var workspace
    var origin: TrustedOrigin?
    var palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connection")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { workspace.closeIdentity() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.pointing)
                    .accessibilityLabel("Close connection details")
                    .accessibilityIdentifier("close-identity")
            }
            if let origin {
                HStack(spacing: 6) {
                    Image(systemName: origin.transport == .http ? "exclamationmark.triangle.fill" : "lock.fill")
                        .foregroundStyle(origin.transport == .http ? Color(red: 0.82, green: 0.38, blue: 0.08) : palette.text)
                    Text(origin.transport.compactLabel)
                        .fontWeight(.medium)
                        .foregroundStyle(origin.transport == .http ? Color(red: 0.82, green: 0.38, blue: 0.08) : palette.text)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(origin.accessibilityLabel)
                labeled("Site", origin.displayHost)
                if origin.usesPunycode {
                    labeled("Encoded host", origin.asciiHost)
                }
                labeled("Address", origin.fullURL)
                if origin.mixedScript {
                    Text("This hostname mixes writing systems and may imitate another site.")
                        .foregroundStyle(Color(red: 0.82, green: 0.38, blue: 0.08))
                }
                if origin.transport == .http {
                    Text("This connection is not encrypted. Anything you send can be read on the network.")
                        .foregroundStyle(Color(red: 0.82, green: 0.38, blue: 0.08))
                }
                HStack {
                    Button("Edit Address", action: workspace.editActiveLine)
                        .pointingHandCursor()
                        .accessibilityIdentifier("identity-edit-address")
                    Spacer()
                    Button("Copy URL") { _ = workspace.copyCurrentPageURL() }
                        .pointingHandCursor()
                        .accessibilityIdentifier("identity-copy-url")
                }
            } else {
                Text("No remote page is active.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .onExitCommand { workspace.closeIdentity() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("identity-inspector")
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(palette.textDim)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .accessibilityIdentifier("identity-\(title.lowercased())")
        }
    }
}

/// An AI-refined label arrives with a brief spectrum sweep. The ordinary local
/// label and user-authored tab names retain the browser's normal text color.
struct AILabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var identity: String
    var pane: PaneID?
    var effect: AILabelEffect?
    @State private var sweep: CGFloat = -1
    @State private var rainbowOpacity = 0.0

    private let colors: [Color] = [
        Color(red: 0.20, green: 0.72, blue: 1.00),
        Color(red: 0.48, green: 0.36, blue: 1.00),
        Color(red: 0.94, green: 0.31, blue: 0.78),
        Color(red: 1.00, green: 0.47, blue: 0.28),
        Color(red: 0.27, green: 0.88, blue: 0.80)
    ]

    var body: some View {
        Text(identity)
            .font(.system(size: 12))
            .overlay {
                GeometryReader { geometry in
                    let width = max(52, geometry.size.width * 0.72)
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                        .offset(x: ((sweep + 1) / 2) * (geometry.size.width + width) - width)
                }
                .mask {
                    Text(identity)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .opacity(rainbowOpacity)
                .accessibilityHidden(true)
            }
            .onChange(of: effect) { _, update in
                guard update?.pane == pane else { return }
                sweep = reduceMotion ? 0 : -1
                rainbowOpacity = 1
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 1.15)) { sweep = 1 }
                }
                withAnimation(.easeOut(duration: 0.5).delay(reduceMotion ? 0.25 : 0.85)) {
                    rainbowOpacity = 0
                }
            }
    }
}

/// A restrained version of the Apple Intelligence spectrum glow. It hugs a
/// row only while an AI-refined result is being revealed: the tab's label in
/// the sidebar.
struct AILabelGlow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var effect: AILabelEffect?
    var pane: PaneID?
    var radius: CGFloat
    @State private var glowOpacity = 0.0
    @State private var hue = 0.0

    private var gradient: AngularGradient {
        AngularGradient(colors: [
            Color(red: 0.20, green: 0.72, blue: 1.00),
            Color(red: 0.48, green: 0.36, blue: 1.00),
            Color(red: 0.94, green: 0.31, blue: 0.78),
            Color(red: 1.00, green: 0.47, blue: 0.28),
            Color(red: 0.27, green: 0.88, blue: 0.80),
            Color(red: 0.20, green: 0.72, blue: 1.00)
        ], center: .center)
    }

    func body(content: Content) -> some View {
        content.overlay {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.stroke(gradient, lineWidth: 3).blur(radius: 4).opacity(0.55)
                shape.stroke(gradient, lineWidth: 1.25)
            }
            .hueRotation(.degrees(hue))
            .opacity(glowOpacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // A panel can be created by the same result that lights it up, so the
        // effect has to be honored on arrival as well as on change.
        .onAppear { reveal(effect) }
        .onChange(of: effect) { _, update in reveal(update) }
    }

    private func reveal(_ update: AILabelEffect?) {
        guard update?.pane == pane else { return }
        hue = 0
        glowOpacity = 1
        if !reduceMotion {
            withAnimation(.linear(duration: 1.25)) { hue = 150 }
        }
        withAnimation(.easeOut(duration: 0.55).delay(reduceMotion ? 0.25 : 0.85)) {
            glowOpacity = 0
        }
    }
}

struct PageGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let backing = scheme == .dark ? Color.black : Color.white
        Group {
            if reduceTransparency || contrast == .increased {
                content.background(backing, in: shape)
            } else if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        }
        // Glass is visual only. Claim its empty space as well as its controls,
        // so the web view underneath cannot receive clicks through the panel.
        .contentShape(shape)
        .onTapGesture { }
        .background(PageControlRegion(radius: radius))
    }
}

struct PointingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pointingHandCursor()
    }
}

extension ButtonStyle where Self == PointingButtonStyle {
    static var pointing: PointingButtonStyle { PointingButtonStyle() }
}

extension View {
    func pointingHandCursor() -> some View {
        background(PointingCursorRegion())
    }

    /// A region that shows `cursor` instead of the pointing hand, like a divider's.
    func cursorRegion(_ cursor: NSCursor) -> some View {
        background(PointingCursorRegion(cursor: cursor))
    }
}

private struct PointingCursorRegion: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var cursor: NSCursor = .pointingHand
    fileprivate static let regions = NSHashTable<CursorView>.weakObjects()

    final class CursorView: NSView {
        var cursor = NSCursor.pointingHand

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: cursor)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> CursorView {
        let view = CursorView()
        Self.regions.add(view)
        return view
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = isEnabled ? cursor : .arrow
        view.window?.invalidateCursorRects(for: view)
    }
}

/// AppKit's hit test can see the page below SwiftUI controls before SwiftUI routes
/// the event. Track the actual panel bounds before deciding a click is outside.
struct PageControlRegion: NSViewRepresentable {
    var radius: CGFloat
    private static let regions = NSHashTable<RegionView>.weakObjects()

    final class RegionView: NSView {
        var radius: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.radius = radius
        Self.regions.add(view)
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) { view.radius = radius }

    static func contains(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return contains(event.locationInWindow, in: window)
    }

    static func contains(_ location: NSPoint, in window: NSWindow) -> Bool {
        regions.allObjects.contains { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let point = view.convert(location, from: nil)
            return NSBezierPath(roundedRect: view.bounds, xRadius: view.radius, yRadius: view.radius).contains(point)
        }
    }
}

/// Glass can float over the page, which repaints the cursor for whatever
/// content sits underneath. Over Interlinked's own controls the page gives the
/// cursor up: clickable controls show the pointing hand, the rest of the glass
/// the arrow, and the page's cursor returns when the mouse moves on it again.
@MainActor
enum ChromeCursor {
    private static var monitor: Any?
    private static var owning = false

    static func install() {
        guard monitor == nil else { return }
        PageWebView.chromeOwnsCursor = {
            MainActor.assumeIsolated { cursorUnderMouse() != nil }
        }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseUp, .leftMouseDragged, .scrollWheel]
        ) { event in
            // After the event is delivered, so the page's own handling
            // cannot repaint the cursor over ours.
            DispatchQueue.main.async { update() }
            return event
        }
    }

    static func update() {
        if let cursor = cursorUnderMouse() {
            cursor.set()
            owning = true
        } else if owning {
            owning = false
            NSCursor.arrow.set()
        }
    }

    private static func cursorUnderMouse() -> NSCursor? {
        let mouse = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number) else { return nil }
        let location = window.convertPoint(fromScreen: mouse)
        let controls = PointingCursorRegion.regions.allObjects.filter { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(location, from: nil))
        }
        if !controls.isEmpty {
            // A special cursor, like a divider's resize, wins over the hand.
            if let special = controls.first(where: { $0.cursor != .pointingHand && $0.cursor != .arrow }) {
                return special.cursor
            }
            return controls.contains { $0.cursor == .pointingHand } ? .pointingHand : .arrow
        }
        return PageControlRegion.contains(location, in: window) ? .arrow : nil
    }
}

struct SiteIcon: View {
    @Environment(Workspace.self) private var workspace
    var pane: PaneID?
    var palette: Palette
    var framed = true
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            if framed {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.panel)
            }
            if let pane, let icon = workspace.hosts.favicons[pane] {
                Image(nsImage: icon).resizable().scaledToFit().padding(size * 0.15)
            } else {
                Image(systemName: pane.map { workspace.surfaces.kind($0).symbol } ?? "square.grid.2x2")
                    .font(.system(size: size * 0.53, weight: .medium))
                    .foregroundStyle(palette.text)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
