import SwiftUI

enum Metrics {
    static let panelRadius: CGFloat = 12
    static let gapTight: CGFloat = 4
    static let gap: CGFloat = 8
    static let gapLoose: CGFloat = 12
    static let surfaceRadius: CGFloat = 8
    static let controlRadius: CGFloat = 6
    static let sidebarWidth: CGFloat = 216
    static let sidebarMin: CGFloat = 160
    static let sidebarMax: CGFloat = 320
    static let sidebarCollapse: CGFloat = 120
    static let sidebarDivider: CGFloat = 8
    static let trafficLightsWidth: CGFloat = 78
    static let trafficLightsHeight: CGFloat = 38
    static let sidebarPadding: CGFloat = 8
    static let tabRowHeight: CGFloat = 30
    static let toolbarHeight: CGFloat = 40
    static let paneGap: CGFloat = 1
    static let controlSize: CGFloat = 22
    static let iconSize: CGFloat = 15
    static let emptyIconSize: CGFloat = 22
    static let labelText: CGFloat = 11.5
    static let nameText: CGFloat = 13
    static let textLineHeight: CGFloat = 16
    static let morph = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)

    static func settleSidebar(_ width: CGFloat) -> CGFloat {
        if width < sidebarCollapse { return 0 }
        return min(max(width, sidebarMin), sidebarMax)
    }
}

enum Tint: String, Codable, CaseIterable, Equatable {
    /// `accent` follows the accent color chosen in System Settings.
    case ink, violet, moss, amber, pine, accent

    var name: String { rawValue }

    var title: String { self == .accent ? "Accent Color" : rawValue.capitalized }

    static func parse(_ word: String) -> Tint? {
        Tint(rawValue: word.lowercased())
    }

    var rgb: (UInt8, UInt8, UInt8) {
        switch self {
        case .ink: return (0x09, 0x09, 0x0b)
        case .violet: return (0x16, 0x12, 0x18)
        case .moss: return (0x10, 0x15, 0x12)
        case .amber: return (0x17, 0x13, 0x0e)
        case .pine: return (0x02, 0x2c, 0x22)
        // Unused: the accent color comes from the system.
        case .accent: return (0x09, 0x09, 0x0b)
        }
    }

    var hsl: (CGFloat, CGFloat, CGFloat) {
        let (r8, g8, b8) = rgb
        let r = CGFloat(r8) / 255
        let g = CGFloat(g8) / 255
        let b = CGFloat(b8) / 255
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let lightness = (maxV + minV) / 2
        if maxV - minV < .ulpOfOne { return (0, 0, lightness) }
        let range = maxV - minV
        let saturation = lightness > 0.5 ? range / (2 - maxV - minV) : range / (maxV + minV)
        let hue: CGFloat
        if maxV == r {
            hue = ((g - b) / range).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            hue = (b - r) / range + 2
        } else {
            hue = (r - g) / range + 4
        }
        return ((hue / 6).truncatingRemainder(dividingBy: 1), saturation, lightness)
    }

    var accent: Color {
        if self == .accent { return .accentColor }
        let (hue, saturation, _) = hsl
        let wrapped = hue < 0 ? hue + 1 : hue
        return Color(hsla: wrapped, Swift.min(saturation, 0.75), 0.46)
    }

    /// The color the glass takes on. Ink keeps it clear.
    var glass: Color? { self == .ink ? nil : accent }
}

extension EnvironmentValues {
    /// The tint every `PageGlass` and the window's backdrop take on.
    @Entry var glassTint: Color?
}

struct Palette {
    var panel: Color
    var specular: Color
    var chrome: Color
    var pane: Color
    var hover: Color
    var hairline: Color
    var hairlineActive: Color
    var text: Color
    var textDim: Color
    var selection: Color
    var accent: Color

    static func of(_ scheme: ColorScheme, tint: Tint) -> Palette {
        switch scheme {
        case .dark: return .dark(tint)
        default: return .light
        }
    }

    static func dark(_ tint: Tint) -> Palette {
        let accent = tint.accent
        return Palette(
            panel: .page,
            specular: Color(hsla: 0, 0, 1, 0.10),
            chrome: .page,
            pane: .page,
            hover: Color(hsla: 0, 0, 1, 0.08),
            hairline: Color(hsla: 0, 0, 1, 0.08),
            hairlineActive: accent,
            text: Color(hsla: 0, 0, 1),
            textDim: Color(hsla: 0, 0, 1),
            selection: Color(hsla: 0, 0, 1, 0.22),
            accent: accent
        )
    }

    static let light = Palette(
        panel: Color(hsla: 0, 0, 0.94),
        specular: Color(hsla: 0, 0, 1, 0.35),
        chrome: Color(hsla: 0, 0, 0.91),
        pane: Color(hsla: 0, 0, 1),
        hover: Color(hsla: 0, 0, 0, 0.07),
        hairline: Color(hsla: 0, 0, 0, 0.10),
        hairlineActive: Color(hsla: 0, 0, 0, 0.24),
        text: Color(hsla: 0, 0, 0.039),
        textDim: Color(hsla: 0, 0, 0.039),
        selection: Color(hsla: 0, 0, 0, 0.14),
        accent: Color(hsla: 0, 0, 0.039)
    )
}

extension Color {
    /// #0F0F0F — the page, the panes, the window.
    static let page = Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)

    init(hsla h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat = 1) {
        let (r, g, b) = Color.hslToRGB(h, s, l)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var nsColor: NSColor {
        NSColor(self)
    }

    private static func hslToRGB(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
    }
}
